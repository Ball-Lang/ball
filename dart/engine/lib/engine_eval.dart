part of 'engine.dart';

extension BallEngineEval on BallEngine {
  /// Unwrap a value to its underlying [Map<String, Object?>] if it is a
  /// [BallMap] or already a raw map.  Returns `null` otherwise.
  Map<String, Object?>? _asMap(Object? v) {
    if (v is BallMap) return v.entries;
    if (v is Map<String, Object?>) return v;
    return null;
  }

  /// Unwrap a value to its underlying [List<Object?>] if it is a
  /// [BallList] or already a raw list.  Returns `null` otherwise.
  List<Object?>? _asList(Object? v) {
    if (v is BallList) return v.items;
    if (v is List<Object?>) return v;
    return null;
  }

  Future<Object?> _evalExpression(Expression expr, _Scope scope) async {
    return switch (expr.whichExpr()) {
      Expression_Expr.call => await _evalCall(expr.call, scope),
      Expression_Expr.literal => await _evalLiteral(expr.literal, scope),
      Expression_Expr.reference => await _evalReference(expr.reference, scope),
      Expression_Expr.fieldAccess => await _evalFieldAccess(expr.fieldAccess, scope),
      Expression_Expr.messageCreation => await _evalMessageCreation(
        expr.messageCreation,
        scope,
      ),
      Expression_Expr.block => await _evalBlock(expr.block, scope),
      Expression_Expr.lambda => _evalLambda(expr.lambda, scope),
      Expression_Expr.notSet => null,
    };
  }

  // ---- Function Calls ----

  Future<Object?> _evalCall(FunctionCall call, _Scope scope) async {
    final moduleName = call.module.isEmpty ? _currentModule : call.module;

    // Lazy-evaluated std/dart_std functions (control flow)
    if (moduleName == 'std' || moduleName == 'dart_std') {
      switch (call.function) {
        case 'if':
          return _evalLazyIf(call, scope);
        case 'for':
          return _evalLazyFor(call, scope);
        case 'for_in':
          return _evalLazyForIn(call, scope);
        case 'while':
          return _evalLazyWhile(call, scope);
        case 'do_while':
          return _evalLazyDoWhile(call, scope);
        case 'switch':
          return _evalLazySwitch(call, scope);
        case 'try':
          return _evalLazyTry(call, scope);
        case 'and':
          return _evalShortCircuitAnd(call, scope);
        case 'or':
          return _evalShortCircuitOr(call, scope);
        case 'return':
          return _evalReturn(call, scope);
        case 'break':
          return _evalBreak(call, scope);
        case 'continue':
          return _evalContinue(call, scope);
        case 'assign':
          return _evalAssign(call, scope);
        case 'labeled':
          return _evalLabeled(call, scope);
        case 'goto':
          return _evalGoto(call, scope);
        case 'label':
          return _evalLabel(call, scope);
        case 'post_increment':
        case 'pre_increment':
        case 'post_decrement':
        case 'pre_decrement':
          return _evalIncDec(call, scope);
        case 'dart_await_for':
          return _evalAwaitFor(call, scope);
        case 'cascade':
        case 'null_aware_cascade':
          return _evalLazyCascade(call, scope);
      }
    }

    // cpp_scope_exit must be lazy: register the cleanup expression without
    // evaluating it, then execute in LIFO order when the enclosing block exits.
    if (moduleName == 'cpp_std' && call.function == 'cpp_scope_exit') {
      return _evalCppScopeExit(call, scope);
    }

    // Eager evaluation for all other calls
    final input = call.hasInput() ? await _evalExpression(call.input, scope) : null;

    // Well-known global functions (not in any module).
    if (call.module.isEmpty) {
      switch (call.function) {
        case 'identical':
          final identicalMap = _asMap(input);
          if (identicalMap != null) {
            final a = identicalMap['arg0'] ?? identicalMap['left'];
            final b = identicalMap['arg1'] ?? identicalMap['right'];
            return identical(a, b);
          }
          return false;
      }
    }

    // Hot-path fast dispatch: explicitly-qualified std/dart_std calls are
    // always base functions. Skip the `$module.$function` string alloc
    // and the _functions map probe — go straight to the module handler.
    // Only fires when call.module is set explicitly (empty-module calls
    // still flow through the scope-closure check below).
    if (call.module == 'std' || call.module == 'dart_std') {
      return _callBaseFunction(call.module, call.function, input);
    }

    final key = '$moduleName.${call.function}';
    final func = _functions[key];
    if (func != null && func.isBase) {
      return _callBaseFunction(moduleName, call.function, input);
    }

    // Local closure call: when the function name resolves to a value
    // in the current scope (bound via `let f = (x) => ...`), invoke
    // that value directly. Otherwise fall through to module lookup.
    // Module-qualified calls skip the scope check — those always mean
    // "call function F in module M".
    if (call.module.isEmpty && scope.has(call.function)) {
      final bound = scope.lookup(call.function);
      if (bound is Function) {
        final result = bound(input);
        if (result is Future) return await result;
        return result;
      }
    }

    // Method call on object (has 'self' field) — instance method dispatch.
    final inputMap = _asMap(input);
    if (inputMap != null && inputMap.containsKey('self')) {
      final self = inputMap['self'];
      final selfMap = _asMap(self);
      if (selfMap != null) {
        // Built-in class static method dispatch (List.generate, etc.).
        if (selfMap['__type__'] == '__builtin_class__') {
          final className = selfMap['__class_ref__'] as String;
          final argInput = Map<String, Object?>.from(inputMap)..remove('self');
          final builtinResult = await _dispatchBuiltinClassMethod(
            className, call.function, argInput);
          if (builtinResult != _sentinel) return builtinResult;
        }

        // Static method dispatch on class reference.
        if (selfMap['__type__'] == '__class__') {
          final className = selfMap['__class_ref__'] as String;
          final qualifiedName = className.contains(':') ? className : '$_currentModule:$className';
          final colonIdx2 = qualifiedName.indexOf(':');
          final modPart2 = colonIdx2 >= 0 ? qualifiedName.substring(0, colonIdx2) : _currentModule;
          final staticKey = '$modPart2.$qualifiedName.${call.function}';
          final staticFunc = _functions[staticKey];
          if (staticFunc != null) {
            // Strip 'self' from input for static methods.
            final staticInput = Map<String, Object?>.from(inputMap)..remove('self');
            return _callFunction(modPart2, staticFunc, staticInput);
          }
        }

        final typeName = selfMap['__type__'] as String?;
        if (typeName != null &&
            typeName != '__builtin_class__' &&
            typeName != '__class__') {
          // Use _resolveMethod which walks superclass chain and mixins.
          final resolved = _resolveMethod(typeName, call.function);
          if (resolved != null) {
            return _callFunction(resolved.module, resolved.func, input);
          }
        }
      }

      // Built-in method dispatch for List, String, and other built-in types.
      final builtinResult = await _dispatchBuiltinInstanceMethod(
        self, call.function, input);
      if (builtinResult != _sentinel) return builtinResult;

      // Fall through to normal resolution if no method found on the type.
    }

    // Fallback method resolution: scan all module functions for a matching
    // "TypeName.methodName" pattern when self is a typed object.
    final fallbackMap = _asMap(input);
    if (fallbackMap != null && fallbackMap.containsKey('self')) {
      final selfFallback = fallbackMap['self'];
      final selfFallbackMap = _asMap(selfFallback);
      if (selfFallbackMap != null) {
        final typeName = selfFallbackMap['__type__'] as String?;
        if (typeName != null) {
          for (final m in program.modules) {
            for (final f in m.functions) {
              if (!f.isBase && f.hasBody()) {
                final dotIdx = f.name.lastIndexOf('.');
                if (dotIdx >= 0 && f.name.substring(dotIdx + 1) == call.function) {
                  final prefix = f.name.substring(0, dotIdx);
                  if (prefix == typeName) {
                    return _callFunction(m.name, f, input);
                  }
                }
              }
            }
          }
          // Walk the superclass chain for inherited methods too.
          var superType = _findTypeDef(typeName)?.superclass;
          while (superType != null && superType.isNotEmpty) {
            final colonIdx = typeName.indexOf(':');
            final modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : _currentModule;
            final qualSuper = superType.contains(':') ? superType : '$modPart:$superType';
            for (final m in program.modules) {
              for (final f in m.functions) {
                if (!f.isBase && f.hasBody()) {
                  final dotIdx = f.name.lastIndexOf('.');
                  if (dotIdx >= 0 && f.name.substring(dotIdx + 1) == call.function) {
                    final prefix = f.name.substring(0, dotIdx);
                    if (prefix == qualSuper || prefix == superType) {
                      return _callFunction(m.name, f, input);
                    }
                  }
                }
              }
            }
            superType = _findTypeDef(qualSuper)?.superclass;
          }
        }
      }
    }

    return _resolveAndCallFunction(call.module, call.function, input);
  }

