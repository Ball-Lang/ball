part of 'engine.dart';

extension BallEngineControlFlow on BallEngine {
  Map<String, Object?>? _cfAsMap(Object? v) {
    if (v is BallMap) return v.entries;
    if (v is Map<String, Object?>) return v;
    return null;
  }

  Map<String, Expression> _lazyFields(FunctionCall call) {
    if (!call.hasInput() ||
        call.input.whichExpr() != Expression_Expr.messageCreation) {
      return {};
    }
    final result = <String, Expression>{};
    for (final f in call.input.messageCreation.fields) {
      result[f.name] = f.value;
    }
    return result;
  }

  Future<Object?> _evalLazyIf(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final condition = fields['condition'];
    final thenBranch = fields['then'];
    final elseBranch = fields['else'];
    if (condition == null || thenBranch == null) {
      throw BallRuntimeError('std.if missing condition or then');
    }
    final condVal = await _evalExpression(condition, scope);
    if (_toBool(condVal)) {
      return _evalExpression(thenBranch, scope);
    } else if (elseBranch != null) {
      return _evalExpression(elseBranch, scope);
    }
    return null;
  }

  Future<Object?> _evalLazyFor(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final initExpr = fields['init'];
    final condition = fields['condition'];
    final update = fields['update'];
    final body = fields['body'];

    // Create a dedicated for-loop scope so that variables declared
    // in the init (e.g. `var i = 0`) are visible in condition/body/update.
    final forScope = scope.child();

    if (initExpr != null) {
      // For-loop init may be:
      //   1. A block with let statements — evaluate directly in forScope
      //   2. A string literal "var i = 0" — parse and bind the variable
      //   3. Anything else — evaluate normally
      if (initExpr.whichExpr() == Expression_Expr.block) {
        for (final stmt in initExpr.block.statements) {
          await _evalStatement(stmt, forScope);
        }
      } else if (initExpr.whichExpr() == Expression_Expr.literal &&
          initExpr.literal.hasStringValue()) {
        // Parse "var name = value" or "final name = value"
        final s = initExpr.literal.stringValue;
        final match = RegExp(
          r'(?:var|final|int|double|String)\s+(\w+)\s*=\s*(.+)',
        ).firstMatch(s);
        if (match != null) {
          final varName = match.group(1)!;
          final rawVal = match.group(2)!.trim();
          // Try parsing as simple literal first.
          final intParsed = int.tryParse(rawVal);
          final doubleParsed = intParsed == null ? double.tryParse(rawVal) : null;
          Object? parsed;
          if (intParsed != null) {
            parsed = intParsed;
          } else if (doubleParsed != null) {
            parsed = doubleParsed;
          } else if (rawVal == 'true') {
            parsed = true;
          } else if (rawVal == 'false') {
            parsed = false;
          } else {
            // Try evaluating as a simple expression in the current scope.
            parsed = _evalSimpleInitExpr(rawVal, forScope);
          }
          forScope.bind(varName, parsed);
        }
      } else {
        await _evalExpression(initExpr, forScope);
      }
    }

    while (true) {
      if (condition != null) {
        final condVal = await _evalExpression(condition, forScope);
        if (!_toBool(condVal)) break;
      }
      if (body != null) {
        final result = await _evalExpression(body, forScope);
        if (result is _FlowSignal) {
          // Labeled break/continue propagate upward to the enclosing
          // `labeled` wrapper. Only unlabeled signals are consumed by
          // the immediate loop.
          if (result.kind == 'return') return result;
          if (result.label != null && result.label!.isNotEmpty) {
            return result;
          }
          if (result.kind == 'break') break;
          // unlabeled continue: fall through to update
        }
      }
      if (update != null) await _evalExpression(update, forScope);
    }
    return null;
  }

  /// Evaluate a simple expression string from a for-loop init.
  /// Handles patterns like: "5", "s.length - 1", "i * i", "n", "arr.length".
  Object? _evalSimpleInitExpr(String rawVal, _Scope scope) {
    // "var.prop OP number" pattern (e.g., "s.length - 1").
    final propOpNum = RegExp(r'^(\w+)\.(\w+)\s*([+\-*/])\s*(\d+)$').firstMatch(rawVal);
    if (propOpNum != null) {
      final ref = propOpNum.group(1)!;
      final prop = propOpNum.group(2)!;
      final op = propOpNum.group(3)!;
      final operand = int.parse(propOpNum.group(4)!);
      if (scope.has(ref)) {
        final obj = scope.lookup(ref);
        num? propVal;
        if (obj is BallString && prop == 'length') propVal = obj.value.length;
        else if (obj is String && prop == 'length') propVal = obj.length;
        else if (obj is BallList && prop == 'length') propVal = obj.items.length;
        else if (obj is List && prop == 'length') propVal = obj.length;
        else if (obj is BallMap && prop == 'length') propVal = obj.entries.length;
        else if (obj is Map && prop == 'length') propVal = obj.length;
        else {
          final map = _cfAsMap(obj);
          if (map != null && map.containsKey(prop)) {
            final v = map[prop];
            if (v is num) propVal = v;
          }
        }
        if (propVal != null) {
          return switch (op) {
            '+' => propVal + operand,
            '-' => propVal - operand,
            '*' => propVal * operand,
            '/' => propVal ~/ operand,
            _ => rawVal,
          };
        }
      }
    }

    // "var OP var" pattern (e.g., "i * i", "n + 1").
    final varOpVar = RegExp(r'^(\w+)\s*([+\-*/])\s*(\w+)$').firstMatch(rawVal);
    if (varOpVar != null) {
      final left = varOpVar.group(1)!;
      final op = varOpVar.group(2)!;
      final right = varOpVar.group(3)!;
      num? leftVal, rightVal;
      if (scope.has(left)) { final v = scope.lookup(left); if (v is num) leftVal = v; }
      final rightNum = int.tryParse(right);
      if (rightNum != null) { rightVal = rightNum; }
      else if (scope.has(right)) { final v = scope.lookup(right); if (v is num) rightVal = v; }
      if (leftVal != null && rightVal != null) {
        return switch (op) {
          '+' => leftVal + rightVal,
          '-' => leftVal - rightVal,
          '*' => leftVal * rightVal,
          '/' => leftVal ~/ rightVal,
          _ => rawVal,
        };
      }
    }

    // "var.prop" pattern (e.g., "arr.length").
    final propAccess = RegExp(r'^(\w+)\.(\w+)$').firstMatch(rawVal);
    if (propAccess != null) {
      final ref = propAccess.group(1)!;
      final prop = propAccess.group(2)!;
      if (scope.has(ref)) {
        final obj = scope.lookup(ref);
        if (obj is BallString && prop == 'length') return obj.value.length;
        if (obj is String && prop == 'length') return obj.length;
        if (obj is BallList && prop == 'length') return obj.items.length;
        if (obj is List && prop == 'length') return obj.length;
        if (obj is BallMap && prop == 'length') return obj.entries.length;
        if (obj is Map && prop == 'length') return obj.length;
        final map = _cfAsMap(obj);
        if (map != null && map.containsKey(prop)) return map[prop];
      }
    }

    // Variable reference.
    if (scope.has(rawVal)) return scope.lookup(rawVal);

    return rawVal;
  }

