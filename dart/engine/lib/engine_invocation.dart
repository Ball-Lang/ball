part of 'engine.dart';

extension BallEngineInvocation on BallEngine {
  Map<String, Object?>? _asMap(Object? v) {
    if (v is BallMap) return v.entries;
    if (v is Map<String, Object?>) return v;
    return null;
  }

  Future<Object?> _callFunction(
    String moduleName,
    FunctionDefinition func,
    Object? input,
  ) async {
    if (func.isBase) {
      return _callBaseFunction(moduleName, func.name, input);
    }

    // Constructor without body: build an instance from `is_this` params.
    if (!func.hasBody()) {
      if (func.hasMetadata()) {
        final kindField = func.metadata.fields['kind'];
        if (kindField?.stringValue == 'constructor') {
          return _buildConstructorInstance(moduleName, func, input);
        }
      }
      return null;
    }

    final prevModule = _currentModule;
    _currentModule = moduleName;
    final scope = _Scope(_globalScope);

    // Bind 'input' to the raw input first (as a fallback reference).
    // Parameter extraction below may override this with the extracted value
    // when the parameter name is 'input' or matches a named field.
    if (func.inputType.isNotEmpty && input != null) {
      scope.bind('input', input);
    }

// Bind parameters: use pre-built param cache for O(1) lookup.
    // This overrides the raw 'input' binding when the param name is 'input'.
    final params =
        _paramCache['$moduleName.${func.name}'] ??
        (func.hasMetadata() ? _extractParams(func.metadata) : const []);
    final inputMap = _asMap(input);
    if (params.isNotEmpty) {
      if (params.length == 1 &&
          !(inputMap != null && inputMap.containsKey('self'))) {
        // Single parameter — bind the input directly (but not for instance
        // methods where `self` is mixed in; those use the map extraction path).
        // If input is a map with positional args (arg0), extract the value.
        if (inputMap != null &&
            inputMap.containsKey('arg0') &&
            !inputMap.containsKey(params[0])) {
          scope.bind(params[0], inputMap['arg0']);
        } else {
          scope.bind(params[0], input);
        }
      } else if (inputMap != null) {
        // Multiple parameters — named args or positional arg0/arg1.
        for (var i = 0; i < params.length; i++) {
          final p = params[i];
          if (inputMap.containsKey(p)) {
            scope.bind(p, inputMap[p]);
          } else if (inputMap.containsKey('arg$i')) {
            scope.bind(p, inputMap['arg$i']);
          }
        }
      } else if (input is List) {
        // Positional args as list.
        for (var i = 0; i < params.length && i < input.length; i++) {
          scope.bind(params[i], input[i]);
        }
      }
    }

    // Bind 'self' for instance method calls so `this` references resolve.
    // Also bind all fields from self into scope so methods can reference
    // `x` instead of `self.x`.
    if (inputMap != null && inputMap.containsKey('self')) {
      final self = inputMap['self'];
      scope.bind('self', self);
      final selfMap = _asMap(self);
      if (selfMap != null) {
        // Bind direct fields. Use temporary debug to trace.
        for (final entry in selfMap.entries) {
          if (!entry.key.startsWith('__')) {
            scope.bind(entry.key, entry.value);
          }
        }
        // Also bind inherited fields from __super__ chain.
        var superObj = _asMap(selfMap['__super__']);
        while (superObj != null) {
          for (final entry in superObj.entries) {
            if (!entry.key.startsWith('__') && !scope.has(entry.key)) {
              scope.bind(entry.key, entry.value);
            }
          }
          superObj = _asMap(superObj['__super__']);
        }
      }
    }

    // Generator support: sync* and async* functions collect yielded values
    // into a BallGenerator. Create one and bind it in scope so std.yield
    // and dart_std.yield_each can add values to it.
    final isSyncStar = func.hasMetadata() &&
        (func.metadata.fields['is_sync_star']?.boolValue ?? false);
    final isAsyncStar = func.hasMetadata() &&
        (func.metadata.fields['is_async_star']?.boolValue ?? false);
    final isGenerator = func.hasMetadata() &&
        (func.metadata.fields['is_generator']?.boolValue ?? false);
    final isGenFunc = isSyncStar || isAsyncStar || isGenerator;

    BallGenerator? generator;
    if (isGenFunc) {
      generator = BallGenerator();
      scope.bind('__generator__', generator);
    }

    final result = await _evalExpression(func.body, scope);
    _currentModule = prevModule;

    Object? finalResult;
    if (result is _FlowSignal && result.kind == 'return') {
      finalResult = result.value;
    } else {
      finalResult = result;
    }

    // Generator: return collected values as a list.
    if (isGenFunc && generator != null) {
      generator.completed = true;
      final values = generator.values;
      if (isAsyncStar) {
        // async* → BallFuture of list
        return _ballFuture(values);
      }
      // sync* → plain list
      return values;
    }

    // Wrap async function results in BallFuture for synchronous simulation.
    if (func.hasMetadata()) {
      final asyncField = func.metadata.fields['is_async'];
      if (asyncField != null && asyncField.boolValue) {
        // async function → wrap return value in BallFuture
        if (!_isBallFuture(finalResult)) {
          return _ballFuture(finalResult);
        }
      }
    }

    return finalResult;
  }