  // ---- Literals ----

  Future<Object?> _evalLiteral(Literal lit, _Scope scope) async {
    return switch (lit.whichValue()) {
      Literal_Value.intValue => lit.intValue.toInt(),
      Literal_Value.doubleValue => lit.doubleValue,
      Literal_Value.stringValue => lit.stringValue,
      Literal_Value.boolValue => lit.boolValue,
      Literal_Value.bytesValue => lit.bytesValue.toList(),
      Literal_Value.listValue => await _evalListLiteral(lit.listValue, scope),
      Literal_Value.notSet => null,
    };
  }

  /// Evaluates a list literal, handling collection_if and collection_for.
  Future<BallList> _evalListLiteral(ListLiteral listVal, _Scope scope) async {
    final result = <Object?>[];
    for (final element in listVal.elements) {
      if (element.hasCall()) {
        final call = element.call;
        final fn = call.function;
        if ((call.module == 'dart_std' || call.module == 'std') &&
            fn == 'collection_if') {
          await _evalCollectionIf(call, scope, result);
          continue;
        }
        if ((call.module == 'dart_std' || call.module == 'std') &&
            fn == 'collection_for') {
          await _evalCollectionFor(call, scope, result);
          continue;
        }
      }
      result.add(await _evalExpression(element, scope));
    }
    return BallList(result);
  }

  /// Evaluates collection_if: if (condition) value [else elseValue]
  Future<void> _evalCollectionIf(
    FunctionCall call,
    _Scope scope,
    List<Object?> result,
  ) async {
    final fields = _lazyFields(call);
    final condExpr = fields['condition'];
    if (condExpr == null) return;
    final cond = _toBool(await _evalExpression(condExpr, scope));
    if (cond) {
      final thenExpr = fields['then'];
      if (thenExpr != null) {
        await _addCollectionElement(thenExpr, scope, result);
      }
    } else {
      final elseExpr = fields['else'];
      if (elseExpr != null) {
        await _addCollectionElement(elseExpr, scope, result);
      }
    }
  }

  /// Evaluates collection_for: for (var in iterable) body
  Future<void> _evalCollectionFor(
    FunctionCall call,
    _Scope scope,
    List<Object?> result,
  ) async {
    final fields = _lazyFields(call);
    final variable = _stringFieldVal(fields, 'variable');
    final iterableExpr = fields['iterable'];
    final bodyExpr = fields['body'];
    if (iterableExpr == null || bodyExpr == null) return;
    final iterable = await _evalExpression(iterableExpr, scope);
    final iterableList = _asList(iterable);
    if (iterableList == null) return;
    for (final item in iterableList) {
      final loopScope = scope.child();
      loopScope.bind((variable ?? '').isEmpty ? 'item' : variable!, item);
      await _addCollectionElement(bodyExpr, loopScope, result);
    }
  }