  Future<Object?> _evalLazyForIn(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final variable = _stringFieldVal(fields, 'variable') ?? 'item';
    final iterable = fields['iterable'];
    final body = fields['body'];
    if (iterable == null || body == null) return null;

    final iterVal = await _evalExpression(iterable, scope);
    final items = _toIterable(iterVal);
    for (final item in items) {
      final loopScope = scope.child();
      loopScope.bind(variable, item);
      final result = await _evalExpression(body, loopScope);
      if (result is _FlowSignal) {
        if (result.kind == 'return') return result;
        if (result.label != null && result.label!.isNotEmpty) {
          return result;
        }
        if (result.kind == 'break') break;
      }
    }
    return null;
  }

  Future<Object?> _evalLazyWhile(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final condition = fields['condition'];
    final body = fields['body'];
    while (true) {
      if (condition != null) {
        final condVal = await _evalExpression(condition, scope);
        if (!_toBool(condVal)) break;
      }
      if (body != null) {
        final result = await _evalExpression(body, scope);
        if (result is _FlowSignal) {
          if (result.kind == 'return') return result;
          if (result.label != null && result.label!.isNotEmpty) {
            return result;
          }
          if (result.kind == 'break') break;
        }
      }
    }
    return null;
  }

  Future<Object?> _evalLazyDoWhile(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final body = fields['body'];
    final condition = fields['condition'];
    do {
      if (body != null) {
        final result = await _evalExpression(body, scope);
        if (result is _FlowSignal) {
          if (result.kind == 'return') return result;
          if (result.label != null && result.label!.isNotEmpty) {
            return result;
          }
          if (result.kind == 'break') break;
        }
      }
      if (condition != null) {
        final condVal = await _evalExpression(condition, scope);
        if (!_toBool(condVal)) break;
      } else {
        break;
      }
    } while (true);
    return null;
  }

  Future<Object?> _evalLazySwitch(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final subject = fields['subject'];
    final cases = fields['cases'];
    if (subject == null || cases == null) return null;

    final subjectVal = await _evalExpression(subject, scope);
    if (cases.whichExpr() != Expression_Expr.literal ||
        cases.literal.whichValue() != Literal_Value.listValue) {
      return null;
    }
    Expression? defaultBody;
    var matched = false;
    for (final caseExpr in cases.literal.listValue.elements) {
      if (caseExpr.whichExpr() != Expression_Expr.messageCreation) continue;
      final cf = <String, Expression>{};
      for (final f in caseExpr.messageCreation.fields) {
        cf[f.name] = f.value;
      }
      final isDefault = cf['is_default'];
      if (isDefault != null &&
          isDefault.whichExpr() == Expression_Expr.literal &&
          isDefault.literal.boolValue) {
        defaultBody = cf['body'];
        continue;
      }

      if (!matched) {
        // Standard value-based case.
        final value = cf['value'];
        if (value != null) {
          final caseVal = await _evalExpression(value, scope);
          if (_ballEquals(caseVal, subjectVal)) matched = true;
        }
        // Pattern-based case (e.g., ConstPattern).
        if (!matched) {
          final patternExpr = cf['pattern_expr'];
          if (patternExpr != null) {
            final pattern = await _evalExpression(patternExpr, scope);
            final patternMap = _cfAsMap(pattern);
            final patternVal = (patternMap != null && patternMap.containsKey('value'))
                ? patternMap['value']
                : pattern;
            if (_ballEquals(patternVal, subjectVal)) matched = true;
          }
        }
        // String pattern matching (e.g., "Color.red" matching enum values).
        if (!matched) {
          final patternField = cf['pattern'];
          if (patternField != null) {
            final patternStr = patternField.whichExpr() == Expression_Expr.literal &&
                patternField.literal.whichValue() == Literal_Value.stringValue
                ? patternField.literal.stringValue
                : null;
            if (patternStr != null) {
              matched = _matchSwitchPattern(subjectVal, patternStr);
            }
          }
        }
      }

      // If matched, execute the body. Support fall-through: if body is empty,
      // continue to the next case.
      if (matched) {
        final body = cf['body'];
        if (body != null) {
          // Check for empty block (fall-through).
          if (body.whichExpr() == Expression_Expr.block &&
              body.block.statements.isEmpty &&
              !body.block.hasResult()) {
            continue; // fall-through
          }
          final result = await _evalExpression(body, scope);
          // Consume unlabeled break (switch break, not loop break).
          if (result is _FlowSignal && result.kind == 'break' && result.label == null) {
            return null;
          }
          return result;
        }
      }
    }
    if (defaultBody != null) {
      final result = await _evalExpression(defaultBody, scope);
      if (result is _FlowSignal && result.kind == 'break' && result.label == null) {
        return null;
      }
      return result;
    }
    return null;
  }

  /// Compare two Ball values for equality, handling int/double coercion.
  bool _ballEquals(Object? a, Object? b) {
    if (a == b) return true;
    // Compare numbers with int/double coercion.
    if (a is num && b is num) return a == b;
    // String representation equality as fallback.
    if (a != null && b != null) return a.toString() == b.toString();
    return false;
  }