  /// Build a class instance from a constructor with no body.
  /// Maps positional args (arg0, arg1, ...) to `is_this` parameter names,
  /// and populates __type__, __super__, and __methods__.
  Future<Object?> _buildConstructorInstance(
    String moduleName,
    FunctionDefinition func,
    Object? input,
  ) async {
    final params = func.hasMetadata() ? _extractParams(func.metadata) : const <String>[];
    final paramsMeta = _extractParamsMeta(func.metadata);

    final instance = <String, Object?>{};

    // Determine the type name from the function name (e.g., "main:Point.new" -> "main:Point").
    final dotIdx = func.name.indexOf('.');
    final typeName = dotIdx >= 0 ? func.name.substring(0, dotIdx) : func.name;
    instance['__type__'] = typeName;

    // Build a map of resolved param values for use in super() calls, etc.
    final resolvedParams = <String, Object?>{};

    // Map input arguments to field names.
    final inputMap = _asMap(input);
    if (inputMap != null) {
      for (var i = 0; i < params.length; i++) {
        final p = params[i];
        final isThis = i < paramsMeta.length && paramsMeta[i]['is_this'] == true;
        Object? val;
        if (inputMap.containsKey(p)) {
          val = inputMap[p];
        } else if (inputMap.containsKey('arg$i')) {
          val = inputMap['arg$i'];
        } else {
          val = i < paramsMeta.length ? paramsMeta[i]['default'] : null;
        }
        resolvedParams[p] = val;
        if (isThis) {
          instance[p] = val;
        }
      }
    } else if (params.length == 1) {
      resolvedParams[params[0]] = input;
      final isThis = paramsMeta.isNotEmpty && paramsMeta[0]['is_this'] == true;
      if (isThis) {
        instance[params[0]] = input;
      }
    }

    // Process field initializers from constructor metadata.
    if (func.hasMetadata()) {
      final initsField = func.metadata.fields['initializers'];
      if (initsField != null &&
          initsField.whichKind() == structpb.Value_Kind.listValue) {
        for (final init in initsField.listValue.values) {
          if (init.whichKind() != structpb.Value_Kind.structValue) continue;
          final kind = init.structValue.fields['kind']?.stringValue;
          final name = init.structValue.fields['name']?.stringValue;
          if (kind == 'field' && name != null) {
            final valField = init.structValue.fields['value'];
            if (valField != null && valField.hasStringValue()) {
              final valStr = valField.stringValue;
              // Try to evaluate as param reference with index (e.g. "coords[0]").
              final indexMatch = RegExp(r'^(\w+)\[(\d+)\]$').firstMatch(valStr);
              if (indexMatch != null) {
                final arrName = indexMatch.group(1)!;
                final idx = int.parse(indexMatch.group(2)!);
                final rawArr = resolvedParams[arrName];
                final arr = rawArr is BallList ? rawArr.items : rawArr;
                if (arr is List && idx < arr.length) {
                  instance[name] = arr[idx];
                } else {
                  instance[name] = null;
                }
              } else if (valStr == 'true') {
                instance[name] = true;
              } else if (valStr == 'false') {
                instance[name] = false;
              } else if (num.tryParse(valStr) != null) {
                final numVal = num.parse(valStr);
                instance[name] = valStr.contains('.') ? BallDouble(numVal.toDouble()) : numVal.toInt();
              } else {
                // Try as a param/variable reference.
                instance[name] = resolvedParams[valStr] ?? valStr;
              }
            } else if (valField != null && valField.hasNumberValue()) {
              final n = valField.numberValue;
              instance[name] = n == n.toInt() ? n.toInt() : n;
            } else if (valField != null && valField.hasBoolValue()) {
              instance[name] = valField.boolValue;
            } else {
              instance[name] = null;
            }
          }
        }
      }
    }

    // Process super constructor initializers.
    final typeDef = _findTypeDef(typeName);
    if (typeDef != null) {
      final superclass = _getMetaString(typeDef, 'superclass');
      if (superclass != null && superclass.isNotEmpty) {
        // Check for super() initializer in constructor metadata.
        final superInstance = await _invokeSuperConstructor(
          func, superclass, resolvedParams,
        );
        final superMap = _asMap(superInstance);
        if (superMap != null) {
          // Merge super fields into the instance and set __super__.
          instance['__super__'] = superInstance;
          // Copy inherited fields to instance level for easy access.
          for (final e in superMap.entries) {
            if (!e.key.startsWith('__') && !instance.containsKey(e.key)) {
              instance[e.key] = e.value;
            }
          }
        } else {
          // Fallback: build a static super object.
          instance['__super__'] = _buildSuperObject(superclass, instance);
        }
      }

      final methods = _resolveTypeMethodsWithInheritance(typeName);
      if (methods.isNotEmpty) {
        instance['__methods__'] = methods;
      }
    }

    return BallMap(instance);
  }