  /// Adds a collection element, recursively handling nested collection_if/for.
  Future<void> _addCollectionElement(
    Expression expr,
    _Scope scope,
    List<Object?> result,
  ) async {
    if (expr.hasCall()) {
      final call = expr.call;
      final fn = call.function;
      if ((call.module == 'dart_std' || call.module == 'std') &&
          fn == 'collection_if') {
        await _evalCollectionIf(call, scope, result);
        return;
      }
      if ((call.module == 'dart_std' || call.module == 'std') &&
          fn == 'collection_for') {
        await _evalCollectionFor(call, scope, result);
        return;
      }
    }
    result.add(await _evalExpression(expr, scope));
  }

  // ---- References ----

  Future<Object?> _evalReference(Reference ref, _Scope scope) async {
    final name = ref.name;

    // Handle 'super' keyword: resolve to the __super__ of self.
    if (name == 'super' && scope.has('self')) {
      final self = scope.lookup('self');
      final selfMap = _asMap(self);
      if (selfMap != null) {
        return selfMap['__super__'] ?? self;
      }
    }

    // Handle built-in type references (List, Map, Set) as class-like objects
    // for static method dispatch (e.g., List.generate, Map.fromEntries).
    if (name == 'List' || name == 'Map' || name == 'Set') {
      return BallMap({'__class_ref__': name, '__type__': '__builtin_class__'});
    }

    if (scope.has(name)) return scope.lookup(name);

    // Constructor tear-off: resolve class names and "Class.new" references
    // to callable closures that invoke the constructor function.
    final ctorEntry = _constructors[name];
    if (ctorEntry != null) {
      return (Object? input) async {
        return _callFunction(ctorEntry.module, ctorEntry.func, input);
      };
    }

    // Try stripping module prefix (e.g. "main:Foo" → "Foo").
    final colonIdx = name.indexOf(':');
    if (colonIdx >= 0) {
      final bare = name.substring(colonIdx + 1);
      final bareEntry = _constructors[bare];
      if (bareEntry != null) {
        return (Object? input) async {
          return _callFunction(bareEntry.module, bareEntry.func, input);
        };
      }
    }

    // Enum type reference: resolve to a map of enum values so that
    // field access (e.g. MyEnum.value1) works.
    final enumVals = _enumValues[name];
    if (enumVals != null) return enumVals;

    // Class/type reference: resolve to a namespace object for static
    // method dispatch and named constructor lookup.
    // Only resolve user-defined types (not built-in types like int, String, etc.).
    if (!_builtinTypeNames.contains(name)) {
      final qualifiedName = '$_currentModule:$name';
      // Check if constructors or static methods exist for this class.
      final hasCtor = _constructors.containsKey(name) || _constructors.containsKey(qualifiedName);
      final hasStaticMethods = _functions.keys.any((k) =>
          k.startsWith('$_currentModule.$qualifiedName.') ||
          k.startsWith('$_currentModule.$name.'));
      final typeExists = _types.containsKey(name) || _types.containsKey(qualifiedName);
      if (typeExists && (hasCtor || hasStaticMethods)) {
        return BallMap({'__class_ref__': name, '__type__': '__class__'});
      }
    }

    // Top-level getter: if a function with this name has is_getter metadata,
    // invoke it as a zero-arg getter (no input needed).
    final getterKey = '$_currentModule.$name';
    final getterFunc = _functions[getterKey];
    if (getterFunc != null && _isGetter(getterFunc)) {
      return _callFunction(_currentModule, getterFunc, null);
    }

    // Fallback: if `self` is in scope, try looking up the field on it.
    // This handles method bodies that reference instance fields like `name`
    // even when the field wasn't explicitly bound (e.g., inherited fields).
    if (scope.has('self')) {
      final self = scope.lookup('self');
      final selfMap = _asMap(self);
      if (selfMap != null) {
        if (selfMap.containsKey(name)) return selfMap[name];
        // Check __super__ chain for inherited fields.
        var superObj = selfMap['__super__'];
        var superMap = _asMap(superObj);
        while (superMap != null) {
          if (superMap.containsKey(name)) return superMap[name];
          superObj = superMap['__super__'];
          superMap = _asMap(superObj);
        }
        // Try getter dispatch on self.
        final typeName = selfMap['__type__'] as String?;
        if (typeName != null) {
          final getterResult = await _tryGetterDispatch(selfMap, name);
          if (getterResult != _sentinel) return getterResult;
        }
      }
    }

    // Top-level function tear-off: resolve function names to callable closures.
    for (final m in program.modules) {
      for (final f in m.functions) {
        if (f.name == name && !f.isBase && f.hasBody()) {
          if (f.hasMetadata()) {
            final kindField = f.metadata.fields['kind'];
            final kind = kindField?.stringValue;
            if (kind == 'top_level_variable') {
              // Use the current value from globalScope (which may have been
              // mutated via assign) instead of re-evaluating the body.
              if (_globalScope.has(name)) {
                return _globalScope.lookup(name);
              }
              return _callFunction(m.name, f, null);
            }
            if (kind == 'function') {
              final modName = m.name;
              return (Object? input) async {
                return _callFunction(modName, f, input);
              };
            }
          }
        }
      }
    }

    // Static field lookup: when inside a method/constructor, resolve bare names
    // like "_cache" to "ClassName._cache" static fields.
    // Use the cached value from _globalScope if already initialized.
    for (final m in program.modules) {
      for (final f in m.functions) {
        if (f.hasMetadata()) {
          final kind = f.metadata.fields['kind']?.stringValue;
          if (kind == 'static_field') {
            final dotIdx = f.name.lastIndexOf('.');
            if (dotIdx >= 0 && f.name.substring(dotIdx + 1) == name) {
              // Return the cached value from _globalScope.
              if (_globalScope.has(f.name)) {
                return _globalScope.lookup(f.name);
              }
              return _callFunction(m.name, f, null);
            }
          }
        }
      }
    }

    return scope.lookup(name);
  }