  /// Match a switch pattern string against a subject value.
  ///
  /// Handles patterns like "Color.red" for enum matching, simple type
  /// patterns like "int x", and constant patterns.
  bool _matchSwitchPattern(Object? subject, String pattern) {
    // Enum pattern: "EnumType.value" (e.g., "Color.red").
    final dotIdx = pattern.indexOf('.');
    if (dotIdx >= 0) {
      final enumType = pattern.substring(0, dotIdx);
      final enumValue = pattern.substring(dotIdx + 1);
      // Subject is an enum value map with __type__ and name fields.
      final subjectMap = _cfAsMap(subject);
      if (subjectMap != null) {
        final typeName = subjectMap['__type__'] as String?;
        if (typeName != null) {
          // Match "Color" against "main:Color" (strip module prefix).
          final colonIdx = typeName.indexOf(':');
          final bareType = colonIdx >= 0 ? typeName.substring(colonIdx + 1) : typeName;
          if (bareType == enumType && subjectMap['name'] == enumValue) return true;
          if (typeName == enumType && subjectMap['name'] == enumValue) return true;
        }
      }
      // Also try resolving the pattern to an actual enum value and comparing.
      final enumVals = _enumValues[enumType];
      if (enumVals != null && enumVals.containsKey(enumValue)) {
        final resolved = enumVals[enumValue];
        final resolvedMap = _cfAsMap(resolved);
        if (subjectMap != null && resolvedMap != null) {
          return subjectMap['__type__'] == resolvedMap['__type__'] &&
              subjectMap['name'] == resolvedMap['name'];
        }
      }
      // Try with module-qualified enum type.
      final qualifiedEnumType = '$_currentModule:$enumType';
      final qualEnumVals = _enumValues[qualifiedEnumType];
      if (qualEnumVals != null && qualEnumVals.containsKey(enumValue)) {
        final resolved = qualEnumVals[enumValue];
        final resolvedMap = _cfAsMap(resolved);
        if (subjectMap != null && resolvedMap != null) {
          return subjectMap['__type__'] == resolvedMap['__type__'] &&
              subjectMap['name'] == resolvedMap['name'];
        }
      }
    }

    // Constant patterns: "null", "true", "false", numbers.
    if (pattern == 'null') return subject == null;
    if (pattern == 'true') return subject == true;
    if (pattern == 'false') return subject == false;
    final numVal = num.tryParse(pattern);
    if (numVal != null && subject is num) return _ballEquals(subject, numVal);

    // Type test pattern: "int", "String", etc.
    if (_matchesTypePattern(subject, pattern)) return true;

    // Direct string equality.
    return pattern == subject?.toString();
  }

  Future<Object?> _evalLazyTry(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final body = fields['body'];
    final catches = fields['catches'];
    final finallyBlock = fields['finally'];

    Object? result;
    try {
      result = body != null ? await _evalExpression(body, scope) : null;
    } catch (e, stackTrace) {
      result = null;
      if (catches != null &&
          catches.whichExpr() == Expression_Expr.literal &&
          catches.literal.whichValue() == Literal_Value.listValue) {
        var caught = false;
        for (final catchExpr in catches.literal.listValue.elements) {
          if (catchExpr.whichExpr() != Expression_Expr.messageCreation) {
            continue;
          }
          final cf = <String, Expression>{};
          for (final f in catchExpr.messageCreation.fields) {
            cf[f.name] = f.value;
          }
          // Typed catch: when `type` is set, match either
          //   (a) a BallException whose typeName matches, or
          //   (b) a real Dart exception whose runtimeType name matches
          //       (e.g. `on FormatException catch (e)` from `int.parse`).
          // Untyped catches match any exception.
          final catchType = _stringFieldVal(cf, 'type');
          if (catchType != null && catchType.isNotEmpty) {
            bool matches;
            if (e is BallException) {
              // Match fully-qualified or bare type name.
              // e.typeName may be "main:FormatException", catchType may be "FormatException".
              final eType = e.typeName;
              final eColonIdx = eType.indexOf(':');
              final eBare = eColonIdx >= 0 ? eType.substring(eColonIdx + 1) : eType;
              matches = eType == catchType || eBare == catchType;
            } else if (e is Map && e['__type__'] != null) {
              final eType = e['__type__'].toString();
              final eColonIdx = eType.indexOf(':');
              final eBare = eColonIdx >= 0 ? eType.substring(eColonIdx + 1) : eType;
              matches = eType == catchType || eBare == catchType;
            } else {
              matches = e.runtimeType.toString() == catchType;
            }
            if (!matches) continue;
          }
          final variable = _stringFieldVal(cf, 'variable') ?? 'e';
          final stackVariable = _stringFieldVal(cf, 'stack_trace');
          final catchBody = cf['body'];
          if (catchBody != null) {
            final catchScope = scope.child();
            // Bind original thrown value for BallException (so catch
            // bodies can read field data); fall back to string form for
            // real Dart runtime errors.
            catchScope.bind(variable, e is BallException ? e.value : e.toString());
            // Bind the stack-trace variable when the source was
            // `catch (e, stack) { ... }`. We use the trace Dart
            // captured at the outer `catch (e, stackTrace)` above so
            // the binding reflects the real unwinding point.
            if (stackVariable != null && stackVariable.isNotEmpty) {
              catchScope.bind(stackVariable, stackTrace);
            }
            // Save/restore the active exception so `rethrow` re-raises
            // the original error and nested tries unwind cleanly.
            final previousActive = _activeException;
            _activeException = e;
            try {
              result = await _evalExpression(catchBody, catchScope);
            } finally {
              _activeException = previousActive;
            }
            caught = true;
            break;
          }
        }
        if (!caught) rethrow;
      } else {
        rethrow;
      }
    } finally {
      if (finallyBlock != null) {
        await _evalExpression(finallyBlock, scope);
      }
    }
    return result;
  }

  Future<Object?> _evalShortCircuitAnd(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final left = fields['left'];
    final right = fields['right'];
    if (left == null || right == null) return false;
    final leftVal = await _evalExpression(left, scope);
    if (!_toBool(leftVal)) return false;
    return _toBool(await _evalExpression(right, scope));
  }

  Future<Object?> _evalShortCircuitOr(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final left = fields['left'];
    final right = fields['right'];
    if (left == null || right == null) return false;
    final leftVal = await _evalExpression(left, scope);
    if (_toBool(leftVal)) return true;
    return _toBool(await _evalExpression(right, scope));
  }

  Future<Object?> _evalReturn(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final value = fields['value'];
    final val = value != null ? await _evalExpression(value, scope) : null;
    return _FlowSignal('return', value: val);
  }

  Future<Object?> _evalBreak(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    return _FlowSignal('break', label: label);
  }

  Future<Object?> _evalContinue(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    return _FlowSignal('continue', label: label);
  }

