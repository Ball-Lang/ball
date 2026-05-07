part of 'engine.dart';

// Maps std function names to the Dart operator symbol used in the encoder.
const _stdFunctionToOperator = <String, String>{
  'equals': '==',
  'not_equals': '!=',
  'add': '+',
  'subtract': '-',
  'multiply': '*',
  'divide': '~/',
  'divide_double': '/',
  'modulo': '%',
  'less_than': '<',
  'greater_than': '>',
  'lte': '<=',
  'gte': '>=',
  'index': '[]',
};

extension BallEngineStd on BallEngine {
  // ============================================================
  // Base Functions (std + dart_std modules)
  // ============================================================

  /// Unwrap a value that may be a [BallMap] or a raw [Map<String, Object?>].
  Map<String, Object?>? _stdAsMap(Object? v) {
    if (v is BallMap) return v.entries;
    if (v is Map<String, Object?>) return v;
    if (v is Map) return v.cast<String, Object?>();
    return null;
  }

  /// Unwrap a value that may be a [BallList] or a raw [List].
  List<Object?>? _stdAsList(Object? v) {
    if (v is BallList) return v.items;
    if (v is List) return v as List<Object?>;
    return null;
  }

  /// Try to dispatch a std operator call to a user-defined operator override.
  /// Returns `null` if no override is found.
  Future<Object?> _tryOperatorOverride(String function, Object? input) async {
    final op = _stdFunctionToOperator[function];
    if (op == null) return null;
    final m = _stdAsMap(input);
    if (m == null) return null;

    // For 'index', operands are in 'target'/'index'; for others, 'left'/'right'.
    final Object? left;
    final Object? right;
    if (function == 'index') {
      left = m['target'];
      right = m['index'];
    } else {
      left = m['left'];
      right = m['right'];
    }

    final leftMap = _stdAsMap(left);
    if (leftMap == null || !leftMap.containsKey('__type__')) {
      return null;
    }

    final typeName = leftMap['__type__'] as String;
    final colonIdx = typeName.indexOf(':');
    final modPart = colonIdx >= 0
        ? typeName.substring(0, colonIdx)
        : _currentModule;

    // Walk the type hierarchy (self, then __super__ chain) looking for the
    // operator method, mirroring normal method dispatch.
    Map<String, Object?>? current = leftMap;
    while (current != null) {
      final curType = current['__type__'] as String?;
      if (curType != null) {
        final cColonIdx = curType.indexOf(':');
        final cModPart = cColonIdx >= 0
            ? curType.substring(0, cColonIdx)
            : modPart;
        final cTypeName = cColonIdx >= 0 ? curType : '$cModPart:$curType';
        final methodKey = '$cModPart.$cTypeName.$op';
        final method = _functions[methodKey];
        if (method != null) {
          // Build input matching method-call convention: {self, other, arg0, right}.
          // Include arg0 so positional param binding works for any param name.
          final methodInput = <String, Object?>{
            'self': left,
            'other': right,
            'arg0': right,
            'right': right,
          };
          return _callFunction(cModPart, method, methodInput);
        }
      }
      current = _stdAsMap(current['__super__']);
    }

    return null;
  }

  /// Dispatch a static method call on a built-in class (List, Map, Set).
  /// Returns [_sentinel] if not handled.
  Future<Object?> _dispatchBuiltinClassMethod(
    String className,
    String method,
    Map<String, Object?> args,
  ) async {
    switch ('$className.$method') {
      case 'List.generate':
        final count = args['arg0'] ?? args['count'];
        final generator = args['arg1'] ?? args['generator'];
        return _callBaseFunction('std', 'dart_list_generate', <String, Object?>{
          'count': count,
          'generator': generator,
        });
      case 'List.filled':
        final count = args['arg0'] ?? args['count'];
        final value = args['arg1'] ?? args['value'];
        return _callBaseFunction('std', 'dart_list_filled', <String, Object?>{
          'count': count,
          'value': value,
        });
      case 'List.of':
      case 'List.from':
        final source = args['arg0'] ?? args['value'];
        final sourceList = _stdAsList(source);
        if (sourceList != null) {
          _trackMemoryAllocation(sourceList.length * _ballPointerBytes);
          return sourceList.toList();
        }
        if (source is Set) {
          _trackMemoryAllocation(source.length * _ballPointerBytes);
          return source.toList();
        }
        if (source is Iterable) {
          final result = source.toList();
          _trackMemoryAllocation(result.length * _ballPointerBytes);
          return result;
        }
        return <Object?>[];
      case 'Map.fromEntries':
        final list = args['arg0'] ?? args['list'];
        return _callBaseFunction('std', 'map_from_entries', <String, Object?>{
          'list': list,
        });
      default:
        return _sentinel;
    }
  }

  Future<Object?> _callBaseFunction(
    String module,
    String function,
    Object? input,
  ) async {
    // Check for operator overrides on class instances before std dispatch.
    if (_stdFunctionToOperator.containsKey(function)) {
      final override = await _tryOperatorOverride(function, input);
      if (override != null) return override;
    }

    for (final handler in moduleHandlers) {
      if (handler.handles(module)) {
        final result = await handler.call(function, input, callFunction);
        // Profiling: track call counts per function name.
        _callCounts?[function] = (_callCounts![function] ?? 0) + 1;
        return result;
      }
    }
    throw BallRuntimeError('Unknown base module: "$module"');
  }