  // ---- Field Access ----

  Future<Object?> _evalFieldAccess(FieldAccess access, _Scope scope) async {
    final object = await _evalExpression(access.object, scope);
    final fieldName = access.field_2;

    // Unwrap BallMap once so all downstream checks work uniformly.
    final objectMap = _asMap(object);

    // ── Built-in class reference field access (List.generate, etc.) ──
    if (objectMap != null && objectMap['__type__'] == '__builtin_class__') {
      final className = objectMap['__class_ref__'] as String;
      // Return a closure that dispatches via the built-in class method handler.
      return (Object? input) async {
        final argsMap = _asMap(input);
        final args = argsMap ?? <String, Object?>{'arg0': input};
        final result = await _dispatchBuiltinClassMethod(className, fieldName, args);
        if (result != _sentinel) return result;
        throw BallRuntimeError('Unknown static method: $className.$fieldName');
      };
    }

    // ── Class reference field access (static methods, named ctors) ──
    if (objectMap != null && objectMap['__type__'] == '__class__') {
      final className = objectMap['__class_ref__'] as String;
      final qualifiedName = className.contains(':') ? className : '$_currentModule:$className';

      // Named constructor: "ClassName.ctorName"
      final namedCtor = _constructors['$qualifiedName.$fieldName'] ??
          _constructors['$className.$fieldName'];
      if (namedCtor != null) {
        return (Object? input) async {
          return _callFunction(namedCtor.module, namedCtor.func, input);
        };
      }

      // Static method: look up "module.qualifiedName.methodName"
      final colonIdx = qualifiedName.indexOf(':');
      final modPart = colonIdx >= 0 ? qualifiedName.substring(0, colonIdx) : _currentModule;
      final staticKey = '$modPart.$qualifiedName.$fieldName';
      final staticFunc = _functions[staticKey];
      if (staticFunc != null) {
        return (Object? input) async {
          return _callFunction(modPart, staticFunc, input);
        };
      }

      // Enum values on class ref
      final enumVals = _enumValues[className] ?? _enumValues[qualifiedName];
      if (enumVals != null && enumVals.containsKey(fieldName)) {
        return enumVals[fieldName];
      }
    }

    // ── Map / message field access ─────────────────────────────
    if (objectMap != null) {
      if (objectMap.containsKey(fieldName)) return objectMap[fieldName];

      // Walk the __super__ chain for inherited fields.
      var superObj = objectMap['__super__'];
      var superMap = _asMap(superObj);
      while (superMap != null) {
        if (superMap.containsKey(fieldName)) return superMap[fieldName];
        superObj = superMap['__super__'];
        superMap = _asMap(superObj);
      }

      // Look up methods on the object.
      final methods = objectMap['__methods__'];
      if (methods is Map<String, Function> && methods.containsKey(fieldName)) {
        return methods[fieldName];
      }

      // Walk __super__ chain for methods.
      superObj = objectMap['__super__'];
      superMap = _asMap(superObj);
      while (superMap != null) {
        final superMethods = superMap['__methods__'];
        if (superMethods is Map<String, Function> &&
            superMethods.containsKey(fieldName)) {
          return superMethods[fieldName];
        }
        superObj = superMap['__super__'];
        superMap = _asMap(superObj);
      }

      // Virtual fields on maps / message instances.
      switch (fieldName) {
        case 'keys':
          return objectMap.keys.toList();
        case 'values':
          return objectMap.values.toList();
        case 'length':
          return objectMap.length;
        case 'isEmpty':
          return objectMap.isEmpty;
        case 'isNotEmpty':
          return objectMap.isNotEmpty;
        case 'entries':
          return objectMap.entries
              .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
              .toList();
      }

      // Getter dispatch: if the field isn't a data field, check for a getter
      // function on the object's type (metadata has is_getter: true).
      final getterResult = await _tryGetterDispatch(objectMap, fieldName);
      if (getterResult != _sentinel) return getterResult;

      throw BallRuntimeError(
        'Field "$fieldName" not found. '
        'Available: ${objectMap.keys.toList()}',
      );
    }

    // ── Virtual properties on built-in types ───────────────────
    // Mirrors V8's LoadIC prototype-chain lookup for common properties.
    // Unwrap BallList so property access works on wrapped lists too.
    final rawList = _asList(object);
    switch (fieldName) {
      case 'length':
        if (object is String) return object.length;
        if (rawList != null) return rawList.length;
        if (object is Map) return object.length;
        if (object is Set) return object.length;
      case 'isEmpty':
        if (object is String) return object.isEmpty;
        if (rawList != null) return rawList.isEmpty;
        if (object is Map) return object.isEmpty;
        if (object is Set) return object.isEmpty;
      case 'isNotEmpty':
        if (object is String) return object.isNotEmpty;
        if (rawList != null) return rawList.isNotEmpty;
        if (object is Map) return object.isNotEmpty;
        if (object is Set) return object.isNotEmpty;
      case 'first':
        if (rawList != null && rawList.isNotEmpty) return rawList.first;
        if (object is Set && object.isNotEmpty) return object.first;
      case 'last':
        if (rawList != null && rawList.isNotEmpty) return rawList.last;
        if (object is Set && object.isNotEmpty) return object.last;
      case 'single':
        if (rawList != null && rawList.length == 1) return rawList.single;
        if (object is Set && object.length == 1) return object.single;
      case 'reversed':
        if (rawList != null) return rawList.reversed.toList();
      case 'keys':
        if (object is Map) return object.keys.toList();
      case 'values':
        if (object is Map) return object.values.toList();
      case 'isNaN':
        if (object is double) return object.isNaN;
      case 'isFinite':
        if (object is double) return object.isFinite;
      case 'isInfinite':
        if (object is double) return object.isInfinite;
      case 'isNegative':
        if (object is num) return object.isNegative;
      case 'sign':
        if (object is num) return object.sign;
      case 'abs':
        if (object is num) return object.abs();
      case 'runtimeType':
        return object?.runtimeType.toString() ?? 'Null';
    }

    throw BallRuntimeError(
      'Cannot access field "$fieldName" on '
      '${object?.runtimeType ?? "null"}',
    );
  }

