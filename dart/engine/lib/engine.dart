/// Ball engine — interprets and executes ball programs at runtime.
///
/// The engine walks the expression tree and evaluates it directly,
/// without generating any intermediate source code.
///
/// Fully compliant with the ball.v1 proto schema.
/// Supports the universal std library base functions.
library;

import 'ball_value.dart';
export 'ball_value.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/gen/google/protobuf/descriptor.pb.dart' as google;
import 'package:ball_resolver/ball_resolver.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart'
    as structpb;

part 'engine_types.dart';
part 'engine_invocation.dart';
part 'engine_eval.dart';
part 'engine_control_flow.dart';
part 'engine_std.dart';

class BallEngine {
  final Program program;

  /// Resolved type definitions by name.
  final Map<String, google.DescriptorProto> _types = {};

  /// Resolved functions by "module.function" key.
  final Map<String, FunctionDefinition> _functions = {};

  /// Separate getter function map to avoid setter overwriting getter when they
  /// share the same key.
  final Map<String, FunctionDefinition> _getters = {};

  /// Separate setter function map.
  final Map<String, FunctionDefinition> _setters = {};

  /// Global scope with top-level variable bindings.
  final _Scope _globalScope = _Scope();

  /// Standard output sink (overridable for testing).
  void Function(String) stdout;

  /// Current module context (set during function execution).
  String _currentModule = '';

  /// Innermost sync*/async* scope — std.yield collects into its __generator__.
  _Scope? _activeGeneratorScope;

  /// Consume std.yield / yield_each flow signals inside a generator function.
  Object? _consumeGeneratorFlow(Object? result) {
    if (result is! _FlowSignal) return result;
    final gs = _activeGeneratorScope;
    if (gs == null || !gs.has('__generator__')) return result;
    final gen = gs.lookup('__generator__');
    if (gen is! BallGenerator) return result;
    if (result.kind == 'yield') {
      gen.yield_(result.value);
      return null;
    }
    if (result.kind == 'yield_each') {
      final val = result.value;
      if (val is BallGenerator) {
        gen.yieldAll(val.values);
      } else {
        gen.yieldAll(_toIterable(val));
      }
      return null;
    }
    return result;
  }

  /// Pre-resolved parameter name lists, keyed by "module.function".
  /// Built once in [_buildLookupTables] to avoid repeated metadata parsing.
  final Map<String, List<String>> _paramCache = {};

  /// Lazily-populated function resolution cache for module-unqualified calls.
  /// Eliminates O(n) linear scans through all modules on repeated calls.
  final Map<String, ({String module, FunctionDefinition func})> _callCache = {};

  /// Pre-built instance-method dispatch keyed by "typePrefix\0methodName".
  /// Covers cross-module definitions; inheritance resolved at lookup time.
  final Map<String, ({String module, FunctionDefinition func})>
  _typeMethodDispatch = {};

  /// Inline cache for (typeName, methodName) instance-method resolution.
  final Map<String, ({String module, FunctionDefinition func})?>
  _instanceMethodCache = {};

  /// Pre-built top-level reference bindings keyed by bare function name.
  final Map<String, ({String module, FunctionDefinition func, String kind})>
  _topLevelRefs = {};

  /// Pre-built static-field bindings keyed by bare field name.
  final Map<String, ({String module, FunctionDefinition func, String fullName})>
  _staticFieldRefs = {};

  /// Enum type registry: maps enum type names (both qualified "module:Enum"
  /// and bare "Enum") to a map of value name → enum value object.
  /// Each enum value is a Map with __type__, name, index.
  final Map<String, Map<String, Object?>> _enumValues = {};

  /// Constructor registry: maps bare class names (and "module:Class" qualified
  /// names) to the default `.new` constructor function definition.  Populated
  /// during [_buildLookupTables] for every function whose metadata has
  /// `kind: "constructor"`.  Used by [_evalReference] to resolve constructor
  /// tear-offs and by [_resolveAndCallFunction] as a fallback.
  final Map<String, ({String module, FunctionDefinition func})> _constructors =
      {};

  /// Optional per-function call counters. Enabled via [enableProfiling].
  /// Mirrors V8's bytecode dispatch counters (GetDispatchCountersObject).
  Map<String, int>? _callCounts;