  Future<Object?> _evalAssign(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final target = fields['target'];
    final value = fields['value'];
    if (target == null || value == null) return null;

    final op = _stringFieldVal(fields, 'op');

    // For ??= we must check the current value BEFORE evaluating the RHS,
    // because Dart's ??= short-circuits (does not evaluate RHS if LHS is
    // non-null).
    if (op == '??=') {
      return _evalNullAwareAssign(target, value, scope);
    }

    // Detect in-place mutation pattern: assign(target: var, value: list_remove_at(list: var, ...))
    // When the list argument and target reference the same variable, the mutation
    // already happens in place. Return the removed element without overwriting the variable.
    if (target.whichExpr() == Expression_Expr.reference &&
        value.whichExpr() == Expression_Expr.call) {
      final valFn = value.call.function;
      final valMod = value.call.module;
      if ((valFn == 'list_remove_at' || valFn == 'list_pop' || valFn == 'list_remove_last') &&
          (valMod == 'std' || valMod == 'std_collections' || valMod.isEmpty)) {
        final valFields = _lazyFields(value.call);
        final listExpr = valFields['list'];
        if (listExpr != null &&
            listExpr.whichExpr() == Expression_Expr.reference &&
            listExpr.reference.name == target.reference.name) {
          // In-place mutation: evaluate value (mutates the list) and return it.
          return await _evalExpression(value, scope);
        }
      }
    }

    final val = await _evalExpression(value, scope);

    // Simple reference assignment
    if (target.whichExpr() == Expression_Expr.reference) {
      final name = target.reference.name;
      if (op != null && op.isNotEmpty && op != '=') {
        final current = scope.lookup(name);
        final computed = _applyCompoundOp(op, current, val);
        scope.set(name, computed);
        _syncFieldToSelf(scope, name, computed);
        // Also sync to global scope for top-level mutable variables.
        if (_globalScope.has(name) && !scope.has(name)) {
          _globalScope.set(name, computed);
        }
        return computed;
      }
      scope.set(name, val);
      _syncFieldToSelf(scope, name, val);
      // Also sync to global scope for top-level mutable variables.
      if (_globalScope.has(name)) {
        _globalScope.set(name, val);
      }
      return val;
    }

    // Field access assignment (obj.field = val)
    if (target.whichExpr() == Expression_Expr.fieldAccess) {
      final obj = await _evalExpression(target.fieldAccess.object, scope);
      final map = _cfAsMap(obj);
      if (map != null) {
        final fieldName = target.fieldAccess.field_2;

        // Compound assignment on field access (e.g. obj.field ??= val)
        if (op != null && op.isNotEmpty && op != '=') {
          final current = map[fieldName];
          final computed = _applyCompoundOp(op, current, val);
          map[fieldName] = computed;
          return computed;
        }

        // Check for a setter function before falling back to map write.
        final setterResult = await _trySetterDispatch(map, fieldName, val);
        if (setterResult != _sentinel) return setterResult;

        map[fieldName] = val;
        return val;
      }
    }

    // Index assignment (list[i] = val)
    if (target.whichExpr() == Expression_Expr.call &&
        target.call.module == 'std' &&
        target.call.function == 'index') {
      final indexFields = _lazyFields(target.call);
      final indexTarget = indexFields['target'];
      final indexExpr = indexFields['index'];
      if (indexTarget != null && indexExpr != null) {
        final list = await _evalExpression(indexTarget, scope);
        final idx = await _evalExpression(indexExpr, scope);

        // Compound assignment on index (e.g. list[i] ??= val, map[k] += val)
        if (op != null && op.isNotEmpty && op != '=') {
          if (list is BallList && idx is int) {
            final current = list.items[idx];
            final computed = _applyCompoundOp(op, current, val);
            list.items[idx] = computed;
            return computed;
          }
          if (list is List && idx is int) {
            final current = list[idx];
            final computed = _applyCompoundOp(op, current, val);
            list[idx] = computed;
            return computed;
          }
          if (list is BallMap && idx is String) {
            final current = list.entries[idx];
            final computed = _applyCompoundOp(op, current, val);
            list.entries[idx] = computed;
            return computed;
          }
          if (list is Map) {
            final current = list[idx];
            final computed = _applyCompoundOp(op, current, val);
            list[idx] = computed;
            return computed;
          }
        }

        if (list is BallList && idx is int) {
          list.items[idx] = val;
          return val;
        }
        if (list is List && idx is int) {
          list[idx] = val;
          return val;
        }
        if (list is BallMap && idx is String) {
          list.entries[idx] = val;
          return val;
        }
        if (list is Map) {
          list[idx] = val;
          return val;
        }
      }
    }

    return val;
  }

  /// Handle `??=` with short-circuit semantics: evaluate the RHS only when
  /// the current value of the target is `null`.
  Future<Object?> _evalNullAwareAssign(
    Expression target,
    Expression value,
    _Scope scope,
  ) async {
    // Simple reference: x ??= val
    if (target.whichExpr() == Expression_Expr.reference) {
      final name = target.reference.name;
      final current = scope.lookup(name);
      if (current != null) return current;
      final val = await _evalExpression(value, scope);
      scope.set(name, val);
      return val;
    }

    // Field access: obj.field ??= val
    if (target.whichExpr() == Expression_Expr.fieldAccess) {
      final obj = await _evalExpression(target.fieldAccess.object, scope);
      final map = _cfAsMap(obj);
      if (map != null) {
        final fieldName = target.fieldAccess.field_2;
        final current = map[fieldName];
        if (current != null) return current;
        final val = await _evalExpression(value, scope);
        map[fieldName] = val;
        return val;
      }
    }

    // Index: list[i] ??= val  /  map[k] ??= val
    if (target.whichExpr() == Expression_Expr.call &&
        target.call.module == 'std' &&
        target.call.function == 'index') {
      final indexFields = _lazyFields(target.call);
      final indexTarget = indexFields['target'];
      final indexExpr = indexFields['index'];
      if (indexTarget != null && indexExpr != null) {
        final list = await _evalExpression(indexTarget, scope);
        final idx = await _evalExpression(indexExpr, scope);
        if (list is BallList && idx is int) {
          final current = list.items[idx];
          if (current != null) return current;
          final val = await _evalExpression(value, scope);
          list.items[idx] = val;
          return val;
        }
        if (list is List && idx is int) {
          final current = list[idx];
          if (current != null) return current;
          final val = await _evalExpression(value, scope);
          list[idx] = val;
          return val;
        }
        if (list is BallMap && idx is String) {
          final current = list.entries[idx];
          if (current != null) return current;
          final val = await _evalExpression(value, scope);
          list.entries[idx] = val;
          return val;
        }
        if (list is Map) {
          final current = list[idx];
          if (current != null) return current;
          final val = await _evalExpression(value, scope);
          list[idx] = val;
          return val;
        }
      }
    }

    // Fallback: evaluate and return
    return _evalExpression(value, scope);
  }