  /// Try to dispatch a getter function for [fieldName] on [object].
  /// Returns [_sentinel] if no getter was found, otherwise the getter result.
  Future<Object?> _tryGetterDispatch(
    Map<String, Object?> object,
    String fieldName,
  ) async {
    final typeName = object['__type__'] as String?;
    if (typeName == null) return _sentinel;

    final colonIdx = typeName.indexOf(':');
    final modPart =
        colonIdx >= 0 ? typeName.substring(0, colonIdx) : _currentModule;

    // Check "module.typeName.fieldName" as a getter.
    final getterKey = '$modPart.$typeName.$fieldName';
    final getterFunc = _getters[getterKey] ?? _functions[getterKey];
    if (getterFunc != null && _isGetter(getterFunc)) {
      return _callFunction(
        modPart,
        getterFunc,
        <String, Object?>{'self': object},
      );
    }

    // Walk __super__ chain for inherited getters.
    var superObj = object['__super__'];
    var superMap = _asMap(superObj);
    while (superMap != null) {
      final superType = superMap['__type__'] as String?;
      if (superType != null) {
        final sColonIdx = superType.indexOf(':');
        final sModPart =
            sColonIdx >= 0 ? superType.substring(0, sColonIdx) : modPart;
        final sTypeName =
            sColonIdx >= 0 ? superType : '$sModPart:$superType';
        final superGetterKey = '$sModPart.$sTypeName.$fieldName';
        final superGetterFunc = _getters[superGetterKey] ?? _functions[superGetterKey];
        if (superGetterFunc != null && _isGetter(superGetterFunc)) {
          return _callFunction(
            sModPart,
            superGetterFunc,
            <String, Object?>{'self': object},
          );
        }
      }
      superObj = superMap['__super__'];
      superMap = _asMap(superObj);
    }

    return _sentinel;
  }

  /// Returns true if the function has `is_getter: true` or `kind: "getter"` in its metadata.
  bool _isGetter(FunctionDefinition func) {
    if (!func.hasMetadata()) return false;
    final field = func.metadata.fields['is_getter'];
    if (field != null && field.boolValue) return true;
    final kind = func.metadata.fields['kind'];
    if (kind != null && kind.stringValue == 'getter') return true;
    return false;
  }

  /// Returns true if the function has `is_setter: true` or `kind: "setter"` in its metadata.
  bool _isSetter(FunctionDefinition func) {
    if (!func.hasMetadata()) return false;
    final field = func.metadata.fields['is_setter'];
    if (field != null && field.boolValue) return true;
    final kind = func.metadata.fields['kind'];
    return kind != null && kind.stringValue == 'setter';
  }

  /// Try to dispatch a setter function for [fieldName] on [object].
  /// Returns [_sentinel] if no setter was found, otherwise the setter result.
  Future<Object?> _trySetterDispatch(
    Map<String, Object?> object,
    String fieldName,
    Object? value,
  ) async {
    final typeName = object['__type__'] as String?;
    if (typeName == null) return _sentinel;

    final colonIdx = typeName.indexOf(':');
    final modPart =
        colonIdx >= 0 ? typeName.substring(0, colonIdx) : _currentModule;

    // Setter functions are named "TypeName.fieldName=" by convention.
    // Also check without the "=" suffix since some setters share the exact
    // name with their getter (distinguished only by metadata).
    final setterKey = '$modPart.$typeName.$fieldName=';
    final setterKeyNoEq = '$modPart.$typeName.$fieldName';
    final setterFunc = _setters[setterKey] ?? _setters[setterKeyNoEq] ?? _functions[setterKey];
    if (setterFunc != null && _isSetter(setterFunc)) {
      return _callFunction(
        modPart,
        setterFunc,
        <String, Object?>{'self': object, 'value': value},
      );
    }

    // Walk __super__ chain for inherited setters.
    var superObj = object['__super__'];
    var superMap = _asMap(superObj);
    while (superMap != null) {
      final superType = superMap['__type__'] as String?;
      if (superType != null) {
        final sColonIdx = superType.indexOf(':');
        final sModPart =
            sColonIdx >= 0 ? superType.substring(0, sColonIdx) : modPart;
        final sTypeName =
            sColonIdx >= 0 ? superType : '$sModPart:$superType';
        final superSetterKey = '$sModPart.$sTypeName.$fieldName=';
        final superSetterKeyNoEq = '$sModPart.$sTypeName.$fieldName';
        final superSetterFunc = _setters[superSetterKey] ?? _setters[superSetterKeyNoEq] ?? _functions[superSetterKey];
        if (superSetterFunc != null && _isSetter(superSetterFunc)) {
          return _callFunction(
            sModPart,
            superSetterFunc,
            <String, Object?>{'self': object, 'value': value},
          );
        }
      }
      superObj = superMap['__super__'];
      superMap = _asMap(superObj);
    }

    return _sentinel;
  }