  /// Maximum number of nested non-base Ball function calls allowed.
  final int maxRecursionDepth;

  /// Maximum wall-clock execution time in milliseconds for [run].
  /// `null` disables timeout enforcement.
  final int? timeoutMs;

  /// Maximum approximate memory allocated for Ball values in bytes.
  /// `null` disables memory limit enforcement.
  final int? maxMemoryBytes;

  /// Maximum number of modules accepted in the program.
  final int maxModules;

  /// Maximum nested expression evaluation depth.
  final int maxExpressionDepth;

  /// Maximum protobuf binary size accepted for the program.
  /// `null` disables program size enforcement (default — opt-in for trusted runs).
  final int? maxProgramSizeBytes;

  /// When true, blocks all I/O / process-affecting base functions
  /// (file_*, dir_*, env_get, exit, panic) by throwing [BallRuntimeError].
  /// Use for evaluating untrusted programs.
  final bool sandbox;

  /// Approximate bytes allocated by Ball values during this engine run.
  int _memoryUsedBytes = 0;

  /// Current nested expression evaluation depth.
  int _expressionDepth = 0;

  /// Millisecond timestamp captured when [run] starts.
  int? _executionStartMs;

  /// Current nested non-base Ball function call depth.
  int _recursionDepth = 0;

  /// Registered module handlers consulted by [_callBaseFunction].
  ///
  /// The list is searched in order; the first handler for which
  /// [BallModuleHandler.handles] returns `true` wins. Defaults to
  /// `[StdModuleHandler()]`, which provides the complete built-in std library.
  final List<BallModuleHandler> moduleHandlers;

  /// Shared random number generator for `random_int` / `random_double`.
  final math.Random _random = math.Random();

  /// Standard error sink (overridable for testing).
  void Function(String) stderr;

  /// Standard input line reader (overridable for testing). `null` = no stdin.
  String Function()? stdinReader;

  /// Environment variable getter (overridable for sandboxing).
  String Function(String) _envGet;

  /// Command-line arguments passed to the program.
  List<String> _args;

  /// Counter for simulated mutex handles (single-threaded mode).
  int _nextMutexId = 0;

  /// The exception currently bound inside an active `catch` block, or `null`.
  /// Used by the `rethrow` base function to re-raise the original exception.
  /// Saved and restored around each catch body so nested tries unwind cleanly.
  Object? _activeException;

  // toString recursion guard: [_ballToStringAsync] sets a sentinel key
  // (`__tostring_guard__`) directly on each typed-object map while evaluating
  // its toString method. If re-entered for the same object, the key is already
  // present and a safe placeholder is returned. This approach is portable
  // across all Ball targets (Dart, TS, C++).

  /// Optional module resolver for lazy-loading unresolved module imports.
  /// When set, if a cross-module call targets a module not yet in the
  /// lookup tables, the engine checks `module_imports` and resolves on demand.
  final ModuleResolver? _resolver;

  /// Completes when top-level variable initialisation is done.
  late final Future<void> _initialized;

  BallEngine(
    this.program, {
    void Function(String)? stdout,
    void Function(String)? stderr,
    this.stdinReader,
    String Function(String)? envGet,
    List<String>? args,
    bool enableProfiling = false,
    this.maxRecursionDepth = 10000,
    this.timeoutMs,
    this.maxMemoryBytes,
    this.maxModules = 100,
    this.maxExpressionDepth = 1000,
    this.maxProgramSizeBytes,
    this.sandbox = false,
    List<BallModuleHandler>? moduleHandlers,
    ModuleResolver? resolver,
  }) : stdout = stdout ?? print,
       _resolver = resolver,
       stderr = stderr ?? ((s) => io.stderr.writeln(s)),
       _envGet = envGet ?? ((name) => io.Platform.environment[name] ?? ''),
       _args = args ?? [],
       moduleHandlers = moduleHandlers ?? [StdModuleHandler()] {
    _validateProgramLimits();
    if (enableProfiling) _callCounts = {};
    for (final handler in this.moduleHandlers) {
      handler.init(this);
    }
    _buildLookupTables();
    _initialized = _initTopLevelVariables();
  }