  /// Invoke the super constructor for a child class.
  Future<Object?> _invokeSuperConstructor(
    FunctionDefinition childCtor,
    String superclass,
    Map<String, Object?> resolvedParams,
  ) async {
    // Look for super() initializer in constructor metadata.
    if (childCtor.hasMetadata()) {
      final initsField = childCtor.metadata.fields['initializers'];
      if (initsField != null &&
          initsField.whichKind() == structpb.Value_Kind.listValue) {
        for (final init in initsField.listValue.values) {
          if (init.whichKind() != structpb.Value_Kind.structValue) continue;
          final kind = init.structValue.fields['kind']?.stringValue;
          if (kind == 'super') {
            final argsStr = init.structValue.fields['args']?.stringValue ?? '';
            // Parse "(name)" or "(name, age)" to get param names to forward.
            final argNames = _parseSuperArgs(argsStr);
            // Build input for the super constructor.
            final superInput = <String, Object?>{};
            for (var i = 0; i < argNames.length; i++) {
              final token = argNames[i];
              if (resolvedParams.containsKey(token)) {
                superInput['arg$i'] = resolvedParams[token];
              } else if ((token.startsWith("'") && token.endsWith("'")) ||
                         (token.startsWith('"') && token.endsWith('"'))) {
                // String literal: strip quotes.
                superInput['arg$i'] = token.substring(1, token.length - 1);
              } else if (num.tryParse(token) != null) {
                final n = num.parse(token);
                superInput['arg$i'] = token.contains('.') ? n.toDouble() : n.toInt();
              } else if (token == 'true') {
                superInput['arg$i'] = true;
              } else if (token == 'false') {
                superInput['arg$i'] = false;
              }
            }
            // Find and invoke the super constructor.
            final superCtorEntry = _lookupConstructor(superclass);
            if (superCtorEntry != null) {
              return _callFunction(superCtorEntry.module, superCtorEntry.func, superInput);
            }
          }
        }
      }
    }

    // No explicit super() call — try invoking default super constructor.
    final superCtorEntry = _lookupConstructor(superclass);
    if (superCtorEntry != null) {
      // Pass all resolved params as potential args.
      final superInput = <String, Object?>{};
      for (var i = 0; i < resolvedParams.length; i++) {
        superInput['arg$i'] = resolvedParams.values.elementAt(i);
      }
      return _callFunction(superCtorEntry.module, superCtorEntry.func, superInput);
    }

    return null;
  }

  /// Parse super constructor args like "(name)" or "(name, age)".
  /// Look up a constructor by name, trying bare name, module-qualified, etc.
  ({String module, FunctionDefinition func})? _lookupConstructor(String name) {
    // Direct lookup.
    final direct = _constructors[name];
    if (direct != null) return direct;
    // Try with current module prefix: "main:ClassName".
    final qualified = '$_currentModule:$name';
    final qual = _constructors[qualified];
    if (qual != null) return qual;
    // Search all constructors for a bare-name match.
    for (final entry in _constructors.entries) {
      final key = entry.key;
      // key might be "main:Animal" or "Animal" — strip module prefix and compare.
      final colonIdx = key.indexOf(':');
      final bare = colonIdx >= 0 ? key.substring(colonIdx + 1) : key;
      if (bare == name) return entry.value;
    }
    return null;
  }