  /// When inside a method, sync a field assignment back to the self object.
  /// Mirrors the TS engine's syncFieldToSelf.
  void _syncFieldToSelf(_Scope scope, String fieldName, Object? val) {
    if (!scope.has('self')) return;
    try {
      final self = scope.lookup('self');
      final selfMap = _asMap(self);
      if (selfMap != null && selfMap.containsKey('__type__')) {
        if (selfMap.containsKey(fieldName)) {
          selfMap[fieldName] = val;
        }
        // Also sync to __super__ chain.
        var superObj = selfMap['__super__'];
        var superMap = _asMap(superObj);
        while (superMap != null) {
          if (superMap.containsKey(fieldName)) {
            superMap[fieldName] = val;
          }
          superObj = superMap['__super__'];
          superMap = _asMap(superObj);
        }
      }
    } catch (_) {
      // Ignore — not inside a method.
    }
  }

  // ---- Message Creation ----

  Future<Object?> _evalMessageCreation(MessageCreation msg, _Scope scope) async {
    final fields = <String, Object?>{};
    // Track which field names appear multiple times (e.g., repeated 'entry'
    // in map_create). When a duplicate is found, convert to a list.
    for (final pair in msg.fields) {
      final val = await _evalExpression(pair.value, scope);
      if (fields.containsKey(pair.name)) {
        final existing = fields[pair.name];
        if (existing is List) {
          existing.add(val);
        } else {
          fields[pair.name] = [existing, val];
        }
      } else {
        fields[pair.name] = val;
      }
    }
    if (msg.typeName.isNotEmpty) {
      // Check if this type has a constructor — if so, invoke it to build
      // the instance properly (maps arg0/arg1/... to named fields via is_this).
      final ctorEntry = _constructors[msg.typeName];
      if (ctorEntry != null) {
        return _callFunction(ctorEntry.module, ctorEntry.func, fields);
      }

      fields['__type__'] = msg.typeName;

      // Extract type arguments if generic (e.g., Box<int>).
      final genMatch = RegExp(r'^(\w+)<(.+)>$').firstMatch(msg.typeName);
      if (genMatch != null) {
        fields['__type__'] = genMatch.group(1)!;
        fields['__type_args__'] = _splitTypeArgs(genMatch.group(2)!);
      }

      // Check if this type has a superclass (inheritance support).
      // Resolve from TypeDefinition metadata or DescriptorProto.
      final typeDef = _findTypeDef(msg.typeName);
      if (typeDef != null) {
        // Initialize fields with default values from metadata if not
        // already present in the message creation.
        _initFieldDefaults(msg.typeName, fields);

        final superclass = _getMetaString(typeDef, 'superclass');
        if (superclass != null && superclass.isNotEmpty) {
          // Recursively build the __super__ object with inherited fields & methods.
          fields['__super__'] = _buildSuperObject(superclass, fields);
        }

        // Resolve methods from the type's module (includes inherited methods).
        final methods = _resolveTypeMethodsWithInheritance(msg.typeName);
        if (methods.isNotEmpty) {
          fields['__methods__'] = methods;
        }
      } else {
        // No typeDef found: the typeName might be a function/method call
        // encoded as messageCreation (common in encoder-generated IR).
        // Try resolving it as a function.
        final fnKey = '$_currentModule.${msg.typeName}';
        final fnMatch = _functions[fnKey];
        if (fnMatch != null && !fnMatch.isBase && fnMatch.hasBody()) {
          // If self is in scope and the function is a method, call with self.
          if (scope.has('self')) {
            final kindField = fnMatch.hasMetadata() ? fnMatch.metadata.fields['kind'] : null;
            if (kindField?.stringValue == 'method') {
              final selfObj = scope.lookup('self');
              fields['self'] = selfObj;
            }
          }
          return _callFunction(_currentModule, fnMatch, fields);
        }

        // Try resolving via self's type: typeName "main:_gcd" -> method on self's type.
        if (scope.has('self')) {
          final selfObj = scope.lookup('self');
          final selfObjMap = _asMap(selfObj);
          if (selfObjMap != null) {
            final selfType = selfObjMap['__type__'] as String?;
            if (selfType != null) {
              // Extract method name from typeName (e.g., "main:_gcd" -> "_gcd").
              final colonIdx = msg.typeName.indexOf(':');
              final methodName = colonIdx >= 0 ? msg.typeName.substring(colonIdx + 1) : msg.typeName;
              final resolved = _resolveMethod(selfType, methodName);
              if (resolved != null) {
                fields['self'] = selfObj;
                return _callFunction(resolved.module, resolved.func, fields);
              }
            }
          }
        }

        // Scan all modules for matching function name.
        // Only match explicit functions/methods, not constructors or top-level
        // variables which would cause infinite recursion.
        for (final m in program.modules) {
          for (final f in m.functions) {
            if (f.name == msg.typeName && !f.isBase && f.hasBody()) {
              if (f.hasMetadata()) {
                final k = f.metadata.fields['kind']?.stringValue;
                if (k == 'constructor' || k == 'top_level_variable' || k == 'static_field') continue;
              }
              return _callFunction(m.name, f, fields);
            }
          }
        }
      }
    }
    return BallMap(fields);
  }