  // ── Dispatch table builder ──────────────────────────────────────────────
  // Called by StdModuleHandler.init() to obtain the full dispatch map.
  // Lives here so the closures can close over engine instance methods
  // (same Dart library → library-private access is fine).
  // Inspired by V8 Ignition's kInterpreterDispatchTableRegister.
  Map<String, FutureOr<Object?> Function(Object?)> _buildStdDispatch() {
    return {
      // I/O
      'print': _stdPrint,

      // Arithmetic
      'add': _stdAdd,
      'subtract': (i) => _stdBinary(i, (a, b) => a - b),
      'multiply': (i) => _stdBinary(i, (a, b) => a * b),
      'divide': (i) => _stdBinaryInt(i, (a, b) => a ~/ b),
      'divide_double': (i) => _stdBinaryDouble(i, (a, b) => a / b),
      'modulo': (i) => _stdBinary(i, (a, b) => a % b),
      'negate': (i) => _stdUnaryNum(i, (v) => -v),

      // Comparison
      'equals': (i) => _stdBinaryAny(i, (a, b) => a == b),
      'not_equals': (i) => _stdBinaryAny(i, (a, b) => a != b),
      'less_than': (i) => _stdBinaryComp(i, (a, b) => a < b),
      'greater_than': (i) => _stdBinaryComp(i, (a, b) => a > b),
      'lte': (i) => _stdBinaryComp(i, (a, b) => a <= b),
      'gte': (i) => _stdBinaryComp(i, (a, b) => a >= b),

      // Logical (short-circuit handled in _evalCall; these are fallbacks)
      'and': (i) => _stdBinaryBool(i, (a, b) => a && b),
      'or': (i) => _stdBinaryBool(i, (a, b) => a || b),
      'not': _stdNot,

      // Bitwise
      'bitwise_and': (i) => _stdBinaryInt(i, (a, b) => a & b),
      'bitwise_or': (i) => _stdBinaryInt(i, (a, b) => a | b),
      'bitwise_xor': (i) => _stdBinaryInt(i, (a, b) => a ^ b),
      'bitwise_not': (i) => _stdUnaryNum(i, (v) => ~(v as int)),
      'left_shift': (i) => _stdBinaryInt(i, (a, b) => a << b),
      'right_shift': (i) => _stdBinaryInt(i, (a, b) => a >> b),
      'unsigned_right_shift': (i) => _stdBinaryInt(i, (a, b) => a >>> b),

      // Increment/Decrement (value-only; mutation via assign)
      'pre_increment': (i) => (_extractUnaryArg(i) as num) + 1,
      'pre_decrement': (i) => (_extractUnaryArg(i) as num) - 1,
      'post_increment': (i) => (_extractUnaryArg(i) as num) + 1,
      'post_decrement': (i) => (_extractUnaryArg(i) as num) - 1,

      // String & conversion
      'concat': _stdConcat,
      'length': _stdLength,
      'to_string': (i) => _ballToString(_extractUnaryArg(i)),
      'int_to_string': (i) => _stdConvert(i, (v) => (v as int).toString()),
      'double_to_string': (i) =>
          _stdConvert(i, (v) => (v as double).toString()),
      'string_to_int': (i) => _stdConvert(i, (v) => int.parse(v as String)),
      'string_to_double': (i) =>
          _stdConvert(i, (v) => double.parse(v as String)),
      'to_double': (i) => _toNum(_extractUnaryArg(i)).toDouble(),
      'to_int': (i) => _toNum(_extractUnaryArg(i)).toInt(),
      'int_to_double': (i) => _toNum(_extractUnaryArg(i)).toDouble(),
      'double_to_int': (i) => _toNum(_extractUnaryArg(i)).toInt(),
      'compare_to': (i) {
        final m = _stdAsMap(i) ?? <String, Object?>{'value': i};
        final v = m['value'] ?? m['left'];
        final other = m['other'] ?? m['right'];
        if (v is String && other is String) return v.compareTo(other);
        final a = _toNum(v);
        final b = _toNum(other);
        return a < b ? -1 : (a > b ? 1 : 0);
      },

      // String interpolation — concatenates evaluated parts list.
      // Encoders emit this frequently; was previously missing from the engine.
      'string_interpolation': (i) {
        final m = _stdAsMap(i);
        if (m != null) {
          final parts = _stdAsList(m['parts']);
          if (parts != null) {
            final result = parts.map((p) => _ballToString(p)).join();
            _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
            return result;
          }
          final value = m['value'];
          if (value != null) {
            final result = _ballToString(value);
            _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
            return result;
          }
        }
        final result = _ballToString(i);
        _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
        return result;
      },

      // Null safety
      'null_coalesce': (i) => _stdBinaryAny(i, (a, b) => a ?? b),
      'null_check': (i) {
        final v = _extractUnaryArg(i);
        if (v == null) {
          throw BallRuntimeError('Null check operator used on a null value');
        }
        return v;
      },
      'null_aware_access': _stdNullAwareAccess,
      'null_aware_call': _stdNullAwareCall,

      // Control flow (fallbacks for pre-evaluated input)
      'if': _stdIf,

      // Type operations
      'is': _stdTypeCheck,
      'is_not': (i) => !(_stdTypeCheck(i) as bool),
      'as': _extractUnaryArg,

      // Indexing
      'index': _stdIndex,

      // Cascade / spread / invoke
      'cascade': _stdCascade,
      'null_aware_cascade': _stdNullAwareCascade,
      'spread': _extractUnaryArg,
      'null_spread': _extractUnaryArg,
      'invoke': _stdInvoke,
      'tear_off': (i) {
        // Return the lambda/function stored in the input.
        final m = _stdAsMap(i);
        if (m != null) return m['callback'] ?? m['method'];
        return i;
      },
      'list_generate': _stdListGenerate,
      'dart_list_generate': _stdListGenerate,
      'list_filled': _stdListFilled,
      'dart_list_filled': _stdListFilled,

      // Collections
      'map_create': _stdMapCreate,
      'set_create': _stdSetCreate,
      'record': _stdRecord,
      'collection_if': (_) => null,
      'collection_for': (_) => null,

      // std_collections — list operations
      'list_push': (i) {
        final m = _stdAsMap(i)!;
        final raw = m['list'];
        final list =
            _stdAsList(raw) ?? (raw is Set ? raw.toList() : <Object?>[]);
        _trackMemoryAllocation(_ballPointerBytes);
        list.add(m['value']);
        return list;
      },
      'list_pop': (i) {
        final list = _stdAsList((_stdAsMap(i)!)['list'])!;
        if (list.isEmpty) throw BallRuntimeError('pop on empty list');
        return list.removeLast();
      },
      'list_insert': (i) {
        final m = _stdAsMap(i)!;
        final list = (_stdAsList(m['list'])!).toList();
        _trackMemoryAllocation((list.length + 1) * _ballPointerBytes);
        list.insert(_toInt(m['index']), m['value']);
        return list;
      },
      'list_remove_at': (i) {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        return list.removeAt(_toInt(m['index']));
      },
      'list_get': (i) {
        final m = _stdAsMap(i)!;
        return (_stdAsList(m['list'])!)[_toInt(m['index'])];
      },
      'list_set': (i) {
        final m = _stdAsMap(i)!;
        final list = (_stdAsList(m['list'])!).toList();
        _trackMemoryAllocation(list.length * _ballPointerBytes);
        list[_toInt(m['index'])] = m['value'];
        return list;
      },
      'list_length': (i) => _stdAsList((_stdAsMap(i)!)['list'])!.length,
      'list_is_empty': (i) => _stdAsList((_stdAsMap(i)!)['list'])!.isEmpty,
      'list_first': (i) => _stdAsList((_stdAsMap(i)!)['list'])!.first,
      'list_last': (i) => _stdAsList((_stdAsMap(i)!)['list'])!.last,
      'list_single': (i) => _stdAsList((_stdAsMap(i)!)['list'])!.single,
      'list_contains': (i) {
        final m = _stdAsMap(i)!;
        final collection = m['list'];
        if (collection is String)
          return collection.contains(m['value'].toString());
        final collectionList = _stdAsList(collection);
        if (collectionList != null) return collectionList.contains(m['value']);
        if (collection is Set) return collection.contains(m['value']);
        return false;
      },
      'list_index_of': (i) {
        final m = _stdAsMap(i)!;
        return (_stdAsList(m['list'])!).indexOf(m['value']);
      },
      'list_map': (i) async {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        final result = <Object?>[];
        _trackMemoryAllocation(list.length * _ballPointerBytes);
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          result.add(v);
        }
        return result;
      },
      'list_filter': (i) async {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        final result = <Object?>[];
        _trackMemoryAllocation(list.length * _ballPointerBytes);
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v == true) result.add(e);
        }
        return result;
      },
      'list_reduce': (i) async {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final cb = m['callback'];
        var acc = m['initial'];
        for (final e in list) {
          var v = (cb as Function)(<String, Object?>{'left': acc, 'right': e});
          if (v is Future) v = await v;
          acc = v;
        }
        return acc;
      },
      'list_find': (i) async {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v == true) return e;
        }
        throw StateError('No element');
      },
      'list_any': (i) async {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v == true) return true;
        }
        return false;
      },
      'list_all': (i) async {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v != true) return false;
        }
        return true;
      },
      'list_none': (i) async {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v == true) return false;
        }
        return true;
      },
      'list_sort': (i) async {
        final m = _stdAsMap(i)!;
        final sorted = (_stdAsList(m['list'])!).toList();
        _trackMemoryAllocation(sorted.length * _ballPointerBytes);
        final cb =
            m['callback'] ?? m['comparator'] ?? m['compare'] ?? m['value'];
        if (cb == null || cb is! Function) {
          // Natural sort (no comparator).
          sorted.sort((a, b) => (a as Comparable).compareTo(b));
          return sorted;
        }
        // Use insertion sort to support async comparators.
        for (var j = 1; j < sorted.length; j++) {
          final key = sorted[j];
          var k = j - 1;
          while (k >= 0) {
            var r = (cb as Function)(<String, Object?>{
              'left': sorted[k],
              'right': key,
              'arg0': sorted[k],
              'arg1': key,
              'a': sorted[k],
              'b': key,
            });
            if (r is Future) r = await r;
            final cmp = (r is int) ? r : (r as num).toInt();
            if (cmp <= 0) break;
            sorted[k + 1] = sorted[k];
            k--;
          }
          sorted[k + 1] = key;
        }
        return sorted;
      },
      'list_sort_by': (i) async {
        final m = _stdAsMap(i)!;
        final list = (_stdAsList(m['list'])!).toList();
        _trackMemoryAllocation(list.length * _ballPointerBytes);
        final cb = m['callback'];
        // Pre-compute keys with await support.
        final keys = <Comparable>[];
        for (final e in list) {
          var k = (cb as Function)(e);
          if (k is Future) k = await k;
          keys.add(k as Comparable);
        }
        // Build index list and sort by keys.
        _trackMemoryAllocation(list.length * _ballPointerBytes);
        final indices = List.generate(list.length, (i) => i);
        indices.sort((a, b) => keys[a].compareTo(keys[b]));
        _trackMemoryAllocation(indices.length * _ballPointerBytes);
        return [for (final idx in indices) list[idx]];
      },
      'list_reverse': (i) => _trackListCopy(
        _stdAsList((_stdAsMap(i)!)['list'])!.reversed.toList(),
      ),
      'list_slice': (i) {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        // Support named fields (start/end), positional args (arg0/arg1),
        // and 'value' field.
        int s;
        int? e;
        if (m.containsKey('start')) {
          s = _toInt(m['start']);
          e = m['end'] != null ? _toInt(m['end']) : null;
        } else if (m.containsKey('arg0') && m.containsKey('arg1')) {
          s = _toInt(m['arg0']);
          e = _toInt(m['arg1']);
        } else if (m.containsKey('value')) {
          // Single 'value' field: treat as start index.
          final v = m['value'];
          if (v is List && v.length >= 2) {
            s = _toInt(v[0]);
            e = _toInt(v[1]);
          } else {
            s = _toInt(v);
            e = null;
          }
        } else {
          s = 0;
          e = null;
        }
        final result = list.sublist(s, e ?? list.length);
        _trackMemoryAllocation(result.length * _ballPointerBytes);
        return result;
      },
      'list_flat_map': (i) async {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        final result = <Object?>[];
        _trackMemoryAllocation(list.length * _ballPointerBytes);
        for (final e in list) {
          var r = cb(e);
          if (r is Future) r = await r;
          if (r is List) {
            result.addAll(r);
          } else {
            result.add(r);
          }
        }
        return result;
      },
      'list_zip': (i) {
        final m = _stdAsMap(i)!;
        final a = _stdAsList(m['list'])!;
        final b = _stdAsList(m['value'])!;
        final len = a.length < b.length ? a.length : b.length;
        _trackMemoryAllocation(len * _ballPointerBytes);
        return List.generate(len, (j) {
          _trackMemoryAllocation(2 * _ballPointerBytes);
          return [a[j], b[j]];
        });
      },
      'list_take': (i) {
        final m = _stdAsMap(i)!;
        final result = (_stdAsList(
          m['list'],
        )!).take(_toInt(m['value'] ?? m['index'])).toList();
        _trackMemoryAllocation(result.length * _ballPointerBytes);
        return result;
      },
      'list_drop': (i) {
        final m = _stdAsMap(i)!;
        final result = (_stdAsList(
          m['list'],
        )!).skip(_toInt(m['value'] ?? m['index'])).toList();
        _trackMemoryAllocation(result.length * _ballPointerBytes);
        return result;
      },
      'list_concat': (i) {
        final m = _stdAsMap(i)!;
        final result = [..._stdAsList(m['list'])!, ..._stdAsList(m['value'])!];
        _trackMemoryAllocation(result.length * _ballPointerBytes);
        return result;
      },
      'list_clear': (i) {
        final m = _stdAsMap(i)!;
        final raw = m['list'];
        final list = _stdAsList(raw);
        if (list != null) {
          list.clear();
          return list;
        }
        return <Object?>[];
      },
      'list_to_list': (i) {
        final raw = (_stdAsMap(i)!)['list'];
        final list = _stdAsList(raw);
        if (list != null) {
          _trackMemoryAllocation(list.length * _ballPointerBytes);
          return list.toList();
        }
        if (raw is Set) {
          _trackMemoryAllocation(raw.length * _ballPointerBytes);
          return raw.toList();
        }
        return <Object?>[];
      },
      'list_foreach': (i) async {
        final m = _stdAsMap(i)!;
        final collection = m['list'];
        final fn = m['function'] ?? m['value'] ?? m['callback'];
        if (fn is Function) {
          final listVal = _stdAsList(collection);
          if (listVal != null) {
            for (final item in listVal) {
              var r = fn(item);
              if (r is Future) await r;
            }
          } else if (collection is Map) {
            // Map.forEach((key, value) => ...) — call with positional args
            // so the lambda can bind them by param name.
            for (final entry in collection.entries) {
              var r = fn(<String, Object?>{
                'key': entry.key,
                'value': entry.value,
                'arg0': entry.key,
                'arg1': entry.value,
              });
              if (r is Future) await r;
            }
          } else if (collection is BallMap) {
            for (final entry in collection.entries.entries) {
              var r = fn(<String, Object?>{
                'key': entry.key,
                'value': entry.value,
                'arg0': entry.key,
                'arg1': entry.value,
              });
              if (r is Future) await r;
            }
          } else if (collection is Set) {
            for (final item in collection) {
              var r = fn(item);
              if (r is Future) await r;
            }
          }
        }
        return null;
      },
      'list_join': (i) {
        final m = _stdAsMap(i)!;
        final list = _stdAsList(m['list'])!;
        final sep = m['separator']?.toString() ?? ',';
        return list.map((e) => _ballToString(e)).join(sep);
      },

      // std_collections — map operations
      'map_get': (i) {
        final m = _stdAsMap(i)!;
        final raw = m['map'];
        final map = raw is BallMap
            ? raw.entries
            : (raw is Map ? raw : <dynamic, dynamic>{});
        return map[m['key']];
      },
      'map_set': (i) {
        final m = _stdAsMap(i)!;
        final raw = m['map'];
        final map = raw is BallMap
            ? raw.entries
            : (raw is Map ? raw : <dynamic, dynamic>{});
        if (!map.containsKey(m['key'])) {
          _trackMemoryAllocation(_ballMapEntryBytes);
        }
        map[m['key']] = m['value'];
        return map;
      },
      'map_delete': (i) {
        final m = _stdAsMap(i)!;
        final raw = m['map'];
        final map = raw is BallMap
            ? raw.entries
            : (raw is Map ? raw : <dynamic, dynamic>{});
        map.remove(m['key']);
        return map;
      },
      'map_contains_key': (i) {
        final m = _stdAsMap(i)!;
        final target = m['map'];
        if (target is BallMap) return target.entries.containsKey(m['key']);
        if (target is Map) return target.containsKey(m['key']);
        if (target is Set) return target.contains(m['key']);
        throw BallRuntimeError('map_contains_key: expected Map or Set');
      },
      'map_contains_value': (i) {
        final m = _stdAsMap(i)!;
        final raw = m['map'];
        final map = raw is BallMap
            ? raw.entries
            : (raw is Map ? raw : <dynamic, dynamic>{});
        return map.containsValue(m['value']);
      },
      'map_put_if_absent': (i) {
        final m = _stdAsMap(i)!;
        final map = _stdAsMap(m['map']) ?? (m['map'] as Map);
        final key = m['key'] as String;
        if (!map.containsKey(key)) {
          _trackMemoryAllocation(_ballMapEntryBytes);
          final val = m['value'];
          map[key] = val is Function ? val() : val;
        }
        return map[key];
      },
      'map_keys': (i) {
        final map =
            _stdAsMap((_stdAsMap(i)!)['map']) ??
            ((_stdAsMap(i)!)['map'] as Map);
        final result = map.keys.toList();
        _trackMemoryAllocation(result.length * _ballPointerBytes);
        return result;
      },
      'map_values': (i) {
        final map =
            _stdAsMap((_stdAsMap(i)!)['map']) ??
            ((_stdAsMap(i)!)['map'] as Map);
        final result = map.values.toList();
        _trackMemoryAllocation(result.length * _ballPointerBytes);
        return result;
      },
      'map_entries': (i) {
        final map =
            _stdAsMap((_stdAsMap(i)!)['map']) ??
            ((_stdAsMap(i)!)['map'] as Map);
        _trackMemoryAllocation(
          map.length * (_ballPointerBytes + _ballMapEntryBytes),
        );
        return map.entries
            .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
            .toList();
      },
      'map_from_entries': (i) {
        final list = _stdAsList((_stdAsMap(i)!)['list'])!;
        _trackMemoryAllocation(list.length * _ballMapEntryBytes);
        final result = <String, Object?>{};
        for (final e in list) {
          final eMap = _stdAsMap(e);
          if (eMap != null) {
            final k = eMap['key'] ?? eMap['arg0'];
            final v = eMap['value'] ?? eMap['arg1'];
            if (k != null) result[k.toString()] = v;
          } else if (e is Map) {
            final k = e['key'] ?? e['arg0'];
            final v = e['value'] ?? e['arg1'];
            if (k != null) result[k.toString()] = v;
          }
        }
        return result;
      },
      'map_merge': (i) {
        final m = _stdAsMap(i)!;
        final map1 = _stdAsMap(m['map']) ?? (m['map'] as Map);
        final map2 = _stdAsMap(m['value']) ?? (m['value'] as Map);
        final result = <String, Object?>{
          ...map1.cast<String, Object?>(),
          ...map2.cast<String, Object?>(),
        };
        _trackMemoryAllocation(result.length * _ballMapEntryBytes);
        return result;
      },
      'map_map': (i) async {
        final m = _stdAsMap(i)!;
        final map = _stdAsMap(m['map']) ?? (m['map'] as Map);
        final cb = m['callback'];
        final result = <String, Object?>{};
        _trackMemoryAllocation(map.length * _ballMapEntryBytes);
        for (final entry in map.entries) {
          var r = (cb as Function)(<String, Object?>{
            'key': entry.key,
            'value': entry.value,
          });
          if (r is Future) r = await r;
          final rMap = _stdAsMap(r);
          if (rMap != null) {
            result[rMap['key'] as String] = rMap['value'];
          } else {
            result[entry.key as String] = r;
          }
        }
        return result;
      },
      'map_filter': (i) async {
        final m = _stdAsMap(i)!;
        final map = _stdAsMap(m['map']) ?? (m['map'] as Map);
        final cb = m['callback'];
        final result = <String, Object?>{};
        _trackMemoryAllocation(map.length * _ballMapEntryBytes);
        for (final entry in map.entries) {
          var v = (cb as Function)(<String, Object?>{
            'key': entry.key,
            'value': entry.value,
          });
          if (v is Future) v = await v;
          if (v == true) {
            result[entry.key as String] = entry.value;
          }
        }
        return result;
      },
      'map_is_empty': (i) {
        final map =
            _stdAsMap((_stdAsMap(i)!)['map']) ??
            ((_stdAsMap(i)!)['map'] as Map);
        return map.isEmpty;
      },
      'map_length': (i) {
        final map =
            _stdAsMap((_stdAsMap(i)!)['map']) ??
            ((_stdAsMap(i)!)['map'] as Map);
        return map.length;
      },

      // std_collections — string join
      'string_join': (i) {
        final m = _stdAsMap(i)!;
        final result = (_stdAsList(
          m['list'],
        )!).map((e) => '$e').join(m['separator'] as String? ?? '');
        _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
        return result;
      },

      // std_collections — set operations
      'set_add': (i) {
        final m = _stdAsMap(i)!;
        final s = (m['set'] as Set).toSet();
        s.add(m['value']);
        return s;
      },
      'set_remove': (i) {
        final m = _stdAsMap(i)!;
        final s = (m['set'] as Set).toSet();
        s.remove(m['value']);
        return s;
      },
      'set_contains': (i) {
        final m = _stdAsMap(i)!;
        return (m['set'] as Set).contains(m['value']);
      },
      'set_union': (i) {
        final m = _stdAsMap(i)!;
        return (m['left'] as Set).union(m['right'] as Set);
      },
      'set_intersection': (i) {
        final m = _stdAsMap(i)!;
        return (m['left'] as Set).intersection(m['right'] as Set);
      },
      'set_difference': (i) {
        final m = _stdAsMap(i)!;
        return (m['left'] as Set).difference(m['right'] as Set);
      },
      'set_length': (i) => ((_stdAsMap(i)!)['set'] as Set).length,
      'set_is_empty': (i) => ((_stdAsMap(i)!)['set'] as Set).isEmpty,
      'set_to_list': (i) => ((_stdAsMap(i)!)['set'] as Set).toList(),

      // Switch expression
      'switch_expr': _stdSwitchExpr,

      // Exceptions
      'throw': (i) {
        final val = _extractUnaryArg(i);
        String typeName = 'Exception';
        final valMap = _stdAsMap(val);
        if (valMap != null) {
          typeName =
              (valMap['__type__'] as String?) ??
              (valMap['__type'] as String?) ??
              'Exception';
          // Ensure 'message' field exists for standard exception types.
          // The encoder stores the message as arg0; Dart code accesses e.message.
          if (!valMap.containsKey('message') && valMap.containsKey('arg0')) {
            valMap['message'] = valMap['arg0'];
          }
        }
        throw BallException(typeName, val);
      },
      'rethrow': (_) {
        final ex = _activeException;
        if (ex == null) {
          throw BallRuntimeError('rethrow outside of catch');
        }
        throw ex;
      },
      // The encoder wraps parenthesized sub-expressions (assign /
      // cascade / ternary) in a `std.paren` call to preserve precedence.
      // At runtime the parens are semantically a no-op — just return
      // the inner value.
      'paren': (i) => _extractUnaryArg(i),

      // Assert
      'assert': _stdAssert,

      // Async — synchronous simulation via BallFuture/BallGenerator
      'await': (i) async {
        var val = _extractUnaryArg(i);
        // Unwrap real Dart Futures (from async lambda bodies).
        if (val is Future) val = await val;
        // Unwrap BallFuture (synchronous simulation of async).
        if (_isBallFuture(val)) return _unwrapBallFuture(val);
        return val;
      },
      'yield': (i) {
        final val = _extractUnaryArg(i);
        // In generator context, add the value to the current BallGenerator.
        // The generator is bound as __generator__ in the function scope by
        // _callFunction when it detects is_sync_star / is_async_star.
        // Outside generator context, just return the value.
        return val;
      },
      'yield_each': (i) {
        final val = _extractUnaryArg(i);
        // Flatten iterable yields: add all elements to the current generator.
        return val;
      },

      // Literals
      'symbol': (i) => _extractField(i, 'value'),
      'type_literal': (i) => _extractField(i, 'type'),

      // Labels (handled lazily in _evalCall)
      'labeled': (_) => null,

      // ── Strings ──────────────────────────────────────────────────
      'string_length': (i) => _stdConvert(i, (v) => (v as String).length),
      'string_is_empty': (i) => _stdConvert(i, (v) => (v as String).isEmpty),
      'string_concat': _stdConcat,
      'string_contains': (i) =>
          _stdBinaryAny(i, (a, b) => (a as String).contains(b as String)),
      'string_starts_with': (i) =>
          _stdBinaryAny(i, (a, b) => (a as String).startsWith(b as String)),
      'string_ends_with': (i) =>
          _stdBinaryAny(i, (a, b) => (a as String).endsWith(b as String)),
      'string_index_of': (i) =>
          _stdBinaryAny(i, (a, b) => (a as String).indexOf(b as String)),
      'string_last_index_of': (i) =>
          _stdBinaryAny(i, (a, b) => (a as String).lastIndexOf(b as String)),
      'string_substring': _stdStringSubstring,
      'string_char_at': _stdStringCharAt,
      'string_char_code_at': _stdStringCharCodeAt,
      'string_code_unit_at': _stdStringCharCodeAt,
      'string_from_char_code': (i) =>
          _stdConvert(i, (v) => String.fromCharCode(v as int)),
      'string_to_upper': (i) =>
          _stdConvert(i, (v) => (v as String).toUpperCase()),
      'string_to_lower': (i) =>
          _stdConvert(i, (v) => (v as String).toLowerCase()),
      'string_trim': (i) => _stdConvert(i, (v) => (v as String).trim()),
      'string_trim_start': (i) =>
          _stdConvert(i, (v) => (v as String).trimLeft()),
      'string_trim_end': (i) =>
          _stdConvert(i, (v) => (v as String).trimRight()),
      'string_replace': (i) => _stdStringReplace(i, false),
      'string_replace_all': (i) => _stdStringReplace(i, true),
      'string_split': (i) {
        final m = _stdAsMap(i);
        if (m != null) {
          final str = (m['string'] ?? m['value'] ?? m['left'] ?? '') as String;
          final delim =
              (m['delimiter'] ?? m['separator'] ?? m['right'] ?? '') as String;
          final result = str.split(delim);
          _trackMemoryAllocation(
            result.length * _ballPointerBytes +
                result.fold<int>(0, (sum, part) => sum + part.length) *
                    _ballStringCodeUnitBytes,
          );
          return result;
        }
        return <String>[];
      },
      'string_repeat': _stdStringRepeat,
      'string_pad_left': (i) => _stdStringPad(i, true),
      'string_pad_right': (i) => _stdStringPad(i, false),

      // ── Regex ────────────────────────────────────────────────────
      'regex_match': (i) =>
          _stdBinaryAny(i, (a, b) => RegExp(b as String).hasMatch(a as String)),
      'regex_find': (i) => _stdBinaryAny(
        i,
        (a, b) => RegExp(b as String).firstMatch(a as String)?.group(0),
      ),
      'regex_find_all': (i) => _stdBinaryAny(
        i,
        (a, b) => RegExp(
          b as String,
        ).allMatches(a as String).map((m) => m.group(0)!).toList(),
      ),
      'regex_replace': (i) => _stdRegexReplace(i, false),
      'regex_replace_all': (i) => _stdRegexReplace(i, true),

      // ── Math ─────────────────────────────────────────────────────
      'math_abs': (i) => _stdConvert(i, (v) => (v as num).abs()),
      'math_floor': (i) => _stdConvert(i, (v) => (v as num).floor()),
      'math_ceil': (i) => _stdConvert(i, (v) => (v as num).ceil()),
      'math_round': (i) => _stdConvert(i, (v) => (v as num).round()),
      'math_trunc': (i) => _stdConvert(i, (v) => (v as num).truncate()),
      'math_sqrt': (i) => _stdMathUnary(i, _mathSqrt),
      'math_pow': (i) => _stdMathBinary(i, _mathPow),
      'math_log': (i) => _stdMathUnary(i, _mathLog),
      'math_log2': (i) => _stdMathUnary(i, (v) => _mathLog(v) / _mathLog(2)),
      'math_log10': (i) => _stdMathUnary(i, (v) => _mathLog(v) / _mathLog(10)),
      'math_exp': (i) => _stdMathUnary(i, _mathExp),
      'math_sin': (i) => _stdMathUnary(i, _mathSin),
      'math_cos': (i) => _stdMathUnary(i, _mathCos),
      'math_tan': (i) => _stdMathUnary(i, _mathTan),
      'math_asin': (i) => _stdMathUnary(i, _mathAsin),
      'math_acos': (i) => _stdMathUnary(i, _mathAcos),
      'math_atan': (i) => _stdMathUnary(i, _mathAtan),
      'math_atan2': (i) => _stdMathBinary(i, _mathAtan2),
      'math_min': (i) => _stdBinary(i, (a, b) => a < b ? a : b),
      'math_max': (i) => _stdBinary(i, (a, b) => a > b ? a : b),
      'math_clamp': _stdMathClamp,
      'math_pi': (_) => 3.141592653589793,
      'math_e': (_) => 2.718281828459045,
      'math_infinity': (_) => double.infinity,
      'math_nan': (_) => double.nan,
      'math_is_nan': (i) => _stdConvert(i, (v) => (v as num).isNaN),
      'math_is_finite': (i) => _stdConvert(i, (v) => (v as num).isFinite),
      'math_is_infinite': (i) => _stdConvert(i, (v) => (v as num).isInfinite),
      'math_sign': (i) => _stdConvert(i, (v) => (v as num).sign),
      'math_gcd': (i) => _stdBinaryInt(i, (a, b) => a.gcd(b)),
      'math_lcm': (i) => _stdBinaryInt(i, (a, b) => (a * b).abs() ~/ a.gcd(b)),

      // ── std_io ─────────────────────────────────────────────────
      'print_error': (i) {
        final im = _stdAsMap(i);
        final msg = im != null ? im['message']?.toString() ?? '' : '$i';
        stderr(msg);
        return null;
      },
      'read_line': (_) => stdinReader?.call() ?? '',
      'exit': (i) {
        _checkSandbox('exit');
        final im = _stdAsMap(i);
        final code = im != null ? (im['code'] as int?) ?? 0 : 0;
        throw _ExitSignal(code);
      },
      'panic': (i) {
        _checkSandbox('panic');
        final im = _stdAsMap(i);
        final msg = im != null ? im['message']?.toString() ?? '' : '$i';
        stderr(msg);
        throw _ExitSignal(1);
      },
      'sleep_ms': (i) async {
        final ms = (i is num) ? i.toInt() : 0;
        if (ms > 0) {
          await Future.delayed(Duration(milliseconds: ms));
        }
        return null;
      },
      'timestamp_ms': (_) => DateTime.now().millisecondsSinceEpoch,
      'random_int': (i) {
        final m = _stdAsMap(i)!;
        final min = (m['min'] as num?)?.toInt() ?? 0;
        final max = (m['max'] as num?)?.toInt() ?? 100;
        return min + _random.nextInt(max - min + 1);
      },
      'random_double': (_) => _random.nextDouble(),
      'env_get': (i) {
        _checkSandbox('env_get');
        final im = _stdAsMap(i);
        final name = im != null ? im['name'] as String? ?? '' : '$i';
        return _envGet(name);
      },
      'args_get': (_) => _args,

      // ── std_convert ────────────────────────────────────────────
      'json_encode': (i) {
        final im = _stdAsMap(i);
        final val = im != null ? im['value'] : i;
        return _jsonEncode(val);
      },
      'json_decode': (i) {
        final im = _stdAsMap(i);
        final str = im != null ? im['value'] as String? ?? '' : '$i';
        return _jsonDecode(str);
      },
      'utf8_encode': (i) {
        final im = _stdAsMap(i);
        final str = im != null ? im['value'] as String? ?? '' : '$i';
        return _utf8Encode(str);
      },
      'utf8_decode': (i) {
        final im = _stdAsMap(i);
        final bytes = im != null ? im['value'] as List<int>? ?? [] : <int>[];
        return _utf8Decode(bytes);
      },
      'base64_encode': (i) {
        final im = _stdAsMap(i);
        final bytes = im != null ? im['value'] as List<int>? ?? [] : <int>[];
        return _base64Encode(bytes);
      },
      'base64_decode': (i) {
        final im = _stdAsMap(i);
        final str = im != null ? im['value'] as String? ?? '' : '$i';
        return _base64Decode(str);
      },

      // ── std_time ───────────────────────────────────────────────
      'now': (_) => DateTime.now().millisecondsSinceEpoch,
      'now_micros': (_) => DateTime.now().microsecondsSinceEpoch,
      'format_timestamp': (i) {
        final m = _stdAsMap(i)!;
        final ms = (m['timestamp_ms'] as num?)?.toInt() ?? 0;
        final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
        return dt.toIso8601String();
      },
      'parse_timestamp': (i) {
        final m = _stdAsMap(i)!;
        final str = m['value'] as String? ?? '';
        return DateTime.parse(str).millisecondsSinceEpoch;
      },
      'duration_add': (i) => _stdBinaryInt(i, (a, b) => a + b),
      'duration_subtract': (i) => _stdBinaryInt(i, (a, b) => a - b),
      'year': (_) => DateTime.now().toUtc().year,
      'month': (_) => DateTime.now().toUtc().month,
      'day': (_) => DateTime.now().toUtc().day,
      'hour': (_) => DateTime.now().toUtc().hour,
      'minute': (_) => DateTime.now().toUtc().minute,
      'second': (_) => DateTime.now().toUtc().second,

      // ── std_fs ─────────────────────────────────────────────────
      'file_read': _stdFileRead,
      'file_read_bytes': _stdFileReadBytes,
      'file_write': _stdFileWrite,
      'file_write_bytes': _stdFileWriteBytes,
      'file_append': _stdFileAppend,
      'file_exists': _stdFileExists,
      'file_delete': _stdFileDelete,
      'dir_list': _stdDirList,
      'dir_create': _stdDirCreate,
      'dir_exists': _stdDirExists,

      // ── std_concurrency (single-threaded simulation) ──────────
      'thread_spawn': (i) async {
        // Single-threaded: execute body, return 0 as handle.
        final m = _stdAsMap(i)!;
        final body = m['body'];
        if (body is Function) {
          var v = body(null);
          if (v is Future) await v;
        }
        return 0;
      },
      'thread_join': (_) => null, // no-op in single-threaded mode
      'mutex_create': (_) => _nextMutexId++,
      'mutex_lock': (_) => null, // no-op
      'mutex_unlock': (_) => null, // no-op
      'scoped_lock': (i) async {
        // Execute body directly (no actual locking).
        final m = _stdAsMap(i)!;
        final body = m['body'];
        if (body is Function) {
          var v = body(null);
          if (v is Future) v = await v;
          return v;
        }
        return null;
      },
      'atomic_load': (i) {
        final m = _stdAsMap(i)!;
        return m['value'];
      },
      'atomic_store': (i) => null,
      'atomic_compare_exchange': (i) => true,

      // ── cpp_std (no-op / passthrough in Dart engine) ──────────
      // cpp_scope_exit is handled lazily in _evalCall; this entry handles
      // the rare case of it reaching the dispatch table (already registered).
      'cpp_scope_exit': (_) => null,
      'cpp_destructor': (_) => null,
      'cpp_move': (i) {
        final im = _stdAsMap(i);
        if (im != null) return im['value'];
        return i;
      },
      'cpp_forward': (i) {
        final im = _stdAsMap(i);
        if (im != null) return im['value'];
        return i;
      },
      'cpp_make_unique': (i) => i,
      'cpp_make_shared': (i) => i,
      'cpp_unique_ptr_get': (i) {
        final im = _stdAsMap(i);
        if (im != null) return im['value'];
        return i;
      },
      'cpp_shared_ptr_get': (i) {
        final im = _stdAsMap(i);
        if (im != null) return im['value'];
        return i;
      },
      'cpp_shared_ptr_use_count': (_) => 1,
      'cpp_static_assert': (_) => null,
      'cpp_decltype': (i) => i,
      'cpp_auto': (i) => i,
      'cpp_structured_binding': (i) => i,
      'cpp_template_instantiate': (i) => i,
      'cpp_new': (i) => i,
      'cpp_delete': (_) => null,
      'cpp_sizeof': (_) => 8,
      'cpp_alignof': (_) => 8,
      'ptr_cast': (i) {
        final im = _stdAsMap(i);
        if (im != null) return im['value'];
        return i;
      },
      'arrow': (i) {
        final im = _stdAsMap(i);
        if (im != null) {
          final target = im['target'];
          final field = im['field'];
          final targetMap = _stdAsMap(target);
          if (targetMap != null && field is String) {
            return targetMap[field];
          }
        }
        return null;
      },
      'deref': (i) {
        final im = _stdAsMap(i);
        if (im != null) return im['value'];
        return i;
      },
      'address_of': (i) => i,
      'init_list': (i) => i,
      'nullptr': (_) => null,
      'cpp_ifdef': (i) {
        // Runtime: just evaluate 'then' side (no compile-time symbols in engine)
        final im = _stdAsMap(i);
        if (im != null) return im['then_body'];
        return null;
      },
      'cpp_defined': (_) => false,
      'goto': (i) {
        final im = _stdAsMap(i);
        if (im != null) {
          final label = im['label'] as String? ?? '';
          throw _FlowSignal('goto', label: label);
        }
        return null;
      },
      'label': (i) {
        final im = _stdAsMap(i);
        if (im != null) return im['body'];
        return null;
      },
    };
  }

  // ---- std function implementations ----

  List<Object?> _trackListCopy(List<Object?> list) {
    _trackMemoryAllocation(list.length * _ballPointerBytes);
    return list;
  }

  /// Convert a Ball value to its string representation.
  ///
  /// For typed objects with a user-defined `toString` method, invokes that
  /// method. For StringBuffer objects, returns the buffer contents.
  /// Falls back to Dart's native `toString()`.
  String _ballToString(Object? v) {
    if (v == null || v is BallNull) return 'null';
    if (v is String) return v;
    if (v is BallString) return v.value;
    if (v is bool) return v.toString();
    if (v is BallBool) return v.value.toString();
    if (v is int) return v.toString();
    if (v is BallInt) return v.value.toString();
    if (v is double) return v.toString();
    if (v is BallDouble) return v.toString();
    // BallFuture: show the resolved value for readable output.
    if (_isBallFuture(v)) return _ballToString(_unwrapBallFuture(v));
    if (v is BallList) return '[${v.items.map(_ballToString).join(', ')}]';
    if (v is List) return '[${v.map(_ballToString).join(', ')}]';
    final map = _stdAsMap(v);
    if (map != null) {
      // StringBuffer: return the buffer contents.
      final typeName = map['__type__'] as String?;
      if (typeName != null &&
          (typeName.endsWith(':StringBuffer') || typeName == 'StringBuffer')) {
        return (map['__buffer__'] as String?) ?? '';
      }
      // Typed object: try to invoke the user's toString method.
      if (typeName != null) {
        final resolved = _resolveMethod(typeName, 'toString');
        if (resolved != null) {
          try {
            final future = _callFunction(
              resolved.module,
              resolved.func,
              <String, Object?>{'self': map},
            );
            // _callFunction returns Future<Object?>. Most calls complete
            // synchronously (Dart optimises already-completed Futures).
            // Use .then to grab the value if already resolved.
            Object? syncResult;
            var done = false;
            future.then((r) {
              syncResult = r;
              done = true;
            });
            if (done) return syncResult?.toString() ?? 'null';
            // If truly async, fall back to default representation.
            return map.toString();
          } catch (_) {
            // If toString throws, fall back.
          }
        }
      }
    }
    return v.toString();
  }

  /// Resolve a method by name walking the class hierarchy.
  /// Returns the module name and function definition, or null if not found.
  ({String module, FunctionDefinition func})? _resolveMethod(
    String typeName,
    String methodName,
  ) {
    final colonIdx = typeName.indexOf(':');
    final modPart = colonIdx >= 0
        ? typeName.substring(0, colonIdx)
        : _currentModule;

    // Try "module.typeName.methodName" in _functions.
    final methodKey = '$modPart.$typeName.$methodName';
    final method = _functions[methodKey];
    if (method != null && !method.isBase) {
      return (module: modPart, func: method);
    }

    // Walk superclass chain via _findTypeDef.
    final typeDef = _findTypeDef(typeName);
    if (typeDef != null &&
        typeDef.superclass != null &&
        typeDef.superclass!.isNotEmpty) {
      final superclass = typeDef.superclass!;
      final qualSuper = superclass.contains(':')
          ? superclass
          : '$modPart:$superclass';
      final superResult = _resolveMethod(qualSuper, methodName);
      if (superResult != null) return superResult;
    }

    // Check mixins.
    if (typeDef != null) {
      final mixins = _getMixins(typeName);
      for (final mixin in mixins) {
        final qualMixin = mixin.contains(':') ? mixin : '$modPart:$mixin';
        final mixinResult = _resolveMethod(qualMixin, methodName);
        if (mixinResult != null) return mixinResult;
      }
    }

    return null;
  }

  /// Get mixin names for a type from its module's typeDef metadata.
  List<String> _getMixins(String typeName) {
    for (final module in program.modules) {
      for (final td in module.typeDefs) {
        if (td.name == typeName || td.name.endsWith(':$typeName')) {
          if (td.hasMetadata()) {
            final mixinsField = td.metadata.fields['mixins'];
            if (mixinsField != null &&
                mixinsField.whichKind() == structpb.Value_Kind.listValue) {
              return mixinsField.listValue.values
                  .where((v) => v.hasStringValue())
                  .map((v) => v.stringValue)
                  .toList();
            }
          }
        }
      }
    }
    return const [];
  }

  FutureOr<Object?> _stdPrint(Object? input) async {
    final m = _stdAsMap(input);
    if (m != null) {
      // Accept the canonical `message` key first, then fall back to the
      // generic positional `arg0` and `value` keys that other encoders
      // use. This keeps the live engine, the round-tripped Dart engine,
      // and the cross-language conformance harness in sync without
      // requiring every fixture to pre-rename its print arg.
      final message = m['message'] ?? m['arg0'] ?? m['value'];
      if (message != null) {
        stdout(await _ballToStringAsync(message));
        return null;
      }
    }
    stdout(await _ballToStringAsync(input));
    return null;
  }

  /// Async version of [_ballToString] that can await method calls.
  Future<String> _ballToStringAsync(Object? v) async {
    if (v == null || v is BallNull) return 'null';
    if (v is String) return v;
    if (v is BallString) return v.value;
    if (v is bool) return v.toString();
    if (v is BallBool) return v.value.toString();
    if (v is int) return v.toString();
    if (v is BallInt) return v.value.toString();
    if (v is double) return v.toString();
    if (v is BallDouble) return v.toString();
    if (v is BallList) {
      final parts = <String>[];
      for (final item in v.items) {
        parts.add(await _ballToStringAsync(item));
      }
      return '[${parts.join(', ')}]';
    }
    if (v is List) {
      final parts = <String>[];
      for (final item in v) {
        parts.add(await _ballToStringAsync(item));
      }
      return '[${parts.join(', ')}]';
    }
    final map = _stdAsMap(v);
    if (map != null) {
      final typeName = map['__type__'] as String?;
      if (typeName != null &&
          (typeName.endsWith(':StringBuffer') || typeName == 'StringBuffer')) {
        return (map['__buffer__'] as String?) ?? '';
      }
      if (typeName != null) {
        final resolved = _resolveMethod(typeName, 'toString');
        if (resolved != null) {
          try {
            final result = await _callFunction(
              resolved.module,
              resolved.func,
              <String, Object?>{'self': map},
            );
            return result?.toString() ?? 'null';
          } catch (_) {
            // Fall back on error.
          }
        }
      }
    }
    return v.toString();
  }

  Object? _stdIf(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('std.if input must be a message');
    }
    final condition = m['condition'];
    if (condition == true) return m['then'];
    return m['else'];
  }

  Object? _stdIndex(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('std.index: expected message');
    }
    final target = m['target'];
    final index = m['index'];
    final listTarget = _stdAsList(target);
    if (listTarget != null) return listTarget[_toInt(index)];
    if (target is BallMap)
      return target.entries[index is int ? index.toString() : index];
    if (target is Map) return target[index];
    if (target is String) return target[_toInt(index)];
    throw BallRuntimeError('std.index: unsupported types');
  }

  Object? _stdCascade(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return input;
    return m['target'];
  }

  Object? _stdNullAwareCascade(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return input;
    final target = m['target'];
    if (target == null) return null;
    return target;
  }

  FutureOr<Object?> _stdListGenerate(Object? input) async {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('dart_std.list_generate: expected message');
    }
    final length = _toInt(m['length'] ?? m['count'] ?? m['arg0']);
    final generator =
        m['generator'] ?? m['callback'] ?? m['function'] ?? m['arg1'];
    if (generator is! Function) {
      throw BallRuntimeError(
        'dart_std.list_generate: generator is not callable',
      );
    }
    _trackMemoryAllocation(length * _ballPointerBytes);
    final result = <Object?>[];
    for (var index = 0; index < length; index++) {
      var value = generator(index);
      if (value is Future) value = await value;
      result.add(value);
    }
    return result;
  }

  Object? _stdListFilled(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('dart_std.list_filled: expected message');
    }
    final length = _toInt(m['length'] ?? m['count'] ?? m['arg0']);
    _trackMemoryAllocation(length * _ballPointerBytes);
    return List<Object?>.filled(length, m['value'] ?? m['arg1']);
  }

  FutureOr<Object?> _stdInvoke(Object? input) async {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('std.invoke: expected message');
    }
    final callee = m['callee'];
    if (callee is! Function) {
      throw BallRuntimeError('std.invoke: callee is not callable');
    }
    // Strip metadata keys to get the actual arguments.
    final args = Map<String, Object?>.from(m)
      ..remove('callee')
      ..remove('__type__');
    // Single positional argument: unwrap the sole value so lambdas that
    // take a single param receive the value directly (not wrapped in a map).
    Object? result;
    if (args.length == 1) {
      result = Function.apply(callee, [args.values.first]);
    } else if (args.isEmpty) {
      result = Function.apply(callee, [null]);
    } else {
      result = Function.apply(callee, [args]);
    }
    if (result is Future) result = await result;
    return result;
  }

  Object? _stdNullAwareAccess(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return null;
    final target = m['target'];
    final field = m['field'] as String?;
    if (target == null) return null;
    final targetMap = _stdAsMap(target);
    if (targetMap != null && field != null) {
      return targetMap[field];
    }
    return null;
  }

  Object? _stdNullAwareCall(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return null;
    final target = m['target'];
    if (target == null) return null;
    // In the interpreter, method calls are resolved through function lookup
    return null;
  }

  Object? _stdTypeCheck(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return false;
    final value = m['value'];
    final type = m['type'] as String?;
    if (type == null) return false;
    return _typeMatches(value, type);
  }

  bool _typeMatches(Object? value, String type) {
    // Handle generic types: List<int>, Map<String, int>, etc.
    final genericMatch = RegExp(r'^(\w+)<(.+)>$').firstMatch(type);
    if (genericMatch != null) {
      final baseType = genericMatch.group(1)!;
      final typeArgsStr = genericMatch.group(2)!;
      final typeArgs = _splitTypeArgs(typeArgsStr);

      final listVal = _stdAsList(value);
      if (baseType == 'List' && listVal != null) {
        if (typeArgs.length == 1) {
          return listVal.every((e) => _typeMatches(e, typeArgs[0]));
        }
        return true;
      }
      final mapVal = _stdAsMap(value);
      if (baseType == 'Map' && (mapVal != null || value is Map)) {
        final entries = mapVal?.entries ?? (value as Map).entries;
        if (typeArgs.length == 2) {
          return entries.every(
            (e) =>
                _typeMatches(e.key, typeArgs[0]) &&
                _typeMatches(e.value, typeArgs[1]),
          );
        }
        return true;
      }
      if (baseType == 'Set' && value is Set) {
        if (typeArgs.length == 1) {
          return value.every((e) => _typeMatches(e, typeArgs[0]));
        }
        return true;
      }
      // Check BallObject __type__ with __type_args__
      final objMap = _stdAsMap(value);
      if (objMap != null &&
          _typeNameMatches(objMap['__type__'] as String?, baseType)) {
        final objArgs = objMap['__type_args__'];
        // Handle __type_args__ as a string (e.g., "<int>") or as a List (e.g., ["int"])
        List<String> objTypeArgs = [];
        if (objArgs is String) {
          // Strip angle brackets and split by comma
          final argsStr = objArgs.trim();
          if (argsStr.startsWith('<') && argsStr.endsWith('>')) {
            objTypeArgs = argsStr
                .substring(1, argsStr.length - 1)
                .split(',')
                .map((s) => s.trim())
                .toList();
          } else {
            objTypeArgs = [argsStr];
          }
        } else if (objArgs is List) {
          objTypeArgs = objArgs.map((e) => e.toString()).toList();
        }
        if (objTypeArgs.length == typeArgs.length) {
          for (var i = 0; i < typeArgs.length; i++) {
            if (objTypeArgs[i] != typeArgs[i]) return false;
          }
          return true;
        }
      }
      return false;
    }

    // Simple types
    return switch (type) {
      'int' => value is int || value is BallInt,
      'double' => value is double || value is BallDouble,
      'num' => value is num || value is BallInt || value is BallDouble,
      'String' => value is String || value is BallString,
      'bool' => value is bool || value is BallBool,
      'List' => value is List || value is BallList,
      'Map' => value is Map || value is BallMap,
      'Set' => value is Set,
      'Null' || 'void' => value == null || value is BallNull,
      'Object' || 'dynamic' => true,
      'Function' => value is Function || value is BallFunction,
      _ => _objectTypeMatches(value, type),
    };
  }

  bool _objectTypeMatches(Object? value, String type) {
    final m = _stdAsMap(value);
    if (m == null) return false;
    if (_typeNameMatches(m['__type__'] as String?, type)) return true;
    // Walk __super__ chain
    var superObj = m['__super__'];
    while (superObj != null) {
      final superMap = _stdAsMap(superObj);
      if (superMap == null) break;
      if (_typeNameMatches(superMap['__type__'] as String?, type)) return true;
      superObj = superMap['__super__'];
    }
    return false;
  }

  /// Compare type names accounting for module-qualified forms.
  /// "main:Foo" matches "Foo", "Foo" matches "main:Foo", and exact matches.
  bool _typeNameMatches(String? objType, String checkType) {
    if (objType == null) return false;
    if (objType == checkType) return true;
    // objType is "module:Foo", checkType is "Foo"
    if (objType.endsWith(':$checkType')) return true;
    // objType is "Foo", checkType is "module:Foo"
    if (checkType.endsWith(':$objType')) return true;
    // Both qualified but different modules — strip and compare bare names.
    final objColon = objType.indexOf(':');
    final checkColon = checkType.indexOf(':');
    if (objColon >= 0 && checkColon >= 0) {
      return objType.substring(objColon + 1) ==
          checkType.substring(checkColon + 1);
    }
    return false;
  }

  /// Split generic type arguments, respecting nested angle brackets.
  List<String> _splitTypeArgs(String str) {
    final args = <String>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i < str.length; i++) {
      if (str[i] == '<') depth++;
      if (str[i] == '>') depth--;
      if (str[i] == ',' && depth == 0) {
        args.add(str.substring(start, i).trim());
        start = i + 1;
      }
    }
    args.add(str.substring(start).trim());
    return args;
  }

  Object? _stdMapCreate(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return <String, Object?>{};
    // Support both 'entries' (list of {name, value}) and 'entry' (single or
    // list of {key, value}) formats.
    final entries = m['entries'] ?? m['entry'];
    final entriesList = _stdAsList(entries);
    if (entriesList != null) {
      _trackMemoryAllocation(entriesList.length * _ballMapEntryBytes);
      final result = <Object?, Object?>{};
      for (final entry in entriesList) {
        final entryMap = _stdAsMap(entry);
        if (entryMap != null) {
          final key = entryMap['key'] ?? entryMap['name'];
          result[key] = entryMap['value'];
        }
      }
      return result;
    }
    final entriesMap = _stdAsMap(entries);
    if (entriesMap != null) {
      // Single entry (not wrapped in a list).
      _trackMemoryAllocation(_ballMapEntryBytes);
      final key = entriesMap['key'] ?? entriesMap['name'];
      return <Object?, Object?>{key: entriesMap['value']};
    }
    return <String, Object?>{};
  }

  Object? _stdSetCreate(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return <Object?>{};
    final elements = m['elements'];
    final elementsList = _stdAsList(elements);
    if (elementsList != null) {
      _trackMemoryAllocation(elementsList.length * _ballPointerBytes);
      return elementsList.toSet();
    }
    return <Object?>{};
  }

  Object? _stdRecord(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return input;
    return m['fields'] ?? m;
  }

  FutureOr<Object?> _stdSwitchExpr(Object? input) async {
    final im = _stdAsMap(input);
    if (im == null) return null;
    final subject = im['subject'];
    final rawCases = im['cases'];
    final cases = _stdAsList(rawCases);
    if (cases == null) return null;
    Object? defaultBody;
    for (final c in cases) {
      final cMap = _stdAsMap(c);
      if (cMap == null) continue;
      final pattern = cMap['pattern'];
      final patternExpr = cMap['pattern_expr'];
      final body = cMap['body'];
      final guard = cMap['guard'];
      // Default / wildcard.
      if (cMap['is_default'] == true || pattern == '_') {
        defaultBody = body;
        continue;
      }
      // Try structured pattern matching first.
      final bindings = <String, Object?>{};
      if (_matchPattern(subject, patternExpr ?? pattern, bindings)) {
        // Check guard condition if present.
        if (guard != null && guard is Function) {
          var guardResult = guard(bindings);
          if (guardResult is Future) guardResult = await guardResult;
          if (guardResult != true) continue;
        }
        // If body is a function, call it with bindings to inject destructured vars.
        if (body is Function) {
          var result = body(bindings);
          if (result is Future) result = await result;
          return result;
        }
        return body;
      }
    }
    if (defaultBody != null) return defaultBody;
    throw BallRuntimeError('Non-exhaustive switch expression');
  }

  /// Structured pattern matching supporting Dart 3 patterns.
  ///
  /// Returns `true` if [value] matches [pattern], and populates [bindings]
  /// with any destructured variable names.
  bool _matchPattern(
    Object? value,
    Object? pattern,
    Map<String, Object?> bindings,
  ) {
    if (pattern == null || pattern == '_') return true; // wildcard
    if (pattern is String) return _matchStringPattern(value, pattern, bindings);
    final patternMap = _stdAsMap(pattern);
    if (patternMap != null) {
      return _matchStructuredPattern(value, patternMap, bindings);
    }
    // Direct value equality.
    return pattern == value || pattern.toString() == value?.toString();
  }

  /// Match a string pattern like 'int x', 'String s', '> 5', etc.
  bool _matchStringPattern(
    Object? value,
    String pattern,
    Map<String, Object?> bindings,
  ) {
    final trimmed = pattern.trim();
    if (trimmed == '_') return true; // wildcard

    // Type test with binding: 'int x', 'String name', 'double d'
    final typeBindMatch = RegExp(r'^(\w+)\s+(\w+)$').firstMatch(trimmed);
    if (typeBindMatch != null) {
      final typeName = typeBindMatch.group(1)!;
      final varName = typeBindMatch.group(2)!;
      if (_matchesTypePattern(value, typeName)) {
        bindings[varName] = value;
        return true;
      }
      return false;
    }

    // Const pattern: 'null', 'true', 'false'
    if (trimmed == 'null') return value == null;
    if (trimmed == 'true') return value == true;
    if (trimmed == 'false') return value == false;

    // Relational pattern: '> 5', '< 10', '>= 0', '<= 100', '== 42'
    final relMatch = RegExp(r'^(==|!=|>=|<=|>|<)\s*(.+)$').firstMatch(trimmed);
    if (relMatch != null && value is num) {
      final op = relMatch.group(1)!;
      final rhsStr = relMatch.group(2)!.trim();
      final rhs = num.tryParse(rhsStr);
      if (rhs != null) {
        return switch (op) {
          '==' => value == rhs,
          '!=' => value != rhs,
          '>' => value > rhs,
          '<' => value < rhs,
          '>=' => value >= rhs,
          '<=' => value <= rhs,
          _ => false,
        };
      }
    }

    // Simple type pattern: 'int', 'String', etc.
    if (_matchesTypePattern(value, trimmed)) return true;

    // Direct value equality as fallback.
    if (trimmed == value?.toString()) return true;

    return false;
  }

  /// Match structured pattern maps (e.g., ObjectPattern, ListPattern).
  bool _matchStructuredPattern(
    Object? value,
    Map<String, Object?> pattern,
    Map<String, Object?> bindings,
  ) {
    final kind = _patternKind(pattern);
    switch (kind) {
      case 'type_test':
        // { __pattern_kind__: 'type_test', type: 'int', name: 'x' }
        final typeName = pattern['type'] as String?;
        final varName = pattern['name'] as String?;
        if (typeName != null && _matchesTypePattern(value, typeName)) {
          if (varName != null) bindings[varName] = value;
          return true;
        }
        return false;

      case 'var':
        final typeName = pattern['type'] as String?;
        if (typeName != null && !_matchesTypePattern(value, typeName)) {
          return false;
        }
        final varName = pattern['name'] as String?;
        if (varName != null && varName != '_') bindings[varName] = value;
        return true;

      case 'wildcard':
        final typeName = pattern['type'] as String?;
        return typeName == null || _matchesTypePattern(value, typeName);

      case 'const':
        return _ballEquals(value, pattern['value']);

      case 'relational':
        return _matchRelationalPattern(
          value,
          pattern['operator'] as String?,
          pattern['operand'],
        );

      case 'list':
        // { __pattern_kind__: 'list', elements: [...patterns], rest: 'restVar' }
        final listVal = _stdAsList(value);
        if (listVal == null) return false;
        final elements = _stdAsList(pattern['elements']) ?? const [];
        final restIndex = elements.indexWhere((e) {
          final em = _stdAsMap(e);
          return em != null && _patternKind(em) == 'rest';
        });
        final fixedCount = restIndex == -1
            ? elements.length
            : elements.length - 1;
        if (restIndex == -1 && listVal.length != fixedCount) return false;
        if (restIndex != -1 && listVal.length < fixedCount) return false;
        for (var i = 0; i < elements.length; i++) {
          final elem = elements[i];
          final elemMap = _stdAsMap(elem);
          if (elemMap != null && _patternKind(elemMap) == 'rest') {
            final restValues = listVal.sublist(
              i,
              listVal.length - fixedCount + i,
            );
            final subpattern = elemMap['subpattern'];
            if (subpattern != null &&
                !_matchPattern(restValues, subpattern, bindings)) {
              return false;
            }
            continue;
          }
          final valueIndex = restIndex == -1 || i < restIndex
              ? i
              : listVal.length - (elements.length - i);
          if (!_matchPattern(listVal[valueIndex], elem, bindings)) return false;
        }
        final rest = pattern['rest'] as String?;
        if (rest != null) {
          bindings[rest] = listVal.sublist(fixedCount);
        }
        return true;

      case 'map':
        final mapVal = _stdAsMap(value);
        if (mapVal == null && value is! Map) return false;
        final rawMap = value is Map ? value : mapVal!;
        final entries = _stdAsList(pattern['entries']) ?? const [];
        for (final entry in entries) {
          final entryMap = _stdAsMap(entry);
          if (entryMap == null) return false;
          final key = entryMap['key'];
          if (!rawMap.containsKey(key)) return false;
          if (!_matchPattern(rawMap[key], entryMap['value'], bindings)) {
            return false;
          }
        }
        return true;

      case 'object':
        // { __pattern_kind__: 'object', type: 'Point', fields: {x: patX, y: patY} }
        final objMap = _stdAsMap(value);
        if (objMap == null) return false;
        final objType = pattern['type'] as String?;
        if (objType != null && !_matchesObjectType(objMap, objType))
          return false;
        for (final entry in _patternFields(pattern['fields']).entries) {
          final fieldVal = objMap[entry.key];
          if (!_matchPattern(fieldVal, entry.value, bindings)) return false;
        }
        return true;

      case 'record':
        // { __pattern_kind__: 'record', fields: {named_field: pattern, $1: pattern} }
        final recMap = _stdAsMap(value);
        if (recMap == null) return false;
        for (final entry in _patternFields(pattern['fields']).entries) {
          final fieldVal = recMap[entry.key];
          if (!_matchPattern(fieldVal, entry.value, bindings)) return false;
        }
        return true;

      case 'logical_or':
        // { __pattern_kind__: 'logical_or', left: pat, right: pat }
        final leftBindings = <String, Object?>{};
        if (_matchPattern(value, pattern['left'], leftBindings)) {
          bindings.addAll(leftBindings);
          return true;
        }
        return _matchPattern(value, pattern['right'], bindings);

      case 'logical_and':
        // { __pattern_kind__: 'logical_and', left: pat, right: pat }
        final tempBindings = <String, Object?>{};
        if (_matchPattern(value, pattern['left'], tempBindings) &&
            _matchPattern(value, pattern['right'], tempBindings)) {
          bindings.addAll(tempBindings);
          return true;
        }
        return false;

      case 'cast':
        // { __pattern_kind__: 'cast', type: 'int', name: 'x' }
        final typeName = pattern['type'] as String?;
        if (typeName != null && !_matchesTypePattern(value, typeName)) {
          return false;
        }
        final subpattern = pattern['pattern'];
        if (subpattern != null && !_matchPattern(value, subpattern, bindings)) {
          return false;
        }
        final varName = pattern['name'] as String?;
        if (varName != null) bindings[varName] = value;
        return true;

      case 'null_check':
      case 'null_assert':
        return value != null &&
            _matchPattern(value, pattern['pattern'], bindings);

      case 'rest':
        return _matchPattern(value, pattern['subpattern'], bindings);

      default:
        // No special kind — try value equality on each field.
        final defMap = _stdAsMap(value);
        if (defMap != null) {
          for (final entry in pattern.entries) {
            if (entry.key.startsWith('__')) continue;
            if (!_matchPattern(defMap[entry.key], entry.value, bindings)) {
              return false;
            }
          }
          return true;
        }
        return false;
    }
  }

  String? _patternKind(Map<String, Object?> pattern) {
    final explicit = pattern['__pattern_kind__'] as String?;
    if (explicit != null) return explicit;
    final type = pattern['__type__'] as String?;
    return switch (type) {
      'VarPattern' => 'var',
      'WildcardPattern' => 'wildcard',
      'ConstPattern' => 'const',
      'ListPattern' => 'list',
      'MapPattern' => 'map',
      'RecordPattern' => 'record',
      'ObjectPattern' => 'object',
      'LogicalAndPattern' => 'logical_and',
      'LogicalOrPattern' => 'logical_or',
      'CastPattern' => 'cast',
      'NullCheckPattern' => 'null_check',
      'NullAssertPattern' => 'null_assert',
      'RelationalPattern' => 'relational',
      'RestPattern' => 'rest',
      _ => null,
    };
  }

  Map<String, Object?> _patternFields(Object? fields) {
    final map = _stdAsMap(fields);
    if (map != null) return map;
    final list = _stdAsList(fields);
    if (list == null) return const {};
    final result = <String, Object?>{};
    var positional = 1;
    for (final field in list) {
      final fieldMap = _stdAsMap(field);
      if (fieldMap == null) continue;
      final name = fieldMap['name'] as String?;
      result[(name == null || name.isEmpty) ? '\$${positional++}' : name] =
          fieldMap['pattern'];
    }
    return result;
  }

  bool _matchRelationalPattern(
    Object? value,
    String? operator,
    Object? operand,
  ) {
    if (operator == null) return false;
    return switch (operator) {
      '==' => _ballEquals(value, operand),
      '!=' => !_ballEquals(value, operand),
      '>' => value is num && operand is num && value > operand,
      '<' => value is num && operand is num && value < operand,
      '>=' => value is num && operand is num && value >= operand,
      '<=' => value is num && operand is num && value <= operand,
      _ => false,
    };
  }

  bool _matchesObjectType(Map<String, Object?> value, String patternType) {
    final actual = value['__type__']?.toString();
    if (actual == null) return false;
    if (actual == patternType) return true;
    final actualBare = actual.contains(':') ? actual.split(':').last : actual;
    final patternBare = patternType.contains(':')
        ? patternType.split(':').last
        : patternType;
    return actualBare == patternBare;
  }

  /// Returns true if [value] matches the type-name pattern string.
  /// Enables switch expressions with type arms like `case int: ...`.
  bool _matchesTypePattern(Object? value, String pattern) {
    return switch (pattern) {
      'int' => value is int || value is BallInt,
      'double' => value is double || value is BallDouble,
      'num' => value is num || value is BallInt || value is BallDouble,
      'String' => value is String || value is BallString,
      'bool' => value is bool || value is BallBool,
      'List' => value is List || value is BallList,
      'Map' => value is Map || value is BallMap,
      'Set' => value is Set,
      'Null' || 'null' => value == null || value is BallNull,
      _ => false,
    };
  }

  Object? _stdAssert(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) return null;
    final condition = m['condition'];
    final message = m['message'];
    if (!_toBool(condition)) {
      throw BallRuntimeError(
        'Assertion failed${message != null ? ": $message" : ""}',
      );
    }
    return null;
  }

  // ---- Arithmetic helpers ----

  /// `std.add` — numeric addition or string concatenation.
  Object? _stdAdd(Object? input) {
    final (left, right) = _extractBinaryArgs(input);
    if (left is String || right is String) {
      return '${left ?? ''}${right ?? ''}';
    }
    return _toNum(left) + _toNum(right);
  }

  Object? _stdBinary(Object? input, num Function(num, num) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toNum(left), _toNum(right));
  }

  Object? _stdBinaryInt(Object? input, int Function(int, int) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toInt(left), _toInt(right));
  }

  Object? _stdBinaryDouble(Object? input, double Function(double, double) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toDouble(left), _toDouble(right));
  }

  Object? _stdBinaryComp(Object? input, bool Function(num, num) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toNum(left), _toNum(right));
  }

  Object? _stdBinaryBool(Object? input, bool Function(bool, bool) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toBool(left), _toBool(right));
  }

  Object? _stdBinaryAny(Object? input, Object? Function(Object?, Object?) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(left, right);
  }

  Object? _stdUnaryNum(Object? input, num Function(num) op) {
    final value = _extractUnaryArg(input);
    return op(_toNum(value));
  }

  Object? _stdNot(Object? input) {
    final value = _extractUnaryArg(input);
    return !_toBool(value);
  }

  Object? _stdConcat(Object? input) {
    final (left, right) = _extractBinaryArgs(input);
    final result = '$left$right';
    _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
    return result;
  }

  Object? _stdLength(Object? input) {
    final value = _extractUnaryArg(input);
    if (value is String) return value.length;
    if (value is BallString) return value.value.length;
    final listVal = _stdAsList(value);
    if (listVal != null) return listVal.length;
    throw BallRuntimeError('std.length: unsupported type ${value.runtimeType}');
  }

  Object? _stdConvert(Object? input, Object? Function(Object?) converter) {
    final value = _extractUnaryArg(input);
    return converter(value);
  }

  // ---- Value extraction helpers ----

  (Object?, Object?) _extractBinaryArgs(Object? input) {
    final m = _stdAsMap(input);
    if (m != null) {
      return (m['left'], m['right']);
    }
    throw BallRuntimeError('Expected message with left/right fields');
  }

  Object? _extractUnaryArg(Object? input) {
    final m = _stdAsMap(input);
    if (m != null) return m['value'];
    return input;
  }

  Object? _extractField(Object? input, String name) {
    final m = _stdAsMap(input);
    if (m != null) return m[name];
    return null;
  }

  String? _stringFieldVal(Map<String, Expression> fields, String name) {
    final expr = fields[name];
    if (expr == null) return null;
    if (expr.whichExpr() == Expression_Expr.literal &&
        expr.literal.whichValue() == Literal_Value.stringValue) {
      return expr.literal.stringValue;
    }
    return null;
  }

  int _toInt(Object? v) {
    if (v is int) return v;
    if (v is BallInt) return v.value;
    if (v is double) return v.toInt();
    if (v is BallDouble) return v.value.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    if (v is BallString) return int.tryParse(v.value) ?? 0;
    if (v is bool) return v ? 1 : 0;
    if (v is BallBool) return v.value ? 1 : 0;
    return 0;
  }

  double _toDouble(Object? v) {
    if (v is double) return v;
    if (v is BallDouble) return v.value;
    if (v is int) return v.toDouble();
    if (v is BallInt) return v.value.toDouble();
    if (v is String) return double.parse(v);
    if (v is BallString) return double.parse(v.value);
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to double');
  }

  num _toNum(Object? v) {
    if (v is num) return v;
    if (v is BallInt) return v.value;
    if (v is BallDouble) return v.value;
    if (v is String) return num.tryParse(v) ?? 0;
    if (v is BallString) return num.tryParse(v.value) ?? 0;
    if (v is bool) return v ? 1 : 0;
    if (v is BallBool) return v.value ? 1 : 0;
    if (v == null || v is BallNull) return 0;
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to num');
  }

  /// Convert a runtime value to an iterable list for for_in loops.
  /// Handles List, Set, Map (iterates entries as {key, value} maps), and String.
  List<Object?> _toIterable(Object? v) {
    if (v is BallList) return v.items;
    if (v is List) return v;
    if (v is Set) return v.toList();
    if (v is BallMap) {
      return v.entries.entries
          .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
          .toList();
    }
    if (v is Map) {
      return v.entries
          .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
          .toList();
    }
    if (v is String) return v.split('');
    throw BallRuntimeError('for_in: value is not iterable (${v.runtimeType})');
  }

  bool _toBool(Object? v) {
    if (v is bool) return v;
    if (v is BallBool) return v.value;
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to bool');
  }

  // ---- String helpers ----

  Object? _stdStringSubstring(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('Expected message');
    }
    final value = m['value'] as String;
    final start = _toInt(m['start']);
    final end = m['end'];
    final result = end != null
        ? value.substring(start, _toInt(end))
        : value.substring(start);
    _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
    return result;
  }

  Object? _stdStringCharAt(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('Expected message');
    }
    final target = m['target'] as String;
    final index = _toInt(m['index']);
    return target[index];
  }

  Object? _stdStringCharCodeAt(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('Expected message');
    }
    final target = (m['target'] ?? m['value'] ?? m['string']) as String;
    final index = _toInt(m['index']);
    return target.codeUnitAt(index);
  }

  Object? _stdStringReplace(Object? input, bool all) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('Expected message');
    }
    final value = m['value'] as String;
    final from = m['from'] as String;
    final to = m['to'] as String;
    final result = all
        ? value.replaceAll(from, to)
        : value.replaceFirst(from, to);
    _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
    return result;
  }

  Object? _stdRegexReplace(Object? input, bool all) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('Expected message');
    }
    final value = m['value'] as String;
    final from = m['from'] as String;
    final to = m['to'] as String;
    final pattern = RegExp(from);
    final result = all
        ? value.replaceAll(pattern, to)
        : value.replaceFirst(pattern, to);
    _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
    return result;
  }

  Object? _stdStringRepeat(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('Expected message');
    }
    final value = m['value'] as String;
    final count = _toInt(m['count']);
    final result = value * count;
    _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
    return result;
  }

  Object? _stdStringPad(Object? input, bool left) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('Expected message');
    }
    final value = m['value'] as String;
    final width = _toInt(m['width']);
    final padding = (m['padding'] as String?) ?? ' ';
    final result = left
        ? value.padLeft(width, padding)
        : value.padRight(width, padding);
    _trackMemoryAllocation(result.length * _ballStringCodeUnitBytes);
    return result;
  }

  // ---- Math helpers (using dart:math would need import, so inline) ----

  Object? _stdMathUnary(Object? input, double Function(double) op) {
    final value = _extractUnaryArg(input);
    return op(_toDouble(value));
  }

  Object? _stdMathBinary(Object? input, double Function(double, double) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toDouble(left), _toDouble(right));
  }

  Object? _stdMathClamp(Object? input) {
    final m = _stdAsMap(input);
    if (m == null) {
      throw BallRuntimeError('Expected message');
    }
    // Handle static method style: math_clamp({value: classRef, min: val, max: lo, arg2: hi})
    // where value is a class reference object, not a number.
    final rawValue = m['value'];
    num value;
    num min;
    num max;
    if (rawValue is Map<String, Object?> || rawValue is BallMap) {
      // Static method dispatch: shift args.
      value = _toNum(m['min']);
      min = _toNum(m['max']);
      max = _toNum(m['arg2']);
    } else {
      value = _toNum(rawValue);
      min = _toNum(m['min']);
      max = _toNum(m['max']);
    }
    return value.clamp(min, max);
  }

  // ---- std_convert helpers ----

  String _jsonEncode(Object? value) {
    return const JsonEncoder().convert(_toJsonSafe(value));
  }

  Object? _jsonDecode(String text) {
    return const JsonDecoder().convert(text);
  }

  /// Recursively prepare a value for JSON encoding, stripping internal keys.
  Object? _toJsonSafe(Object? v) {
    if (v == null || v is BallNull) return null;
    if (v is BallInt) return v.value;
    if (v is BallDouble) return v.value;
    if (v is BallBool) return v.value;
    if (v is BallString) return v.value;
    if (v is num || v is bool || v is String) return v;
    final mapVal = _stdAsMap(v);
    if (mapVal != null) {
      return {
        for (final e in mapVal.entries)
          if (!e.key.startsWith('__')) e.key: _toJsonSafe(e.value),
      };
    }
    if (v is Map) {
      return {
        for (final e in v.entries)
          if (e.key is String && !(e.key as String).startsWith('__'))
            e.key: _toJsonSafe(e.value),
      };
    }
    final listVal = _stdAsList(v);
    if (listVal != null) return listVal.map(_toJsonSafe).toList();
    if (v is Set) return v.map(_toJsonSafe).toList();
    return v.toString();
  }

  List<int> _utf8Encode(String s) => utf8.encode(s);
  String _utf8Decode(List<int> bytes) => utf8.decode(bytes);
  String _base64Encode(List<int> bytes) => base64.encode(bytes);
  List<int> _base64Decode(String s) => base64.decode(s);

  /// Throws [BallRuntimeError] when [op] is invoked under sandbox mode.
  void _checkSandbox(String op) {
    if (sandbox) {
      throw BallRuntimeError('Sandbox violation: $op is not allowed');
    }
  }

  // ---- std_fs helpers ----

  Object? _stdFileRead(Object? input) {
    _checkSandbox('file_read');
    final m = _stdAsMap(input);
    final path = m != null ? m['path'] as String? ?? '' : '$input';
    return io.File(path).readAsStringSync();
  }

  Object? _stdFileReadBytes(Object? input) {
    _checkSandbox('file_read_bytes');
    final m = _stdAsMap(input);
    final path = m != null ? m['path'] as String? ?? '' : '$input';
    return io.File(path).readAsBytesSync().toList();
  }

  Object? _stdFileWrite(Object? input) {
    _checkSandbox('file_write');
    final m = _stdAsMap(input)!;
    io.File(m['path'] as String).writeAsStringSync(m['content'] as String);
    return null;
  }

  Object? _stdFileWriteBytes(Object? input) {
    _checkSandbox('file_write_bytes');
    final m = _stdAsMap(input)!;
    io.File(m['path'] as String).writeAsBytesSync(m['content'] as List<int>);
    return null;
  }

  Object? _stdFileAppend(Object? input) {
    _checkSandbox('file_append');
    final m = _stdAsMap(input)!;
    io.File(
      m['path'] as String,
    ).writeAsStringSync(m['content'] as String, mode: io.FileMode.append);
    return null;
  }

  Object? _stdFileExists(Object? input) {
    _checkSandbox('file_exists');
    final m = _stdAsMap(input);
    final path = m != null ? m['path'] as String? ?? '' : '$input';
    return io.File(path).existsSync();
  }

  Object? _stdFileDelete(Object? input) {
    _checkSandbox('file_delete');
    final m = _stdAsMap(input);
    final path = m != null ? m['path'] as String? ?? '' : '$input';
    io.File(path).deleteSync();
    return null;
  }

  Object? _stdDirList(Object? input) {
    _checkSandbox('dir_list');
    final m = _stdAsMap(input);
    final path = m != null ? m['path'] as String? ?? '' : '$input';
    return io.Directory(path).listSync().map((e) => e.path).toList();
  }

  Object? _stdDirCreate(Object? input) {
    _checkSandbox('dir_create');
    final m = _stdAsMap(input);
    final path = m != null ? m['path'] as String? ?? '' : '$input';
    io.Directory(path).createSync(recursive: true);
    return null;
  }

  Object? _stdDirExists(Object? input) {
    _checkSandbox('dir_exists');
    final m = _stdAsMap(input);
    final path = m != null ? m['path'] as String? ?? '' : '$input';
    return io.Directory(path).existsSync();
  }
}

// Math function implementations using dart:math.
double _mathSqrt(double v) => math.sqrt(v);
double _mathPow(double a, double b) => math.pow(a, b).toDouble();
double _mathLog(double v) => math.log(v);
double _mathExp(double v) => math.exp(v);
double _mathSin(double v) => math.sin(v);
double _mathCos(double v) => math.cos(v);
double _mathTan(double v) => math.tan(v);
double _mathAsin(double v) => math.asin(v);
double _mathAcos(double v) => math.acos(v);
double _mathAtan(double v) => math.atan(v);
double _mathAtan2(double a, double b) => math.atan2(a, b);