  /// Handle ++/-- as lazy scope-mutating operations.
  Future<Object?> _evalIncDec(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final valueExpr = fields['value'];
    if (valueExpr == null) return null;

    // Must be a reference so we can update the variable in scope.
    if (valueExpr.whichExpr() == Expression_Expr.reference) {
      final name = valueExpr.reference.name;
      final current = _toNum(scope.lookup(name));
      final isInc = call.function.contains('increment');
      final isPre = call.function.startsWith('pre');
      final updated = isInc ? current + 1 : current - 1;
      scope.set(name, updated);
      _syncFieldToSelf(scope, name, updated);
      if (_globalScope.has(name)) {
        _globalScope.set(name, updated);
      }
      return isPre ? updated : current;
    }

    // Index-based increment/decrement: value is std.index(target, index)
    // e.g. count[x]++ => post_increment(value=index(target=count, index=x))
    if (valueExpr.whichExpr() == Expression_Expr.call &&
        valueExpr.call.function == 'index' &&
        (valueExpr.call.module == 'std' || valueExpr.call.module.isEmpty)) {
      final indexFields = _lazyFields(valueExpr.call);
      final targetExpr = indexFields['target'];
      final indexExpr = indexFields['index'];
      if (targetExpr != null && indexExpr != null) {
        final container = await _evalExpression(targetExpr, scope);
        final idx = await _evalExpression(indexExpr, scope);
        final isInc = call.function.contains('increment');
        final isPre = call.function.startsWith('pre');
        if (container is BallList && idx is int) {
          final current = _toNum(container.items[idx]);
          final updated = isInc ? current + 1 : current - 1;
          container.items[idx] = updated;
          return isPre ? updated : current;
        }
        if (container is List && idx is int) {
          final current = _toNum(container[idx]);
          final updated = isInc ? current + 1 : current - 1;
          container[idx] = updated;
          return isPre ? updated : current;
        }
        if (container is BallMap && idx is String) {
          final current = _toNum(container.entries[idx]);
          final updated = isInc ? current + 1 : current - 1;
          container.entries[idx] = updated;
          return isPre ? updated : current;
        }
        if (container is Map) {
          final current = _toNum(container[idx]);
          final updated = isInc ? current + 1 : current - 1;
          container[idx] = updated;
          return isPre ? updated : current;
        }
      }
    }

    // Field access increment/decrement: value is obj.field
    if (valueExpr.whichExpr() == Expression_Expr.fieldAccess) {
      final obj = await _evalExpression(valueExpr.fieldAccess.object, scope);
      final fieldName = valueExpr.fieldAccess.field_2;
      final isInc = call.function.contains('increment');
      final isPre = call.function.startsWith('pre');
      final map = _cfAsMap(obj);
      if (map != null) {
        final current = _toNum(map[fieldName]);
        final updated = isInc ? current + 1 : current - 1;
        map[fieldName] = updated;
        return isPre ? updated : current;
      }
    }

    // Fallback: just compute
    final val = _toNum(await _evalExpression(valueExpr, scope));
    final isInc = call.function.contains('increment');
    return isInc ? val + 1 : val - 1;
  }

  Object? _applyCompoundOp(String op, Object? current, Object? val) {
    return switch (op) {
      '+=' => (current is String || val is String)
          ? '${current ?? ''}${val ?? ''}'
          : _numOp(current, val, (a, b) => a + b),
      '-=' => _numOp(current, val, (a, b) => a - b),
      '*=' => _numOp(current, val, (a, b) => a * b),
      '~/=' => _intOp(current, val, (a, b) => a ~/ b),
      '%=' => _intOp(current, val, (a, b) => a % b),
      '&=' => _intOp(current, val, (a, b) => a & b),
      '|=' => _intOp(current, val, (a, b) => a | b),
      '^=' => _intOp(current, val, (a, b) => a ^ b),
      '<<=' => _intOp(current, val, (a, b) => a << b),
      '>>=' => _intOp(current, val, (a, b) => a >> b),
      '>>>=' => _intOp(current, val, (a, b) => a >>> b),
      '??=' => current ?? val,
      _ => val,
    };
  }

  num _numOp(Object? a, Object? b, num Function(num, num) op) =>
      op(_toNum(a), _toNum(b));

  int _intOp(Object? a, Object? b, int Function(int, int) op) =>
      op(_toInt(a), _toInt(b));

  Future<Object?> _evalLabeled(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    final body = fields['body'];
    if (body == null) return null;

    // If the body contains a loop (for/while/for_in/do_while), pass the label
    // to the loop so it can handle labeled break/continue directly (running
    // the update step on continue, breaking on break).
    if (label != null && label.isNotEmpty) {
      final loopCall = _extractLoopFromBody(body);
      if (loopCall != null) {
        final result = await _evalLabeledLoop(loopCall, label, scope);
        if (result is _FlowSignal &&
            (result.kind == 'break' || result.kind == 'continue') &&
            result.label == label) {
          return null;
        }
        return result;
      }
    }

    final result = await _evalExpression(body, scope);
    if (result is _FlowSignal &&
        (result.kind == 'break' || result.kind == 'continue') &&
        result.label == label) {
      return null; // consumed
    }
    return result;
  }

  /// Extract the loop call from a labeled body expression.
  /// The body might be a block containing a single for/while/for_in call.
  FunctionCall? _extractLoopFromBody(Expression expr) {
    // Direct call to a loop
    if (expr.whichExpr() == Expression_Expr.call) {
      final fn = expr.call.function;
      if (fn == 'for' || fn == 'while' || fn == 'for_in' || fn == 'do_while') {
        return expr.call;
      }
    }
    // Block containing a single statement that is a loop call
    if (expr.whichExpr() == Expression_Expr.block &&
        expr.block.statements.length == 1) {
      final stmt = expr.block.statements[0];
      if (stmt.whichStmt() == Statement_Stmt.expression &&
          stmt.expression.whichExpr() == Expression_Expr.call) {
        final fn = stmt.expression.call.function;
        if (fn == 'for' || fn == 'while' || fn == 'for_in' || fn == 'do_while') {
          return stmt.expression.call;
        }
      }
    }
    return null;
  }