  /// Find a TypeDefinition by name across all modules.
  ({String? superclass, List<String> fieldNames})? _findTypeDef(
    String typeName,
  ) {
    for (final module in program.modules) {
      for (final td in module.typeDefs) {
        if (td.name == typeName || td.name.endsWith(':$typeName')) {
          String? superclass;
          if (td.hasMetadata()) {
            final sc = td.metadata.fields['superclass'];
            if (sc != null && sc.hasStringValue()) {
              superclass = sc.stringValue;
            }
          }
          final fieldNames = <String>[];
          if (td.hasDescriptor()) {
            for (final f in td.descriptor.field) {
              fieldNames.add(f.name);
            }
          }
          // Also collect fields from metadata 'fields' array.
          if (td.hasMetadata()) {
            final fieldsMetaVal = td.metadata.fields['fields'];
            if (fieldsMetaVal != null &&
                fieldsMetaVal.whichKind() == structpb.Value_Kind.listValue) {
              for (final fv in fieldsMetaVal.listValue.values) {
                if (fv.whichKind() == structpb.Value_Kind.structValue) {
                  final fname = fv.structValue.fields['name']?.stringValue;
                  if (fname != null && !fieldNames.contains(fname)) {
                    fieldNames.add(fname);
                  }
                }
              }
            }
          }
          return (superclass: superclass, fieldNames: fieldNames);
        }
      }
    }
    return null;
  }

  /// Get a string value from TypeDefinition metadata.
  /// Initialize fields with default values from the typeDef metadata.
  /// Only sets fields that are not already present in the instance.
  void _initFieldDefaults(String typeName, Map<String, Object?> fields) {
    for (final module in program.modules) {
      for (final td in module.typeDefs) {
        if (td.name == typeName || td.name.endsWith(':$typeName')) {
          if (td.hasMetadata()) {
            final fieldsMetaVal = td.metadata.fields['fields'];
            if (fieldsMetaVal != null &&
                fieldsMetaVal.whichKind() == structpb.Value_Kind.listValue) {
              for (final fv in fieldsMetaVal.listValue.values) {
                if (fv.whichKind() != structpb.Value_Kind.structValue) continue;
                final fname = fv.structValue.fields['name']?.stringValue;
                if (fname == null || fields.containsKey(fname)) continue;
                final init = fv.structValue.fields['initializer']?.stringValue;
                if (init != null) {
                  fields[fname] = _parseInitializer(init);
                }
              }
            }
          }
          return;
        }
      }
    }
  }

  /// Parse a simple initializer string like "[]", "{}", "0", "''", etc.
  Object? _parseInitializer(String init) {
    final trimmed = init.trim();
    if (trimmed == '[]') return <Object?>[];
    if (trimmed == '{}') return <String, Object?>{};
    if (trimmed == 'null') return null;
    if (trimmed == 'true') return true;
    if (trimmed == 'false') return false;
    if (trimmed == '""' || trimmed == "''") return '';
    final intVal = int.tryParse(trimmed);
    if (intVal != null) return intVal;
    final doubleVal = double.tryParse(trimmed);
    if (doubleVal != null) return doubleVal;
    // String literal with quotes
    if ((trimmed.startsWith("'") && trimmed.endsWith("'")) ||
        (trimmed.startsWith('"') && trimmed.endsWith('"'))) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }

  String? _getMetaString(
    ({String? superclass, List<String> fieldNames}) typeDef,
    String key,
  ) {
    if (key == 'superclass') return typeDef.superclass;
    return null;
  }

  /// Build a `__super__` object for the given superclass name.
  ///
  /// Populates the super object with:
  /// - The parent's descriptor fields (defaults from the child if present)
  /// - The parent's methods
  /// - Recursively, the grandparent's `__super__` object
  Map<String, Object?> _buildSuperObject(
    String superclass,
    Map<String, Object?> childFields,
  ) {
    // Qualify the superclass name if it's bare (no module prefix).
    final qualifiedSuperclass = superclass.contains(':')
        ? superclass
        : '$_currentModule:$superclass';
    final superFields = <String, Object?>{'__type__': qualifiedSuperclass};

    // Copy descriptor fields from the parent type into __super__.
    final parentTypeDef = _findTypeDef(superclass);
    if (parentTypeDef != null) {
      for (final fname in parentTypeDef.fieldNames) {
        // If the child already set this field, propagate it to super too.
        if (childFields.containsKey(fname)) {
          superFields[fname] = childFields[fname];
        }
        // Otherwise leave it absent (will be null on access).
      }

      // Attach methods belonging to the parent type.
      final parentMethods = _resolveTypeMethods(superclass);
      if (parentMethods.isNotEmpty) {
        superFields['__methods__'] = parentMethods;
      }

      // Recurse: if the parent itself has a superclass, build its __super__.
      final grandparent = parentTypeDef.superclass;
      if (grandparent != null && grandparent.isNotEmpty) {
        superFields['__super__'] = _buildSuperObject(grandparent, childFields);
      }
    }

    return superFields;
  }

  /// Resolve methods associated with a type name from its module.
  Map<String, Function> _resolveTypeMethods(String typeName) {
    final methods = <String, Function>{};
    for (final module in program.modules) {
      for (final func in module.functions) {
        // Match by metadata class field.
        if (func.hasMetadata()) {
          final className = func.metadata.fields['class'];
          if (className != null &&
              className.hasStringValue() &&
              className.stringValue == typeName &&
              func.hasBody()) {
            methods[func.name] = (Object? input) async {
              return _callFunction(module.name, func, input);
            };
            continue;
          }
        }
        // Match by function name pattern: "TypeName.methodName" or
        // "module:TypeName.methodName".
        // Skip constructors and getters/setters (they have their own dispatch paths).
        final funcName = func.name;
        final dotIdx = funcName.lastIndexOf('.');
        if (dotIdx >= 0) {
          final prefix = funcName.substring(0, dotIdx);
          final suffix = funcName.substring(dotIdx + 1);
          // Skip constructors (e.g. "Foo.new", "Foo.named").
          if (suffix == 'new') continue;
          final kindField2 = func.hasMetadata() ? func.metadata.fields['kind'] : null;
          if (kindField2?.stringValue == 'constructor') continue;
          if (prefix == typeName && func.hasBody() && !func.isBase) {
            methods[func.name] = (Object? input) async {
              return _callFunction(module.name, func, input);
            };
          }
        }
      }
    }
    return methods;
  }