  /// Returns an unmodifiable snapshot of profiling call counts.
  /// Keys are std function names; values are invocation counts.
  /// Returns an empty map when profiling was not enabled.
  Map<String, int> profilingReport() => Map.unmodifiable(_callCounts ?? {});

  /// Invoke any ball function by [module] and [function] name with [input].
  Future<Object?> callFunction(String module, String function, Object? input) =>
      _resolveAndCallFunction(module, function, input);

  void _validateProgramLimits() {
    final moduleCount = program.modules.length;
    if (moduleCount > maxModules) {
      throw BallRuntimeError(
        'Too many modules: $moduleCount (max $maxModules)',
      );
    }

    final maxProgramBytes = maxProgramSizeBytes;
    if (maxProgramBytes != null) {
      final programSizeBytes = program.writeToBuffer().length;
      if (programSizeBytes > maxProgramBytes) {
        throw BallRuntimeError(
          'Program too large: $programSizeBytes bytes (max $maxProgramBytes)',
        );
      }
    }

    _validateStaticExpressionDepth();
  }

  void _validateStaticExpressionDepth() {
    for (final module in program.modules) {
      for (final func in module.functions) {
        if (func.hasBody()) _validateExpressionDepth(func.body);
      }
    }
  }

  void _validateExpressionDepth(Expression root) {
    final stack = <({Expression expr, int depth})>[(expr: root, depth: 1)];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      final depth = current.depth;
      if (depth > maxExpressionDepth) {
        throw BallRuntimeError(
          'Expression too deep: $depth levels (max $maxExpressionDepth)',
        );
      }

      switch (current.expr.whichExpr()) {
        case Expression_Expr.call:
          final call = current.expr.call;
          if (call.hasInput()) {
            stack.add((expr: call.input, depth: depth + 1));
          }
        case Expression_Expr.literal:
          final literal = current.expr.literal;
          if (literal.hasListValue()) {
            for (final element in literal.listValue.elements) {
              stack.add((expr: element, depth: depth + 1));
            }
          }
        case Expression_Expr.fieldAccess:
          final access = current.expr.fieldAccess;
          if (access.hasObject()) {
            stack.add((expr: access.object, depth: depth + 1));
          }
        case Expression_Expr.messageCreation:
          for (final field in current.expr.messageCreation.fields) {
            if (field.hasValue()) {
              stack.add((expr: field.value, depth: depth + 1));
            }
          }
        case Expression_Expr.block:
          final block = current.expr.block;
          for (final statement in block.statements) {
            switch (statement.whichStmt()) {
              case Statement_Stmt.let:
                final binding = statement.let;
                if (binding.hasValue()) {
                  stack.add((expr: binding.value, depth: depth + 1));
                }
              case Statement_Stmt.expression:
                stack.add((expr: statement.expression, depth: depth + 1));
              case Statement_Stmt.notSet:
                break;
            }
          }
          if (block.hasResult()) {
            stack.add((expr: block.result, depth: depth + 1));
          }
        case Expression_Expr.lambda:
          final lambda = current.expr.lambda;
          if (lambda.hasBody()) {
            stack.add((expr: lambda.body, depth: depth + 1));
          }
        case Expression_Expr.reference:
        case Expression_Expr.notSet:
          break;
      }
    }
  }

  void _checkExpressionDepth() {
    _expressionDepth += 1;
    if (_expressionDepth > maxExpressionDepth) {
      throw BallRuntimeError(
        'Expression too deep: $_expressionDepth levels (max $maxExpressionDepth)',
      );
    }
  }

  void _exitExpression() {
    _expressionDepth -= 1;
  }

  void _buildLookupTables() {
    for (final module in program.modules) {
      for (final td in module.typeDefs) {
        if (td.hasDescriptor()) {
          _types[td.name] = td.descriptor;
          final tc = td.name.indexOf(':');
          if (tc >= 0) _types[td.name.substring(tc + 1)] = td.descriptor;
        }
      }
      for (final enumDesc in module.enums) {
        final enumName = enumDesc.name;
        final enumMap = <String, Map<String, Object?>>{};
        final enumValueList = enumDesc.value;
        for (var vi = 0; vi < enumValueList.length; vi++) {
          final v = enumValueList[vi];
          final entry = <String, Object?>{
            '__type__': enumName,
            'name': v.name,
            'index': v.number,
          };
          enumMap[v.name] = entry;
        }
        _enumValues[enumName] = enumMap;
        final ec = enumName.indexOf(':');
        if (ec >= 0) {
          _enumValues[enumName.substring(ec + 1)] = enumMap;
        }
      }

      for (final func in module.functions) {
        final key = '${module.name}.${func.name}';
        if (func.hasMetadata()) {
          final isGetterField = func.metadata.fields['is_getter'];
          final isSetterField = func.metadata.fields['is_setter'];
          if (_metadataBool(isGetterField)) {
            _getters[key] = func;
          } else if (_metadataBool(isSetterField)) {
            _setters[key] = func;
            _setters['$key='] = func;
          }
          if (_metadataBool(isSetterField)) {
            _functions.putIfAbsent(key, () => func);
          } else {
            _functions[key] = func;
          }
        } else {
          _functions[key] = func;
        }
        if (func.hasMetadata()) {
          final params = _extractParams(func.metadata);
          // Only cache NAMED functions: a nameless function (lambda) keys to
          // "$module." and would collide with every other nameless function in
          // the module (#246). The lookup extracts a nameless func's params inline.
          if (func.name.isNotEmpty && params.isNotEmpty) {
            _paramCache[key] = params;
          }

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
        _registerFunctionDispatchTables(module, func);
      }
    }
  }

  static String _typeMethodKey(String typePrefix, String methodName) =>
      '$typePrefix\x00$methodName';

  void _registerFunctionDispatchTables(Module module, FunctionDefinition func) {
    if (func.isBase || !func.hasBody()) return;

    if (func.hasMetadata()) {
      final kind = func.metadata.fields['kind']?.stringValue;
      if (kind == 'top_level_variable' || kind == 'function') {
        _topLevelRefs.putIfAbsent(
          func.name,
          () => (module: module.name, func: func, kind: kind!),
        );
      }
      if (kind == 'static_field') {
        final dotIdx = func.name.lastIndexOf('.');
        if (dotIdx >= 0) {
          final bareName = func.name.substring(dotIdx + 1);
          _staticFieldRefs.putIfAbsent(
            bareName,
            () => (module: module.name, func: func, fullName: func.name),
          );
        }
      }
    }

    final funcName = func.name;
    final dotIdx = funcName.lastIndexOf('.');
    if (dotIdx < 0) return;

    final methodName = funcName.substring(dotIdx + 1);
    if (methodName == 'new') return;
    if (_isGetter(func) || _isSetter(func)) return;
    final kindField = func.hasMetadata() ? func.metadata.fields['kind'] : null;
    if (kindField?.stringValue == 'constructor') return;

    final entry = (module: module.name, func: func);
    final typePrefix = funcName.substring(0, dotIdx);
    _typeMethodDispatch[_typeMethodKey(typePrefix, methodName)] = entry;

    if (func.hasMetadata()) {
      final className = func.metadata.fields['class'];
      if (className != null && className.hasStringValue()) {
        _typeMethodDispatch[_typeMethodKey(className.stringValue, methodName)] =
            entry;
      }
    }
  }

  /// Resolve an instance method using pre-built dispatch tables and inheritance.
  /// Returns null when no matching method exists on the type hierarchy.
  ({String module, FunctionDefinition func})? _resolveInstanceMethodDispatch(
    String typeName,
    String methodName,
  ) {
    final cacheKey = _typeMethodKey(typeName, methodName);
    if (_instanceMethodCache.containsKey(cacheKey)) {
      return _instanceMethodCache[cacheKey];
    }

    final resolved =
        _resolveMethod(typeName, methodName) ??
        _lookupTypeMethodWithInheritance(typeName, methodName);
    _instanceMethodCache[cacheKey] = resolved;
    return resolved;
  }

  ({String module, FunctionDefinition func})? _lookupTypeMethodWithInheritance(
    String typeName,
    String methodName,
  ) {
    final colonIdx = typeName.indexOf(':');
    final modPart = colonIdx >= 0
        ? typeName.substring(0, colonIdx)
        : _currentModule;

    var current = typeName;
    while (current.isNotEmpty) {
      final direct = _typeMethodDispatch[_typeMethodKey(current, methodName)];
      if (direct != null) return direct;

      final currentColon = current.indexOf(':');
      if (currentColon >= 0) {
        final bare = current.substring(currentColon + 1);
        final bareHit = _typeMethodDispatch[_typeMethodKey(bare, methodName)];
        if (bareHit != null) return bareHit;
      }

      final typeDef = _findTypeDef(current);
      if (typeDef == null ||
          typeDef.superclass == null ||
          typeDef.superclass!.isEmpty) {
        break;
      }
      final superclass = typeDef.superclass!;
      current = superclass.contains(':') ? superclass : '$modPart:$superclass';
    }

    final mixins = _getMixins(typeName);
    for (final mixin in mixins) {
      final qualMixin = mixin.contains(':') ? mixin : '$modPart:$mixin';
      final mixinHit =
          _typeMethodDispatch[_typeMethodKey(qualMixin, methodName)];
      if (mixinHit != null) return mixinHit;
      final mixinColon = qualMixin.indexOf(':');
      if (mixinColon >= 0) {
        final bareMixin = qualMixin.substring(mixinColon + 1);
        final bareMixinHit =
            _typeMethodDispatch[_typeMethodKey(bareMixin, methodName)];
        if (bareMixinHit != null) return bareMixinHit;
      }
    }

    return null;
  }

  /// Initialize top-level variables by evaluating their body expressions.
  Future<void> _initTopLevelVariables() async {
    for (final module in program.modules) {
      if (module.name == 'std') continue;
      for (final func in module.functions) {
        if (!func.hasMetadata()) continue;
        final kindValue = func.metadata.fields['kind'];
        final kindStr = kindValue?.stringValue;
        if (kindStr != 'top_level_variable' && kindStr != 'static_field')
          continue;
        _currentModule = module.name;
        var value = func.hasBody()
            ? await _evalExpression(func.body, _globalScope)
            : null;
        if (func.outputType.startsWith('Map')) {
          // An ambiguous empty `{}` initializer for a Map-typed static/top-level
          // field arrives as an empty ordered set; coerce it to a real map.
          // Test the portable set form via `_isBallSet`/`_ballSetItems` (not the
          // bare `value is Set`, which compiles to `ball_is_ball_set` on the C++
          // self-host and is true for the *non-empty* one-key set map, whose
          // `.isEmpty` is then false — silently skipping the coercion). Mirrors
          // the `let`/field-type hook in engine_eval.dart. Issue #68.
          if (_isBallSet(value) && _ballSetItems(value).isEmpty) {
            value = _ballUserMap();
          }
          if (value is List && value.isEmpty) {
            value = _ballUserMap();
          }
        }
        _globalScope.bind(func.name, value);
      }
    }
  }

  /// Execute the program starting from the entry point.
  Future<Object?> run() async {
    _executionStartMs = DateTime.now().millisecondsSinceEpoch;
    await _initialized;
    final key = '${program.entryModule}.${program.entryFunction}';
    final entryFunc = _functions[key];
    if (entryFunc == null) {
      throw BallRuntimeError(
        'Entry point "${program.entryFunction}" not found '
        'in module "${program.entryModule}"',
      );
    }
    _currentModule = program.entryModule;
    return _callFunction(program.entryModule, entryFunc, null);
  }

  void _checkExecutionTimeout() {
    final timeout = timeoutMs;
    final start = _executionStartMs;
    if (timeout == null || start == null) return;

    final elapsed = DateTime.now().millisecondsSinceEpoch - start;
    if (elapsed > timeout) {
      throw BallRuntimeError('Execution timeout exceeded');
    }
  }

  String _trackStringAllocation(String value) {
    _trackMemoryAllocation(value.length * _ballStringCodeUnitBytes);
    return value;
  }

  List<int> _trackByteListAllocation(List<int> value) {
    _trackMemoryAllocation(value.length * _ballPointerBytes);
    return value;
  }

  void _trackMemoryAllocation(int bytes) {
    final limit = maxMemoryBytes;
    if (limit == null || bytes <= 0) return;

    if (_memoryUsedBytes + bytes > limit) {
      throw BallRuntimeError('Memory limit exceeded');
    }
    _memoryUsedBytes += bytes;
  }
}