  /// Evaluate a for/while loop with a label, handling labeled break/continue.
  Future<Object?> _evalLabeledLoop(FunctionCall loopCall, String label, _Scope scope) async {
    return switch (loopCall.function) {
      'for' => _evalLabeledFor(loopCall, label, scope),
      'for_in' => _evalLabeledForIn(loopCall, label, scope),
      'while' => _evalLabeledWhile(loopCall, label, scope),
      'do_while' => _evalLabeledDoWhile(loopCall, label, scope),
      _ => _evalExpression(Expression()..call = loopCall, scope),
    };
  }

  Future<Object?> _evalLabeledFor(FunctionCall call, String label, _Scope scope) async {
    final fields = _lazyFields(call);
    final initExpr = fields['init'];
    final condition = fields['condition'];
    final update = fields['update'];
    final body = fields['body'];

    final forScope = scope.child();

    if (initExpr != null) {
      if (initExpr.whichExpr() == Expression_Expr.block) {
        for (final stmt in initExpr.block.statements) {
          await _evalStatement(stmt, forScope);
        }
      } else if (initExpr.whichExpr() == Expression_Expr.literal &&
          initExpr.literal.hasStringValue()) {
        final s = initExpr.literal.stringValue;
        final match = RegExp(
          r'(?:var|final|int|double|String)\s+(\w+)\s*=\s*(.+)',
        ).firstMatch(s);
        if (match != null) {
          final varName = match.group(1)!;
          final rawVal = match.group(2)!.trim();
          final parsed =
              int.tryParse(rawVal) ??
              double.tryParse(rawVal) ??
              (rawVal == 'true'
                  ? true
                  : rawVal == 'false'
                  ? false
                  : rawVal);
          forScope.bind(varName, parsed);
        }
      } else {
        await _evalExpression(initExpr, forScope);
      }
    }

    while (true) {
      if (condition != null) {
        final condVal = await _evalExpression(condition, forScope);
        if (!_toBool(condVal)) break;
      }
      if (body != null) {
        final result = await _evalExpression(body, forScope);
        if (result is _FlowSignal) {
          if (result.kind == 'return') return result;
          // Check labeled signals against our label
          if (result.label == label) {
            if (result.kind == 'break') break;
            if (result.kind == 'continue') {
              if (update != null) await _evalExpression(update, forScope);
              continue;
            }
          }
          // Other labeled signals: propagate
          if (result.label != null && result.label!.isNotEmpty) return result;
          if (result.kind == 'break') break;
          // unlabeled continue: fall through to update
        }
      }
      if (update != null) await _evalExpression(update, forScope);
    }
    return null;
  }

  Future<Object?> _evalLabeledForIn(FunctionCall call, String label, _Scope scope) async {
    final fields = _lazyFields(call);
    final variable = _stringFieldVal(fields, 'variable') ?? 'item';
    final iterable = fields['iterable'];
    final body = fields['body'];
    if (iterable == null || body == null) return null;

    final iterVal = await _evalExpression(iterable, scope);
    final items = _toIterable(iterVal);
    for (final item in items) {
      final loopScope = scope.child();
      loopScope.bind(variable, item);
      final result = await _evalExpression(body, loopScope);
      if (result is _FlowSignal) {
        if (result.kind == 'return') return result;
        if (result.label == label) {
          if (result.kind == 'break') break;
          if (result.kind == 'continue') continue;
        }
        if (result.label != null && result.label!.isNotEmpty) return result;
        if (result.kind == 'break') break;
      }
    }
    return null;
  }

  Future<Object?> _evalLabeledWhile(FunctionCall call, String label, _Scope scope) async {
    final fields = _lazyFields(call);
    final condition = fields['condition'];
    final body = fields['body'];
    while (true) {
      if (condition != null) {
        final condVal = await _evalExpression(condition, scope);
        if (!_toBool(condVal)) break;
      }
      if (body != null) {
        final result = await _evalExpression(body, scope);
        if (result is _FlowSignal) {
          if (result.kind == 'return') return result;
          if (result.label == label) {
            if (result.kind == 'break') break;
            if (result.kind == 'continue') continue;
          }
          if (result.label != null && result.label!.isNotEmpty) return result;
          if (result.kind == 'break') break;
        }
      }
    }
    return null;
  }

  Future<Object?> _evalLabeledDoWhile(FunctionCall call, String label, _Scope scope) async {
    final fields = _lazyFields(call);
    final body = fields['body'];
    final condition = fields['condition'];
    do {
      if (body != null) {
        final result = await _evalExpression(body, scope);
        if (result is _FlowSignal) {
          if (result.kind == 'return') return result;
          if (result.label == label) {
            if (result.kind == 'break') break;
            if (result.kind == 'continue') {
              // do-while: check condition after continue
              if (condition != null) {
                final condVal = await _evalExpression(condition, scope);
                if (!_toBool(condVal)) break;
              }
              continue;
            }
          }
          if (result.label != null && result.label!.isNotEmpty) return result;
          if (result.kind == 'break') break;
        }
      }
      if (condition != null) {
        final condVal = await _evalExpression(condition, scope);
        if (!_toBool(condVal)) break;
      } else {
        break;
      }
    } while (true);
    return null;
  }

  Future<Object?> _evalGoto(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    throw _FlowSignal('goto', label: label);
  }