  List<String> _parseSuperArgs(String argsStr) {
    final trimmed = argsStr.trim();
    if (trimmed.isEmpty) return [];
    // Strip outer parens.
    final inner = trimmed.startsWith('(') && trimmed.endsWith(')')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
    if (inner.isEmpty) return [];
    return inner.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  /// Extract full parameter metadata (not just names) from function metadata.
  List<Map<String, Object?>> _extractParamsMeta(structpb.Struct metadata) {
    final paramsValue = metadata.fields['params'];
    if (paramsValue == null ||
        paramsValue.whichKind() != structpb.Value_Kind.listValue) {
      return const [];
    }
    return paramsValue.listValue.values
        .where((v) => v.whichKind() == structpb.Value_Kind.structValue)
        .map((v) {
          final fields = v.structValue.fields;
          final result = <String, Object?>{};
          final nameField = fields['name'];
          if (nameField != null) result['name'] = nameField.stringValue;
          final isThisField = fields['is_this'];
          if (isThisField != null) result['is_this'] = isThisField.boolValue;
          final defaultField = fields['default_value'];
          if (defaultField != null) {
            if (defaultField.hasStringValue()) {
              result['default'] = defaultField.stringValue;
            } else if (defaultField.hasNumberValue()) {
              final n = defaultField.numberValue;
              result['default'] = n == n.toInt() ? n.toInt() : n;
            } else if (defaultField.hasBoolValue()) {
              result['default'] = defaultField.boolValue;
            }
          }
          return result;
        })
        .toList();
  }

  /// Extract parameter names from function metadata Struct.
  List<String> _extractParams(structpb.Struct metadata) {
    final paramsValue = metadata.fields['params'];
    if (paramsValue == null ||
        paramsValue.whichKind() != structpb.Value_Kind.listValue) {
      return const [];
    }
    return paramsValue.listValue.values
        .where((v) => v.whichKind() == structpb.Value_Kind.structValue)
        .map((v) {
          final nameField = v.structValue.fields['name'];
          return nameField?.stringValue ?? '';
        })
        .where((n) => n.isNotEmpty)
        .toList();
  }

  Future<Object?> _resolveAndCallFunction(
    String module,
    String function,
    Object? input,
  ) async {
    final moduleName = module.isEmpty ? _currentModule : module;
    final key = '$moduleName.$function';
    final func = _functions[key];
    if (func != null) return _callFunction(moduleName, func, input);

    // Module-unqualified fallback: check inline cache first so repeated calls
    // to the same function skip the O(n) linear scan (mirrors V8 inline caches).
    final cached = _callCache[function];
    if (cached != null) return _callFunction(cached.module, cached.func, input);

    for (final m in program.modules) {
      for (final f in m.functions) {
        if (f.name == function) {
          _callCache[function] = (module: m.name, func: f);
          return _callFunction(m.name, f, input);
        }
      }
    }

    // Constructor fallback: try "function.new" (default constructor name).
    final ctorKey = '$moduleName.$function.new';
    final ctorFunc = _functions[ctorKey];
    if (ctorFunc != null) return _callFunction(moduleName, ctorFunc, input);

    // Also check the constructor registry by bare name.
    final ctorEntry = _constructors[function];
    if (ctorEntry != null) {
      return _callFunction(ctorEntry.module, ctorEntry.func, input);
    }

    // Lazy module loading: if a resolver is available, check whether any
    // module declares an import for the missing module and resolve it.
    if (_resolver != null) {
      final resolved = await _tryLazyResolve(moduleName);
      if (resolved != null) {
        _indexModule(resolved);
        final resolvedFunc = _functions['$moduleName.$function'];
        if (resolvedFunc != null) {
          return _callFunction(moduleName, resolvedFunc, input);
        }
      }
    }

    throw BallRuntimeError('Function "$key" not found');
  }

  Future<Module?> _tryLazyResolve(String moduleName) async {
    for (final m in program.modules) {
      for (final import_ in m.moduleImports) {
        if (import_.name == moduleName && import_.whichSource() != ModuleImport_Source.notSet) {
          try {
            return await _resolver!.resolve(import_);
          } catch (_) {}
        }
      }
    }
    return null;
  }

  void _indexModule(Module module) {
    program.modules.add(module);
    for (final type in module.types) {
      _types[type.name] = type;
    }
    for (final td in module.typeDefs) {
      if (td.hasDescriptor()) _types[td.name] = td.descriptor;
    }
    for (final func in module.functions) {
      final key = '${module.name}.${func.name}';
      _functions[key] = func;
      if (func.hasMetadata()) {
        final params = _extractParams(func.metadata);
        if (params.isNotEmpty) _paramCache[key] = params;

        // Mirror constructor registration from _buildLookupTables.
        final kindField = func.metadata.fields['kind'];
        if (kindField?.stringValue == 'constructor') {
          final entry = (module: module.name, func: func);
          final dotIdx = func.name.indexOf('.');
          if (dotIdx >= 0) {
            final className = func.name.substring(0, dotIdx);
            final ctorSuffix = func.name.substring(dotIdx + 1);
            if (ctorSuffix == 'new') {
              _constructors[className] = entry;
              _constructors['${module.name}:$className'] = entry;
            }
            _constructors[func.name] = entry;
          }
        }
      }
    }
  }
}