  /// Resolve methods for a type including inherited methods from ancestors
  /// and mixins.
  ///
  /// Methods from the child type take precedence over parent methods
  /// (method overriding). Mixin methods are applied between superclass
  /// and child (so child overrides mixin, mixin overrides superclass).
  Map<String, Function> _resolveTypeMethodsWithInheritance(String typeName) {
    final methods = <String, Function>{};

    final colonIdx = typeName.indexOf(':');
    final modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : _currentModule;

    // Collect ancestor methods first (so child overrides them).
    final typeDef = _findTypeDef(typeName);
    if (typeDef != null && typeDef.superclass != null && typeDef.superclass!.isNotEmpty) {
      final qualSuper = typeDef.superclass!.contains(':')
          ? typeDef.superclass!
          : '$modPart:${typeDef.superclass!}';
      methods.addAll(_resolveTypeMethodsWithInheritance(qualSuper));
    }

    // Apply mixin methods (between superclass and child).
    final mixins = _getMixins(typeName);
    for (final mixin in mixins) {
      final qualMixin = mixin.contains(':') ? mixin : '$modPart:$mixin';
      methods.addAll(_resolveTypeMethods(qualMixin));
    }

    // Child methods override parent and mixin methods.
    methods.addAll(_resolveTypeMethods(typeName));
    return methods;
  }

  // ---- Block ----

  Future<Object?> _evalBlock(Block block, _Scope scope) async {
    final blockScope = scope.child();
    Object? flowResult;
    for (final stmt in block.statements) {
      final result = await _evalStatement(stmt, blockScope);
      if (result is _FlowSignal) {
        // Run scope-exits in LIFO order before propagating the signal.
        await _runScopeExits(blockScope);
        return result;
      }
    }
    if (block.hasResult()) {
      flowResult = await _evalExpression(block.result, blockScope);
    } else {
      flowResult = null;
    }
    // Run scope-exits in LIFO order (normal exit).
    await _runScopeExits(blockScope);
    return flowResult;
  }

  /// Execute all registered scope-exit cleanups in LIFO order.
  Future<void> _runScopeExits(_Scope blockScope) async {
    if (blockScope._scopeExits.isEmpty) return;
    for (final (expr, evalScope) in blockScope._scopeExits.reversed) {
      try {
        await _evalExpression(expr, evalScope);
      } catch (_) {
        // Scope-exit cleanup errors are swallowed (RAII destructor semantics).
      }
    }
  }

  Future<Object?> _evalStatement(Statement stmt, _Scope scope) async {
    switch (stmt.whichStmt()) {
      case Statement_Stmt.let:
        var value = await _evalExpression(stmt.let.value, scope);
        if (value is _FlowSignal) return value;
        // If the let type says Map but we got an empty Set or List,
        // convert to an empty map (mirrors the encoder using set_create
        // for empty map literals).
        if (stmt.let.hasMetadata()) {
          final letType = stmt.let.metadata.fields['type']?.stringValue;
          if (letType != null && letType.startsWith('Map')) {
            if (value is Set && value.isEmpty) value = <Object?, Object?>{};
            if (value is List && value.isEmpty) value = <Object?, Object?>{};
          }
        }
        scope.bind(stmt.let.name, value);
        return null;
      case Statement_Stmt.expression:
        return _evalExpression(stmt.expression, scope);
      case Statement_Stmt.notSet:
        return null;
    }
  }

  // ---- Lambda ----

  Object? _evalLambda(FunctionDefinition func, _Scope scope) {
    // Capture the scope for closures.
    return (Object? input) async {
      final lambdaScope = scope.child();
      // Always bind `input` so body code referencing the Ball convention
      // name resolves.
      lambdaScope.bind('input', input);

      // Bind declared parameter names. For a lambda with positional
      // params `(x)`, a scalar input binds to `x`. For multi-param or
      // named params, the encoder packs the call site into a
      // messageCreation and the input is a map whose keys match param
      // names — that path uses the map loop below.
      final paramNames =
          func.hasMetadata() ? _extractParams(func.metadata) : const <String>[];
      final inputMap = _asMap(input);
      if (paramNames.length == 1 && inputMap == null) {
        lambdaScope.bind(paramNames.first, input);
      }

      // Bind map-style args (multi-param call sites / message creations).
      if (inputMap != null) {
        for (final entry in inputMap.entries) {
          if (entry.key != '__type__') {
            lambdaScope.bind(entry.key, entry.value);
          }
        }
        // Also bind positional args (arg0, arg1, ...) to declared param names
        // so that lambdas with named params receive values passed positionally.
        if (paramNames.isNotEmpty) {
          for (var i = 0; i < paramNames.length; i++) {
            final p = paramNames[i];
            if (!lambdaScope.has(p)) {
              if (inputMap.containsKey(p)) {
                lambdaScope.bind(p, inputMap[p]);
              } else if (inputMap.containsKey('arg$i')) {
                lambdaScope.bind(p, inputMap['arg$i']);
              }
            }
          }
        }
      }
      if (!func.hasBody()) return null;
      final result = await _evalExpression(func.body, lambdaScope);
      if (result is _FlowSignal && result.kind == 'return') {
        return result.value;
      }
      return result;
    };
  }


}