  Future<Object?> _evalLabel(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'name');
    final body = fields['body'];
    if (body == null) return null;
    // Execute the body; if a goto signal targeting THIS label arrives,
    // re-execute the body (backward goto). For forward gotos, the signal
    // propagates up until the matching label handler catches it.
    Object? result;
    do {
      result = await _evalExpression(body, scope);
      if (result is _FlowSignal &&
          result.kind == 'goto' &&
          result.label == label) {
        continue; // re-execute body (backward goto)
      }
      break;
    } while (true);
    return result;
  }

  /// `dart_await_for` — in a single-threaded engine this is just `for_in`
  /// over a list (streams aren't real).
  /// Lazy cascade evaluation: evaluate `target`, bind it as `__cascade_self__`
  /// in scope, then evaluate `sections` (list of calls on the target), and
  /// return the target. For `null_aware_cascade`, return null if target is null.
  Future<Object?> _evalLazyCascade(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final targetExpr = fields['target'];
    if (targetExpr == null) return null;

    final target = await _evalExpression(targetExpr, scope);

    // null_aware_cascade: if target is null, skip sections and return null.
    if (call.function == 'null_aware_cascade' && target == null) return null;

    // Bind the target as __cascade_self__ so section expressions can reference it.
    final cascadeScope = scope.child();
    cascadeScope.bind('__cascade_self__', target);

    final sectionsExpr = fields['sections'];
    if (sectionsExpr != null) {
      // Sections is typically a list literal of call expressions.
      if (sectionsExpr.whichExpr() == Expression_Expr.literal &&
          sectionsExpr.literal.whichValue() == Literal_Value.listValue) {
        for (final section in sectionsExpr.literal.listValue.elements) {
          await _evalExpression(section, cascadeScope);
        }
      } else {
        await _evalExpression(sectionsExpr, cascadeScope);
      }
    }

    return target;
  }

  Future<Object?> _evalAwaitFor(FunctionCall call, _Scope scope) {
    // Reuse for_in logic.
    return _evalLazyForIn(call, scope);
  }

  /// Dispatch a method call on a built-in instance type (List, String, num).
  /// Returns [_sentinel] if the method is not recognized.
  Future<Object?> _dispatchBuiltinInstanceMethod(
    Object? self, String method, Object? input,
  ) async {
    final inputMap = _cfAsMap(input);
    final args = inputMap ?? <String, Object?>{};
    final arg0 = args['arg0'] ?? args['value'];

    // Track whether self was originally a BallList so we can wrap list
    // results back into BallList when appropriate.
    final wasBallList = self is BallList;

    // Unwrap BallValue wrappers to native types for dispatch.
    final Object? unwrappedSelf;
    if (self is BallList) {
      unwrappedSelf = self.items;
    } else if (self is BallString) {
      unwrappedSelf = self.value;
    } else if (self is BallMap) {
      unwrappedSelf = self.entries;
    } else {
      unwrappedSelf = self;
    }

    // ── List / Set methods ──
    if (unwrappedSelf is List) {
      final self = unwrappedSelf;
      // Helper to optionally wrap a list result back into BallList.
      Object? _wrapList(List<Object?> result) =>
          wasBallList ? BallList(result) : result;
      switch (method) {
        case 'add': self.add(arg0); return null;
        case 'removeLast': return self.removeLast();
        case 'removeAt': return self.removeAt(_toInt(arg0));
        case 'insert': self.insert(_toInt(arg0), args['arg1']); return null;
        case 'clear': self.clear(); return null;
        case 'contains': return self.contains(arg0);
        case 'indexOf': return self.indexOf(arg0);
        case 'join': return self.map((e) => _ballToString(e)).join(arg0 != null ? arg0.toString() : ', ');
        case 'sublist':
          final end = args['arg1'];
          return _wrapList(self.sublist(_toInt(arg0), end != null ? _toInt(end) : null));
        case 'reversed': return _wrapList(self.reversed.toList());
        case 'sort':
          if (arg0 is Function) {
            // Use insertion sort to support async comparators.
            final sorted = self.toList();
            for (var j = 1; j < sorted.length; j++) {
              final key = sorted[j];
              var k = j - 1;
              while (k >= 0) {
                var r = arg0(<String, Object?>{'arg0': sorted[k], 'arg1': key, 'a': sorted[k], 'b': key, 'left': sorted[k], 'right': key});
                if (r is Future) r = await r;
                if (r is num && r > 0) {
                  sorted[k + 1] = sorted[k];
                  k--;
                } else {
                  break;
                }
              }
              sorted[k + 1] = key;
            }
            self.setAll(0, sorted);
            return null;
          }
          final defaultSorted = List<Object?>.of(self);
          defaultSorted.sort((a, b) => (a as Comparable).compareTo(b));
          self.setAll(0, defaultSorted);
          return null;
        case 'map':
          if (arg0 is Function) {
            final result = <Object?>[];
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) r = await r;
              result.add(r);
            }
            return _wrapList(result);
          }
          return wasBallList ? BallList(self) : self;
        case 'where':
        case 'filter':
          if (arg0 is Function) {
            final result = <Object?>[];
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) r = await r;
              if (r == true) result.add(item);
            }
            return _wrapList(result);
          }
          return wasBallList ? BallList(self) : self;
        case 'forEach':
          if (arg0 is Function) {
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) await r;
            }
          }
          return null;
        case 'any':
          if (arg0 is Function) {
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) r = await r;
              if (r == true) return true;
            }
            return false;
          }
          return false;
        case 'every':
          if (arg0 is Function) {
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) r = await r;
              if (r != true) return false;
            }
            return true;
          }
          return true;
        case 'reduce':
          if (arg0 is Function) {
            final init = args['arg1'];
            var acc = init;
            for (final item in self) {
              var r = arg0(<String, Object?>{'arg0': acc, 'arg1': item});
              if (r is Future) r = await r;
              acc = r;
            }
            return acc;
          }
          return null;
        case 'fold':
          if (args['arg1'] is Function) {
            final fn = args['arg1'] as Function;
            var acc = arg0;
            for (final item in self) {
              var r = fn(<String, Object?>{'arg0': acc, 'arg1': item});
              if (r is Future) r = await r;
              acc = r;
            }
            return acc;
          }
          return arg0;
        case 'toList': return _wrapList(self.toList());
        case 'toSet': return _wrapList(self.toSet().toList());
        case 'toString': return '[${self.map(_ballToString).join(', ')}]';
        case 'filled':
          // List.filled(n, value) encoded as self=[], arg0=n, arg1=value
          return _wrapList(List.filled(_toInt(arg0), args['arg1']));
        // Set operations (sets are encoded as arrays).
        case 'union':
          final other = arg0 is BallList ? arg0.items : (arg0 is List ? arg0 : <Object?>[]);
          return _wrapList({...self, ...other}.toList());
        case 'intersection':
          final otherSet = (arg0 is BallList ? arg0.items : (arg0 is List ? arg0 : <Object?>[])).toSet();
          return _wrapList(self.where((x) => otherSet.contains(x)).toList());
        case 'difference':
          final otherSet2 = (arg0 is BallList ? arg0.items : (arg0 is List ? arg0 : <Object?>[])).toSet();
          return _wrapList(self.where((x) => !otherSet2.contains(x)).toList());
        case 'addAll':
          final other2 = arg0 is BallList ? arg0.items : (arg0 is List ? arg0 : <Object?>[]);
          for (final item in other2) {
            if (!self.contains(item)) self.add(item);
          }
          return null;
        case 'expand':
          if (arg0 is Function) {
            final result = <Object?>[];
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) r = await r;
              if (r is BallList) {
                result.addAll(r.items);
              } else if (r is List) {
                result.addAll(r);
              } else {
                result.add(r);
              }
            }
            return _wrapList(result);
          }
          return wasBallList ? BallList(self) : self;
        case 'take': return _wrapList(self.take(_toInt(arg0)).toList());
        case 'skip': return _wrapList(self.skip(_toInt(arg0)).toList());
        case 'followedBy':
          final other3 = arg0 is BallList ? arg0.items : (arg0 is List ? arg0 : <Object?>[]);
          return _wrapList([...self, ...other3]);
      }
    }

    // ── Set methods ──
    if (unwrappedSelf is Set) {
      final self = unwrappedSelf;
      final selfList = self.toList();
      switch (method) {
        case 'union':
          final otherU = arg0 is Set ? arg0 : (arg0 is List ? arg0.toSet() : <Object?>{});
          return self.union(otherU);
        case 'intersection':
          final otherI = arg0 is Set ? arg0 : (arg0 is List ? arg0.toSet() : <Object?>{});
          return self.intersection(otherI);
        case 'difference':
          final otherD = arg0 is Set ? arg0 : (arg0 is List ? arg0.toSet() : <Object?>{});
          return self.difference(otherD);
        case 'add': self.add(arg0); return null;
        case 'addAll':
          if (arg0 is Iterable) self.addAll(arg0);
          return null;
        case 'remove': self.remove(arg0); return null;
        case 'contains': return self.contains(arg0);
        case 'toList': return selfList;
        case 'toSet': return self;
        case 'length': return self.length;
        case 'isEmpty': return self.isEmpty;
        case 'isNotEmpty': return self.isNotEmpty;
        case 'forEach':
          if (arg0 is Function) {
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) await r;
            }
          }
          return null;
        case 'map':
          if (arg0 is Function) {
            final result = <Object?>[];
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) r = await r;
              result.add(r);
            }
            return result;
          }
          return selfList;
        case 'where':
        case 'filter':
          if (arg0 is Function) {
            final result = <Object?>{};
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) r = await r;
              if (r == true) result.add(item);
            }
            return result;
          }
          return self;
      }
    }

    // ── String methods ──
    if (unwrappedSelf is String) {
      final self = unwrappedSelf;
      switch (method) {
        case 'contains': return self.contains(arg0.toString());
        case 'substring':
          final end = args['arg1'];
          return self.substring(_toInt(arg0), end != null ? _toInt(end) : null);
        case 'indexOf': return self.indexOf(arg0.toString());
        case 'split': return self.split(arg0.toString());
        case 'trim': return self.trim();
        case 'toUpperCase': return self.toUpperCase();
        case 'toLowerCase': return self.toLowerCase();
        case 'replaceAll': return self.replaceAll(arg0.toString(), (args['arg1'] ?? '').toString());
        case 'startsWith': return self.startsWith(arg0.toString());
        case 'endsWith': return self.endsWith(arg0.toString());
        case 'padLeft': return self.padLeft(_toInt(arg0), args['arg1']?.toString() ?? ' ');
        case 'padRight': return self.padRight(_toInt(arg0), args['arg1']?.toString() ?? ' ');
        case 'toString': return self;
        case 'codeUnitAt': return self.codeUnitAt(_toInt(arg0));
        case 'compareTo': return self.compareTo(arg0.toString());
      }
    }

    // ── Number methods ──
    if (unwrappedSelf is num) {
      final self = unwrappedSelf;
      switch (method) {
        case 'toDouble': return self.toDouble();
        case 'toInt': return self.toInt();
        case 'toString': return _ballToString(self);
        case 'toStringAsFixed': return self.toStringAsFixed(_toInt(arg0));
        case 'abs': return self.abs();
        case 'round': return self.round();
        case 'floor': return self.floor();
        case 'ceil': return self.ceil();
        case 'compareTo': return self.compareTo(_toNum(arg0));
        case 'clamp': return self.clamp(_toNum(arg0), _toNum(args['arg1'] ?? self));
        case 'truncate': return self.truncate();
        case 'remainder': return self.remainder(_toNum(arg0));
      }
    }

    // ── Map methods on typed objects ──
    final selfMap = _cfAsMap(self);
    if (selfMap != null && selfMap.containsKey('__type__')) {
      // StringBuffer methods.
      final typeName = selfMap['__type__'] as String?;
      if (typeName != null && (typeName.endsWith(':StringBuffer') || typeName == 'StringBuffer')) {
        switch (method) {
          case 'write':
            selfMap['__buffer__'] = (selfMap['__buffer__'] as String? ?? '') + _ballToString(arg0);
            return null;
          case 'writeln':
            selfMap['__buffer__'] = (selfMap['__buffer__'] as String? ?? '') + _ballToString(arg0) + '\n';
            return null;
          case 'writeCharCode':
            selfMap['__buffer__'] = (selfMap['__buffer__'] as String? ?? '') + String.fromCharCode(_toInt(arg0));
            return null;
          case 'toString': return selfMap['__buffer__'] ?? '';
          case 'clear': selfMap['__buffer__'] = ''; return null;
          case 'length': return (selfMap['__buffer__'] as String? ?? '').length;
        }
      }

      // Generic toString on typed objects.
      if (method == 'toString') {
        return _ballToString(self);
      }
    }

    return _sentinel;
  }

  /// `cpp_std.cpp_scope_exit` — register a cleanup expression to run when
  /// the nearest enclosing block scope exits (LIFO / RAII semantics).
  ///
  /// The cleanup expression is stored *unevaluated* alongside the current
  /// scope so that it can close over variables in its lexical context, even
  /// if those variables change before the scope exits.
  Object? _evalCppScopeExit(FunctionCall call, _Scope scope) {
    if (!call.hasInput()) return null;
    final input = call.input;
    if (input.whichExpr() != Expression_Expr.messageCreation) return null;

    // Find the `cleanup` field expression without evaluating it.
    final cleanupEntry = input.messageCreation.fields
        .where((f) => f.name == 'cleanup')
        .firstOrNull;
    if (cleanupEntry == null) return null;

    // Walk up the scope chain to find the nearest block scope (the one
    // created by _evalBlock for the enclosing block).  We register on the
    // *caller* scope, which is the child scope created by the enclosing block.
    scope.registerScopeExit(cleanupEntry.value, scope);
    return null;
  }

}
