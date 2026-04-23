/// Ball engine — interprets and executes ball programs at runtime.
///
/// The engine walks the expression tree and evaluates it directly,
/// without generating any intermediate source code.
///
/// Fully compliant with the ball.v1 proto schema.
/// Supports all 73 std base functions.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/gen/google/protobuf/descriptor.pb.dart' as google;
import 'package:ball_resolver/ball_resolver.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart'
    as structpb;

/// Runtime value representation.
///
/// Every ball value is one of:
///   - int, double, String, bool (scalars)
///   - `List<int>` (bytes)
///   - `List<Object?>` (list literal)
///   - `Map<String, Object?>` (message instance — field name → value)
///   - Function (lambda / closure)
///   - null (void / unset)
typedef BallValue = Object?;

/// Callable signature for invoking a ball function by module + name.
///
/// Exposed as [BallEngine.callFunction] and passed to
/// [BallModuleHandler.call] so handlers can compose other modules
/// without holding a direct [BallEngine] reference.
typedef BallCallable =
    FutureOr<BallValue> Function(String module, String function, BallValue input);

/// Sentinel for break/continue/return flow control.
class _FlowSignal {
  final String kind; // 'break', 'continue', 'return'
  final String? label;
  final BallValue value; // only for 'return'
  _FlowSignal(this.kind, {this.label, this.value});
}

/// A scope contains variable bindings. Scopes are chained for lexical nesting.
class _Scope {
  final Map<String, BallValue> _bindings = {};
  final _Scope? _parent;

  /// Registered scope-exit cleanups added by `cpp_std.cpp_scope_exit`.
  /// Each entry is an (expression, evalScope) pair executed in LIFO order
  /// when the scope that owns this list is torn down.
  final List<(Expression, _Scope)> _scopeExits = [];

  _Scope([this._parent]);

  BallValue lookup(String name) {
    if (_bindings.containsKey(name)) return _bindings[name];
    if (_parent != null) return _parent.lookup(name);
    throw BallRuntimeError('Undefined variable: "$name"');
  }

  void bind(String name, BallValue value) {
    _bindings[name] = value;
  }

  bool has(String name) {
    if (_bindings.containsKey(name)) return true;
    return _parent?.has(name) ?? false;
  }

  void set(String name, BallValue value) {
    if (_bindings.containsKey(name)) {
      _bindings[name] = value;
      return;
    }
    if (_parent != null && _parent.has(name)) {
      _parent.set(name, value);
      return;
    }
    _bindings[name] = value;
  }

  /// Register a cleanup expression + its evaluation scope.
  /// Executed in LIFO order when the owning block exits.
  void registerScopeExit(Expression cleanup, _Scope evalScope) {
    _scopeExits.add((cleanup, evalScope));
  }

  _Scope child() => _Scope(this);
}

/// Error thrown when a ball program encounters a runtime error.
class BallRuntimeError implements Exception {
  final String message;
  BallRuntimeError(this.message);
  @override
  String toString() => 'BallRuntimeError: $message';
}

/// Wrapper for async results in the synchronous interpreter.
///
/// Since the engine is a tree-walking interpreter where all I/O is
/// synchronous, `async` functions wrap their return values in a
/// [BallFuture] and `await` unwraps them. This faithfully simulates
/// the async/await protocol without real concurrency.
class BallFuture {
  /// The resolved value (always completed in a synchronous interpreter).
  final BallValue value;

  /// Whether this future has completed (always `true` in sync mode).
  final bool completed;

  BallFuture(this.value, {this.completed = true});

  @override
  String toString() => 'BallFuture($value)';
}

/// Wrapper for generator results in the synchronous interpreter.
///
/// `sync*` functions collect yielded values into a [BallGenerator],
/// which is returned as a list of values.
class BallGenerator {
  /// The yielded values.
  final List<BallValue> values = [];

  /// Whether this generator has completed.
  bool completed = false;

  /// Add a yielded value.
  void yield_(BallValue value) => values.add(value);

  /// Add all values from an iterable (yield*).
  void yieldAll(Iterable<BallValue> items) => values.addAll(items);

  @override
  String toString() => 'BallGenerator(${values.length} values)';
}

/// A typed exception thrown by a Ball program's `throw` expression.
/// Preserves the original value so catch clauses can match on type.
class BallException implements Exception {
  /// The type name of the thrown value (e.g. "FormatException").
  final String typeName;

  /// The actual thrown value (could be a string, map, etc.).
  final Object? value;

  BallException(this.typeName, this.value);

  @override
  String toString() => value?.toString() ?? typeName;
}

/// Thrown by `std_io.exit` / `std_io.panic` to terminate gracefully.
class _ExitSignal implements Exception {
  final int code;
  _ExitSignal(this.code);
}

// ============================================================
// Module Handler API
// ============================================================

/// Contract for a ball base-module handler.
///
/// [BallEngine] routes every `isBase` function call through its registered
/// [moduleHandlers], delegating to the first one whose [handles] returns
/// `true`. Implement this class to add entirely new modules or to replace
/// the built-in [StdModuleHandler]:
///
/// ```dart
/// class DbHandler extends BallModuleHandler {
///   @override bool handles(String module) => module == 'db';
///   @override BallValue call(String fn, BallValue input, BallCallable engine) {
///     return switch (fn) {
///       'query' => _runQuery(input),
///       _ => throw BallRuntimeError('Unknown db function: "$fn"'),
///     };
///   }
/// }
/// ```
///
/// ### Composition-only ball modules
/// If a ball program module contains **only user-defined (non-`isBase`)
/// functions** that delegate to other modules, no handler is needed at all.
/// The engine evaluates their bodies and resolves cross-module calls
/// automatically:
///
/// ```
/// // ball program (proto/JSON)
/// module math_utils:
///   function hypotenuse(a, b):   // isBase: false, has a body
///     std.math_sqrt(std.add(std.math_pow(a,2), std.math_pow(b,2)))
/// ```
///
/// ### Handler composition (handler calling handler)
/// If your handler needs to call another ball function (user-defined or
/// from another module), use the [BallCallable] passed to [call]:
///
/// ```dart
/// class MathFacade extends BallModuleHandler {
///   @override bool handles(String m) => m == 'myfacade';
///   @override BallValue call(String fn, BallValue input, BallCallable engine) {
///     if (fn == 'taxed_total')
///       return engine('myfacade', 'subtotal', input)
///              + engine('tax', 'compute', input);
///     throw BallRuntimeError('unknown: $fn');
///   }
/// }
/// ```
abstract class BallModuleHandler {
  /// Returns true when this handler is responsible for [module].
  bool handles(String module);

  /// Executes [function] with the given [input] value.
  ///
  /// [engine] is a [BallCallable] that lets this handler compose other
  /// ball functions (user-defined or from other handlers) without holding
  /// a direct engine reference:
  ///
  /// ```dart
  /// final sub = engine('std', 'subtract',
  ///     {'left': highPrice, 'right': lowPrice});
  /// ```
  ///
  /// Throws [BallRuntimeError] when [function] is not supported.
  FutureOr<BallValue> call(String function, BallValue input, BallCallable engine);

  /// Called once by [BallEngine] during construction, before any program
  /// statements are evaluated. Override to capture engine state (e.g.
  /// [BallEngine.stdout]) or to lazily build dispatch tables.
  void init(BallEngine engine) {}
}

/// The built-in `std` / `dart_std` module handler.
///
/// Provides all 73+ standard ball functions. Can be customised before
/// passing to [BallEngine]:
///
/// ```dart
/// // Register a custom function alongside the built-ins:
/// final std = StdModuleHandler()
///   ..register('my_func', (input) => 42);
///
/// // Override the default print implementation:
/// final std = StdModuleHandler()
///   ..register('print', (i) { myLogger.log(i); return null; });
///
/// // Only expose a subset of functions (e.g. no math, no collections):
/// final std = StdModuleHandler.subset({'print', 'add', 'subtract', 'equals'});
///
/// final engine = BallEngine(program, moduleHandlers: [std]);
/// ```
class StdModuleHandler extends BallModuleHandler {
  /// Live dispatch table: function name → handler closure.
  /// Populated during [init]; can be extended/trimmed via [register] /
  /// [unregister] either before or after engine construction.
  final Map<String, FutureOr<BallValue> Function(BallValue)> _dispatch = {};

  /// Composition-aware dispatch table for closures that need [BallCallable].
  /// Checked before [_dispatch] so [registerComposer] can override built-ins.
  final Map<String, FutureOr<BallValue> Function(BallValue, BallCallable)>
  _composedDispatch = {};

  /// Optional allow-list for [StdModuleHandler.subset]; `null` = all.
  final Set<String>? _allowlist;

  /// Tombstones: functions explicitly [unregister]ed *before* [init].
  /// Prevents the auto-build phase from re-adding them as built-ins.
  final Set<String> _tombstones = {};

  /// Creates a handler that exposes the full set of built-in std functions.
  StdModuleHandler() : _allowlist = null;

  /// Creates a handler that only exposes the named [functions].
  ///
  /// Any function not in the set will throw [BallRuntimeError] at runtime,
  /// which is useful for sandboxing or building a minimal runtime.
  StdModuleHandler.subset(Iterable<String> functions)
    : _allowlist = functions.toSet();

  @override
  bool handles(String module) => switch (module) {
    'std' ||
    'dart_std' ||
    'std_collections' ||
    'std_io' ||
    'std_memory' ||
    'std_convert' ||
    'std_fs' ||
    'std_time' ||
    'std_concurrency' ||
    'cpp_std' => true,
    _ => false,
  };

  @override
  void init(BallEngine engine) {
    // _buildStdDispatch lives in BallEngine so it can close over all the
    // engine helper methods (same Dart library → library-private access).
    final full = engine._buildStdDispatch();
    final allowlist = _allowlist;
    // Add built-ins using putIfAbsent so that:
    //   • functions pre-registered via register() are NOT overwritten.
    //   • functions pre-removed via unregister() (_tombstones) are skipped.
    for (final entry in full.entries) {
      if (_tombstones.contains(entry.key)) continue;
      if (_composedDispatch.containsKey(entry.key))
        continue; // already overridden
      if (allowlist != null && !allowlist.contains(entry.key)) continue;
      _dispatch.putIfAbsent(entry.key, () => entry.value);
    }
  }

  /// Register or override the handler for [function] (engine-unaware closure).
  ///
  /// Safe to call before or after engine construction. Pre-construction calls
  /// take precedence over built-in defaults; [init] will not overwrite them.
  void register(String function, FutureOr<BallValue> Function(BallValue) handler) {
    _tombstones.remove(function);
    _composedDispatch.remove(function);
    _dispatch[function] = handler;
  }

  /// Register or override a **composition-aware** handler for [function].
  ///
  /// The closure receives the [BallCallable] so it can call back into the
  /// engine to delegate to another module's functions:
  ///
  /// ```dart
  /// std.registerComposer('hypotenuse', (input, engine) {
  ///   final a = (input as Map)['a'] as num;
  ///   final b = (input as Map)['b'] as num;
  ///   final a2 = engine('std', 'math_pow', {'left': a * 1.0, 'right': 2.0});
  ///   final b2 = engine('std', 'math_pow', {'left': b * 1.0, 'right': 2.0});
  ///   return engine('std', 'math_sqrt', {'value': (a2 as num) + (b2 as num)});
  /// });
  /// ```
  void registerComposer(
    String function,
    FutureOr<BallValue> Function(BallValue, BallCallable) handler,
  ) {
    _tombstones.remove(function);
    _dispatch.remove(function);
    _composedDispatch[function] = handler;
  }

  /// Remove [function] from this handler.
  ///
  /// Safe to call before or after engine construction. Pre-construction calls
  /// are remembered so [init] will not re-add the built-in default.
  void unregister(String function) {
    _tombstones.add(function);
    _dispatch.remove(function);
    _composedDispatch.remove(function);
  }

  /// All function names currently registered in this handler.
  Set<String> get registeredFunctions =>
      Set.unmodifiable({..._dispatch.keys, ..._composedDispatch.keys});

  @override
  FutureOr<BallValue> call(String function, BallValue input, BallCallable engine) {
    final composed = _composedDispatch[function];
    if (composed != null) return composed(input, engine);
    final handler = _dispatch[function];
    if (handler == null) {
      throw BallRuntimeError('Unknown std function: "$function"');
    }
    return handler(input);
  }
}

/// Sentinel value used to distinguish "getter not found" from a getter that
/// returned null.
const Object _sentinel = Object();

/// Executes ball programs directly at runtime.
/// Built-in type names that should not be resolved as class references.
const _builtinTypeNames = {
  'int', 'double', 'num', 'String', 'bool', 'List', 'Map', 'Set',
  'Null', 'void', 'Object', 'dynamic', 'Function', 'Future', 'Stream',
  'Iterable', 'Iterator', 'Type', 'Symbol', 'Never',
};

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

  /// Pre-resolved parameter name lists, keyed by "module.function".
  /// Built once in [_buildLookupTables] to avoid repeated metadata parsing.
  final Map<String, List<String>> _paramCache = {};

  /// Lazily-populated function resolution cache for module-unqualified calls.
  /// Eliminates O(n) linear scans through all modules on repeated calls.
  final Map<String, ({String module, FunctionDefinition func})> _callCache = {};

  /// Enum type registry: maps enum type names (both qualified "module:Enum"
  /// and bare "Enum") to a map of value name → enum value object.
  /// Each enum value is a Map with __type__, name, index.
  final Map<String, Map<String, Map<String, Object?>>> _enumValues = {};

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
    List<BallModuleHandler>? moduleHandlers,
    ModuleResolver? resolver,
  }) : stdout = stdout ?? print,
       _resolver = resolver,
       stderr = stderr ?? ((s) => io.stderr.writeln(s)),
       _envGet = envGet ?? ((name) => io.Platform.environment[name] ?? ''),
       _args = args ?? [],
       moduleHandlers = moduleHandlers ?? [StdModuleHandler()] {
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

  // ============================================================
  // Public call bridge — composition entry point
  // ============================================================

  /// Invoke any ball function by [module] and [function] name with [input].
  ///
  /// This is the composition bridge: both user-defined modules and base
  /// module handlers can call back into the engine without a direct
  /// reference to private members.
  ///
  /// A **composition-only module** (one with no `isBase` functions, whose
  /// bodies call other modules) works automatically — its functions are
  /// stored in [_functions] and evaluated normally by [_callFunction].
  /// No handler registration is required for such modules.
  ///
  /// A **custom handler** that needs to delegate to another module can store
  /// the [BallCallable] passed to [BallModuleHandler.call] and invoke it:
  ///
  /// ```dart
  /// class MathFacade extends BallModuleHandler {
  ///   @override bool handles(String m) => m == 'mymath';
  ///   @override BallValue call(String fn, BallValue input, BallCallable engine) {
  ///     // Delegate abs() to std.math_abs
  ///     if (fn == 'abs') return engine('std', 'math_abs', input);
  ///     throw BallRuntimeError('unknown: $fn');
  ///   }
  /// }
  /// ```
  Future<BallValue> callFunction(String module, String function, BallValue input) =>
      _resolveAndCallFunction(module, function, input);

  void _buildLookupTables() {
    for (final module in program.modules) {
      for (final type in module.types) {
        // Primary key: "module:TypeName" (new convention) or bare "TypeName" (std).
        _types[type.name] = type;
        // Also index by bare name (strip "module:" prefix) for backward compat.
        final tc = type.name.indexOf(':');
        if (tc >= 0) _types[type.name.substring(tc + 1)] = type;
      }
      // Index type definitions from typeDefs
      for (final td in module.typeDefs) {
        if (td.hasDescriptor()) {
          _types[td.name] = td.descriptor;
          final tc = td.name.indexOf(':');
          if (tc >= 0) _types[td.name.substring(tc + 1)] = td.descriptor;
        }
      }
      // Index enum types and their values.
      for (final enumDesc in module.enums) {
        final enumName = enumDesc.name; // e.g. "main:Color"
        final values = <String, Map<String, Object?>>{};
        for (final v in enumDesc.value) {
          values[v.name] = <String, Object?>{
            '__type__': enumName,
            'name': v.name,
            'index': v.number,
          };
        }
        _enumValues[enumName] = values;
        // Also index by bare name (strip "module:" prefix).
        final ec = enumName.indexOf(':');
        if (ec >= 0) _enumValues[enumName.substring(ec + 1)] = values;
      }

      for (final func in module.functions) {
        final key = '${module.name}.${func.name}';
        // Store getters and setters in separate maps to avoid collisions
        // when they share the same function name.
        if (func.hasMetadata()) {
          final isGetterField = func.metadata.fields['is_getter'];
          final isSetterField = func.metadata.fields['is_setter'];
          if (isGetterField != null && isGetterField.boolValue) {
            _getters[key] = func;
          } else if (isSetterField != null && isSetterField.boolValue) {
            _setters[key] = func;
            _setters['$key='] = func;
          }
          // Only store in main functions map if not a setter overwriting a getter.
          if (isSetterField != null && isSetterField.boolValue) {
            _functions.putIfAbsent(key, () => func);
          } else {
            _functions[key] = func;
          }
        } else {
          _functions[key] = func;
        }
        // Pre-cache parameter lists from metadata so _callFunction is
        // allocation-free on repeated calls (mirrors V8's constant pool).
        if (func.hasMetadata()) {
          final params = _extractParams(func.metadata);
          if (params.isNotEmpty) _paramCache[key] = params;

          // Register constructors so class names resolve as callables.
          final kindField = func.metadata.fields['kind'];
          if (kindField?.stringValue == 'constructor') {
            final entry = (module: module.name, func: func);
            // func.name is "ClassName.new" or "ClassName.named".
            // For the default constructor (.new), also register bare class name.
            final dotIdx = func.name.indexOf('.');
            if (dotIdx >= 0) {
              final className = func.name.substring(0, dotIdx);
              final ctorSuffix = func.name.substring(dotIdx + 1);
              if (ctorSuffix == 'new') {
                // Bare class name → default constructor
                _constructors[className] = entry;
                // "module:ClassName" qualified form
                _constructors['${module.name}:$className'] = entry;
              }
              // Always register the full "ClassName.ctorName" form
              _constructors[func.name] = entry;
            }
          }
        }
      }
    }
  }

  /// Initialize top-level variables by evaluating their body expressions.
  Future<void> _initTopLevelVariables() async {
    for (final module in program.modules) {
      if (module.name == 'std' || module.name == 'dart_std') continue;
      for (final func in module.functions) {
        if (!func.hasMetadata()) continue;
        final kindValue = func.metadata.fields['kind'];
        final kindStr = kindValue?.stringValue;
        if (kindStr != 'top_level_variable' && kindStr != 'static_field') continue;
        _currentModule = module.name;
        var value = func.hasBody()
            ? await _evalExpression(func.body, _globalScope)
            : null;
        // If type is Map but value is empty Set/List, convert to map.
        if (func.outputType.startsWith('Map')) {
          if (value is Set && value.isEmpty) value = <Object?, Object?>{};
          if (value is List && value.isEmpty) value = <Object?, Object?>{};
        }
        _globalScope.bind(func.name, value);
      }
    }
  }

  /// Execute the program starting from the entry point.
  ///
  /// All expression evaluation is truly async — `await` suspends execution
  /// and Dart's runtime optimises synchronous Future completions.
  Future<BallValue> run() async {
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

  // ============================================================
  // Function Invocation
  // ============================================================

  Future<BallValue> _callFunction(
    String moduleName,
    FunctionDefinition func,
    BallValue input,
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

    // Bind parameters: use pre-built param cache for O(1) lookup.
    final params =
        _paramCache['$moduleName.${func.name}'] ??
        (func.hasMetadata() ? _extractParams(func.metadata) : const []);
    if (params.isNotEmpty) {
      if (params.length == 1 &&
          !(input is Map<String, Object?> && input.containsKey('self'))) {
        // Single parameter — bind the input directly (but not for instance
        // methods where `self` is mixed in; those use the map extraction path).
        // If input is a map with positional args (arg0), extract the value.
        if (input is Map<String, Object?> &&
            input.containsKey('arg0') &&
            !input.containsKey(params[0])) {
          scope.bind(params[0], input['arg0']);
        } else {
          scope.bind(params[0], input);
        }
      } else if (input is Map<String, Object?>) {
        // Multiple parameters — named args or positional arg0/arg1.
        for (var i = 0; i < params.length; i++) {
          final p = params[i];
          if (input.containsKey(p)) {
            scope.bind(p, input[p]);
          } else if (input.containsKey('arg$i')) {
            scope.bind(p, input['arg$i']);
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
    if (input is Map<String, Object?> && input.containsKey('self')) {
      final self = input['self'];
      scope.bind('self', self);
      if (self is Map<String, Object?>) {
        // Bind direct fields. Use temporary debug to trace.
        for (final entry in self.entries) {
          if (!entry.key.startsWith('__')) {
            scope.bind(entry.key, entry.value);
          }
        }
        // Also bind inherited fields from __super__ chain.
        var superObj = self['__super__'];
        while (superObj is Map<String, Object?>) {
          for (final entry in superObj.entries) {
            if (!entry.key.startsWith('__') && !scope.has(entry.key)) {
              scope.bind(entry.key, entry.value);
            }
          }
          superObj = superObj['__super__'];
        }
      }
    }

    if (func.inputType.isNotEmpty && input != null) {
      scope.bind('input', input);
    }
    final result = await _evalExpression(func.body, scope);
    _currentModule = prevModule;

    BallValue finalResult;
    if (result is _FlowSignal && result.kind == 'return') {
      finalResult = result.value;
    } else {
      finalResult = result;
    }

    // Wrap async function results in BallFuture for synchronous simulation.
    if (func.hasMetadata()) {
      final asyncField = func.metadata.fields['is_async'];
      final generatorField = func.metadata.fields['is_generator'];
      if (asyncField != null && asyncField.boolValue) {
        // async function → wrap return value in BallFuture
        if (finalResult is! BallFuture) {
          return BallFuture(finalResult);
        }
      }
      if (generatorField != null && generatorField.boolValue) {
        // sync* function → collect yielded values as list
        if (finalResult is BallGenerator) {
          return finalResult.values;
        }
        if (finalResult is List) {
          return finalResult;
        }
        return [finalResult];
      }
    }

    return finalResult;
  }

  /// Build a class instance from a constructor with no body.
  /// Maps positional args (arg0, arg1, ...) to `is_this` parameter names,
  /// and populates __type__, __super__, and __methods__.
  Future<BallValue> _buildConstructorInstance(
    String moduleName,
    FunctionDefinition func,
    BallValue input,
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
    if (input is Map<String, Object?>) {
      for (var i = 0; i < params.length; i++) {
        final p = params[i];
        final isThis = i < paramsMeta.length && paramsMeta[i]['is_this'] == true;
        BallValue val;
        if (input.containsKey(p)) {
          val = input[p];
        } else if (input.containsKey('arg$i')) {
          val = input['arg$i'];
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
                final arr = resolvedParams[arrName];
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
                instance[name] = valStr.contains('.') ? numVal.toDouble() : numVal.toInt();
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
        if (superInstance is Map<String, Object?>) {
          // Merge super fields into the instance and set __super__.
          instance['__super__'] = superInstance;
          // Copy inherited fields to instance level for easy access.
          for (final e in superInstance.entries) {
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

    return instance;
  }

  /// Invoke the super constructor for a child class.
  Future<BallValue> _invokeSuperConstructor(
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

  Future<BallValue> _resolveAndCallFunction(
    String module,
    String function,
    BallValue input,
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

  // ============================================================
  // Expression Evaluation
  // ============================================================

  Future<BallValue> _evalExpression(Expression expr, _Scope scope) async {
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

  Future<BallValue> _evalCall(FunctionCall call, _Scope scope) async {
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
          if (input is Map<String, Object?>) {
            final a = input['arg0'] ?? input['left'];
            final b = input['arg1'] ?? input['right'];
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
    if (input is Map<String, Object?> && input.containsKey('self')) {
      final self = input['self'];
      if (self is Map<String, Object?>) {
        // Built-in class static method dispatch (List.generate, etc.).
        if (self['__type__'] == '__builtin_class__') {
          final className = self['__class_ref__'] as String;
          final argInput = Map<String, Object?>.from(input)..remove('self');
          final builtinResult = await _dispatchBuiltinClassMethod(
            className, call.function, argInput);
          if (builtinResult != _sentinel) return builtinResult;
        }

        // Static method dispatch on class reference.
        if (self['__type__'] == '__class__') {
          final className = self['__class_ref__'] as String;
          final qualifiedName = className.contains(':') ? className : '$_currentModule:$className';
          final colonIdx2 = qualifiedName.indexOf(':');
          final modPart2 = colonIdx2 >= 0 ? qualifiedName.substring(0, colonIdx2) : _currentModule;
          final staticKey = '$modPart2.$qualifiedName.${call.function}';
          final staticFunc = _functions[staticKey];
          if (staticFunc != null) {
            // Strip 'self' from input for static methods.
            final staticInput = Map<String, Object?>.from(input)..remove('self');
            return _callFunction(modPart2, staticFunc, staticInput);
          }
        }

        final typeName = self['__type__'] as String?;
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
    if (input is Map<String, Object?> && input.containsKey('self')) {
      final self = input['self'];
      if (self is Map<String, Object?>) {
        final typeName = self['__type__'] as String?;
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

  Future<BallValue> _evalLiteral(Literal lit, _Scope scope) async {
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
  Future<List<Object?>> _evalListLiteral(ListLiteral listVal, _Scope scope) async {
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
    return result;
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
    if (iterable is! List) return;
    for (final item in iterable) {
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

  Future<BallValue> _evalReference(Reference ref, _Scope scope) async {
    final name = ref.name;

    // Handle 'super' keyword: resolve to the __super__ of self.
    if (name == 'super' && scope.has('self')) {
      final self = scope.lookup('self');
      if (self is Map<String, Object?>) {
        return self['__super__'] ?? self;
      }
    }

    // Handle built-in type references (List, Map, Set) as class-like objects
    // for static method dispatch (e.g., List.generate, Map.fromEntries).
    if (name == 'List' || name == 'Map' || name == 'Set') {
      return <String, Object?>{'__class_ref__': name, '__type__': '__builtin_class__'};
    }

    if (scope.has(name)) return scope.lookup(name);

    // Constructor tear-off: resolve class names and "Class.new" references
    // to callable closures that invoke the constructor function.
    final ctorEntry = _constructors[name];
    if (ctorEntry != null) {
      return (BallValue input) async {
        return _callFunction(ctorEntry.module, ctorEntry.func, input);
      };
    }

    // Try stripping module prefix (e.g. "main:Foo" → "Foo").
    final colonIdx = name.indexOf(':');
    if (colonIdx >= 0) {
      final bare = name.substring(colonIdx + 1);
      final bareEntry = _constructors[bare];
      if (bareEntry != null) {
        return (BallValue input) async {
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
        return <String, Object?>{'__class_ref__': name, '__type__': '__class__'};
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
      if (self is Map<String, Object?>) {
        if (self.containsKey(name)) return self[name];
        // Check __super__ chain for inherited fields.
        var superObj = self['__super__'];
        while (superObj is Map<String, Object?>) {
          if (superObj.containsKey(name)) return superObj[name];
          superObj = superObj['__super__'];
        }
        // Try getter dispatch on self.
        final typeName = self['__type__'] as String?;
        if (typeName != null) {
          final getterResult = await _tryGetterDispatch(self, name);
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
              return (BallValue input) async {
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

  Future<BallValue> _evalFieldAccess(FieldAccess access, _Scope scope) async {
    final object = await _evalExpression(access.object, scope);
    final fieldName = access.field_2;

    // ── Built-in class reference field access (List.generate, etc.) ──
    if (object is Map<String, Object?> && object['__type__'] == '__builtin_class__') {
      final className = object['__class_ref__'] as String;
      // Return a closure that dispatches via the built-in class method handler.
      return (BallValue input) async {
        final args = input is Map<String, Object?> ? input : <String, Object?>{'arg0': input};
        final result = await _dispatchBuiltinClassMethod(className, fieldName, args);
        if (result != _sentinel) return result;
        throw BallRuntimeError('Unknown static method: $className.$fieldName');
      };
    }

    // ── Class reference field access (static methods, named ctors) ──
    if (object is Map<String, Object?> && object['__type__'] == '__class__') {
      final className = object['__class_ref__'] as String;
      final qualifiedName = className.contains(':') ? className : '$_currentModule:$className';

      // Named constructor: "ClassName.ctorName"
      final namedCtor = _constructors['$qualifiedName.$fieldName'] ??
          _constructors['$className.$fieldName'];
      if (namedCtor != null) {
        return (BallValue input) async {
          return _callFunction(namedCtor.module, namedCtor.func, input);
        };
      }

      // Static method: look up "module.qualifiedName.methodName"
      final colonIdx = qualifiedName.indexOf(':');
      final modPart = colonIdx >= 0 ? qualifiedName.substring(0, colonIdx) : _currentModule;
      final staticKey = '$modPart.$qualifiedName.$fieldName';
      final staticFunc = _functions[staticKey];
      if (staticFunc != null) {
        return (BallValue input) async {
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
    if (object is Map<String, Object?>) {
      if (object.containsKey(fieldName)) return object[fieldName];

      // Walk the __super__ chain for inherited fields.
      var superObj = object['__super__'];
      while (superObj is Map<String, Object?>) {
        if (superObj.containsKey(fieldName)) return superObj[fieldName];
        superObj = superObj['__super__'];
      }

      // Look up methods on the object.
      final methods = object['__methods__'];
      if (methods is Map<String, Function> && methods.containsKey(fieldName)) {
        return methods[fieldName];
      }

      // Walk __super__ chain for methods.
      superObj = object['__super__'];
      while (superObj is Map<String, Object?>) {
        final superMethods = superObj['__methods__'];
        if (superMethods is Map<String, Function> &&
            superMethods.containsKey(fieldName)) {
          return superMethods[fieldName];
        }
        superObj = superObj['__super__'];
      }

      // Virtual fields on maps / message instances.
      switch (fieldName) {
        case 'keys':
          return object.keys.toList();
        case 'values':
          return object.values.toList();
        case 'length':
          return object.length;
        case 'isEmpty':
          return object.isEmpty;
        case 'isNotEmpty':
          return object.isNotEmpty;
        case 'entries':
          return object.entries
              .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
              .toList();
      }

      // Getter dispatch: if the field isn't a data field, check for a getter
      // function on the object's type (metadata has is_getter: true).
      final getterResult = await _tryGetterDispatch(object, fieldName);
      if (getterResult != _sentinel) return getterResult;

      throw BallRuntimeError(
        'Field "$fieldName" not found. '
        'Available: ${object.keys.toList()}',
      );
    }

    // ── Virtual properties on built-in types ───────────────────
    // Mirrors V8's LoadIC prototype-chain lookup for common properties.
    switch (fieldName) {
      case 'length':
        if (object is String) return object.length;
        if (object is List) return object.length;
        if (object is Map) return object.length;
        if (object is Set) return object.length;
      case 'isEmpty':
        if (object is String) return object.isEmpty;
        if (object is List) return object.isEmpty;
        if (object is Map) return object.isEmpty;
        if (object is Set) return object.isEmpty;
      case 'isNotEmpty':
        if (object is String) return object.isNotEmpty;
        if (object is List) return object.isNotEmpty;
        if (object is Map) return object.isNotEmpty;
        if (object is Set) return object.isNotEmpty;
      case 'first':
        if (object is List && object.isNotEmpty) return object.first;
        if (object is Set && object.isNotEmpty) return object.first;
      case 'last':
        if (object is List && object.isNotEmpty) return object.last;
        if (object is Set && object.isNotEmpty) return object.last;
      case 'single':
        if (object is List && object.length == 1) return object.single;
        if (object is Set && object.length == 1) return object.single;
      case 'reversed':
        if (object is List) return object.reversed.toList();
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
  Future<BallValue> _tryGetterDispatch(
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
    while (superObj is Map<String, Object?>) {
      final superType = superObj['__type__'] as String?;
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
      superObj = superObj['__super__'];
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
  Future<BallValue> _trySetterDispatch(
    Map<String, Object?> object,
    String fieldName,
    BallValue value,
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
    while (superObj is Map<String, Object?>) {
      final superType = superObj['__type__'] as String?;
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
      superObj = superObj['__super__'];
    }

    return _sentinel;
  }

  /// When inside a method, sync a field assignment back to the self object.
  /// Mirrors the TS engine's syncFieldToSelf.
  void _syncFieldToSelf(_Scope scope, String fieldName, BallValue val) {
    if (!scope.has('self')) return;
    try {
      final self = scope.lookup('self');
      if (self is Map<String, Object?> && self.containsKey('__type__')) {
        if (self.containsKey(fieldName)) {
          self[fieldName] = val;
        }
        // Also sync to __super__ chain.
        var superObj = self['__super__'];
        while (superObj is Map<String, Object?>) {
          if (superObj.containsKey(fieldName)) {
            superObj[fieldName] = val;
          }
          superObj = superObj['__super__'];
        }
      }
    } catch (_) {
      // Ignore — not inside a method.
    }
  }

  // ---- Message Creation ----

  Future<BallValue> _evalMessageCreation(MessageCreation msg, _Scope scope) async {
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
          if (selfObj is Map<String, Object?>) {
            final selfType = selfObj['__type__'] as String?;
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
    return fields;
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
            methods[func.name] = (BallValue input) async {
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
            methods[func.name] = (BallValue input) async {
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

  Future<BallValue> _evalBlock(Block block, _Scope scope) async {
    final blockScope = scope.child();
    BallValue flowResult;
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

  Future<BallValue> _evalStatement(Statement stmt, _Scope scope) async {
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

  BallValue _evalLambda(FunctionDefinition func, _Scope scope) {
    // Capture the scope for closures.
    return (BallValue input) async {
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
      if (paramNames.length == 1 && input is! Map<String, Object?>) {
        lambdaScope.bind(paramNames.first, input);
      }

      // Bind map-style args (multi-param call sites / message creations).
      if (input is Map<String, Object?>) {
        for (final entry in input.entries) {
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
              if (input.containsKey(p)) {
                lambdaScope.bind(p, input[p]);
              } else if (input.containsKey('arg$i')) {
                lambdaScope.bind(p, input['arg$i']);
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


  // ============================================================
  // Lazy-evaluated std functions (control flow)
  // ============================================================

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

  Future<BallValue> _evalLazyIf(FunctionCall call, _Scope scope) async {
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

  Future<BallValue> _evalLazyFor(FunctionCall call, _Scope scope) async {
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
        if (obj is String && prop == 'length') propVal = obj.length;
        else if (obj is List && prop == 'length') propVal = obj.length;
        else if (obj is Map && prop == 'length') propVal = obj.length;
        else if (obj is Map<String, Object?> && obj.containsKey(prop)) {
          final v = obj[prop];
          if (v is num) propVal = v;
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
        if (obj is String && prop == 'length') return obj.length;
        if (obj is List && prop == 'length') return obj.length;
        if (obj is Map && prop == 'length') return obj.length;
        if (obj is Map<String, Object?> && obj.containsKey(prop)) return obj[prop];
      }
    }

    // Variable reference.
    if (scope.has(rawVal)) return scope.lookup(rawVal);

    return rawVal;
  }

  Future<BallValue> _evalLazyForIn(FunctionCall call, _Scope scope) async {
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

  Future<BallValue> _evalLazyWhile(FunctionCall call, _Scope scope) async {
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

  Future<BallValue> _evalLazyDoWhile(FunctionCall call, _Scope scope) async {
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

  Future<BallValue> _evalLazySwitch(FunctionCall call, _Scope scope) async {
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
            final patternVal = (pattern is Map<String, Object?> && pattern.containsKey('value'))
                ? pattern['value']
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
  bool _ballEquals(BallValue a, BallValue b) {
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
  bool _matchSwitchPattern(BallValue subject, String pattern) {
    // Enum pattern: "EnumType.value" (e.g., "Color.red").
    final dotIdx = pattern.indexOf('.');
    if (dotIdx >= 0) {
      final enumType = pattern.substring(0, dotIdx);
      final enumValue = pattern.substring(dotIdx + 1);
      // Subject is an enum value map with __type__ and name fields.
      if (subject is Map<String, Object?>) {
        final typeName = subject['__type__'] as String?;
        if (typeName != null) {
          // Match "Color" against "main:Color" (strip module prefix).
          final colonIdx = typeName.indexOf(':');
          final bareType = colonIdx >= 0 ? typeName.substring(colonIdx + 1) : typeName;
          if (bareType == enumType && subject['name'] == enumValue) return true;
          if (typeName == enumType && subject['name'] == enumValue) return true;
        }
      }
      // Also try resolving the pattern to an actual enum value and comparing.
      final enumVals = _enumValues[enumType];
      if (enumVals != null && enumVals.containsKey(enumValue)) {
        final resolved = enumVals[enumValue];
        if (subject is Map<String, Object?> && resolved is Map<String, Object?>) {
          return subject['__type__'] == resolved['__type__'] &&
              subject['name'] == resolved['name'];
        }
      }
      // Try with module-qualified enum type.
      final qualifiedEnumType = '$_currentModule:$enumType';
      final qualEnumVals = _enumValues[qualifiedEnumType];
      if (qualEnumVals != null && qualEnumVals.containsKey(enumValue)) {
        final resolved = qualEnumVals[enumValue];
        if (subject is Map<String, Object?> && resolved is Map<String, Object?>) {
          return subject['__type__'] == resolved['__type__'] &&
              subject['name'] == resolved['name'];
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

  Future<BallValue> _evalLazyTry(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final body = fields['body'];
    final catches = fields['catches'];
    final finallyBlock = fields['finally'];

    BallValue result;
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

  Future<BallValue> _evalShortCircuitAnd(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final left = fields['left'];
    final right = fields['right'];
    if (left == null || right == null) return false;
    final leftVal = await _evalExpression(left, scope);
    if (!_toBool(leftVal)) return false;
    return _toBool(await _evalExpression(right, scope));
  }

  Future<BallValue> _evalShortCircuitOr(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final left = fields['left'];
    final right = fields['right'];
    if (left == null || right == null) return false;
    final leftVal = await _evalExpression(left, scope);
    if (_toBool(leftVal)) return true;
    return _toBool(await _evalExpression(right, scope));
  }

  Future<BallValue> _evalReturn(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final value = fields['value'];
    final val = value != null ? await _evalExpression(value, scope) : null;
    return _FlowSignal('return', value: val);
  }

  Future<BallValue> _evalBreak(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    return _FlowSignal('break', label: label);
  }

  Future<BallValue> _evalContinue(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    return _FlowSignal('continue', label: label);
  }

  Future<BallValue> _evalAssign(FunctionCall call, _Scope scope) async {
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
      if (obj is Map<String, Object?>) {
        final fieldName = target.fieldAccess.field_2;

        // Compound assignment on field access (e.g. obj.field ??= val)
        if (op != null && op.isNotEmpty && op != '=') {
          final current = obj[fieldName];
          final computed = _applyCompoundOp(op, current, val);
          obj[fieldName] = computed;
          return computed;
        }

        // Check for a setter function before falling back to map write.
        final setterResult = await _trySetterDispatch(obj, fieldName, val);
        if (setterResult != _sentinel) return setterResult;

        obj[fieldName] = val;
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
          if (list is List && idx is int) {
            final current = list[idx];
            final computed = _applyCompoundOp(op, current, val);
            list[idx] = computed;
            return computed;
          }
          if (list is Map) {
            final current = list[idx];
            final computed = _applyCompoundOp(op, current, val);
            list[idx] = computed;
            return computed;
          }
        }

        if (list is List && idx is int) {
          list[idx] = val;
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
  Future<BallValue> _evalNullAwareAssign(
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
      if (obj is Map<String, Object?>) {
        final fieldName = target.fieldAccess.field_2;
        final current = obj[fieldName];
        if (current != null) return current;
        final val = await _evalExpression(value, scope);
        obj[fieldName] = val;
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
        if (list is List && idx is int) {
          final current = list[idx];
          if (current != null) return current;
          final val = await _evalExpression(value, scope);
          list[idx] = val;
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
  Future<BallValue> _evalIncDec(FunctionCall call, _Scope scope) async {
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
        if (container is List && idx is int) {
          final current = _toNum(container[idx]);
          final updated = isInc ? current + 1 : current - 1;
          container[idx] = updated;
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
      if (obj is Map<String, Object?>) {
        final current = _toNum(obj[fieldName]);
        final updated = isInc ? current + 1 : current - 1;
        obj[fieldName] = updated;
        return isPre ? updated : current;
      }
    }

    // Fallback: just compute
    final val = _toNum(await _evalExpression(valueExpr, scope));
    final isInc = call.function.contains('increment');
    return isInc ? val + 1 : val - 1;
  }

  BallValue _applyCompoundOp(String op, BallValue current, BallValue val) {
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

  num _numOp(BallValue a, BallValue b, num Function(num, num) op) =>
      op(_toNum(a), _toNum(b));

  int _intOp(BallValue a, BallValue b, int Function(int, int) op) =>
      op(_toInt(a), _toInt(b));

  Future<BallValue> _evalLabeled(FunctionCall call, _Scope scope) async {
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
  Future<BallValue> _evalLabeledLoop(FunctionCall loopCall, String label, _Scope scope) async {
    return switch (loopCall.function) {
      'for' => _evalLabeledFor(loopCall, label, scope),
      'for_in' => _evalLabeledForIn(loopCall, label, scope),
      'while' => _evalLabeledWhile(loopCall, label, scope),
      'do_while' => _evalLabeledDoWhile(loopCall, label, scope),
      _ => _evalExpression(Expression()..call = loopCall, scope),
    };
  }

  Future<BallValue> _evalLabeledFor(FunctionCall call, String label, _Scope scope) async {
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

  Future<BallValue> _evalLabeledForIn(FunctionCall call, String label, _Scope scope) async {
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

  Future<BallValue> _evalLabeledWhile(FunctionCall call, String label, _Scope scope) async {
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

  Future<BallValue> _evalLabeledDoWhile(FunctionCall call, String label, _Scope scope) async {
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

  Future<BallValue> _evalGoto(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    throw _FlowSignal('goto', label: label);
  }

  Future<BallValue> _evalLabel(FunctionCall call, _Scope scope) async {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'name');
    final body = fields['body'];
    if (body == null) return null;
    // Execute the body; if a goto signal targeting THIS label arrives,
    // re-execute the body (backward goto). For forward gotos, the signal
    // propagates up until the matching label handler catches it.
    BallValue result;
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
  Future<BallValue> _evalLazyCascade(FunctionCall call, _Scope scope) async {
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

  Future<BallValue> _evalAwaitFor(FunctionCall call, _Scope scope) {
    // Reuse for_in logic.
    return _evalLazyForIn(call, scope);
  }

  /// Dispatch a method call on a built-in instance type (List, String, num).
  /// Returns [_sentinel] if the method is not recognized.
  Future<BallValue> _dispatchBuiltinInstanceMethod(
    BallValue self, String method, BallValue input,
  ) async {
    final args = input is Map<String, Object?> ? input : <String, Object?>{};
    final arg0 = args['arg0'] ?? args['value'];

    // ── List / Set methods ──
    if (self is List) {
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
          return self.sublist(_toInt(arg0), end != null ? _toInt(end) : null);
        case 'reversed': return self.reversed.toList();
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
          self.sort((a, b) => (a as Comparable).compareTo(b));
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
          return self;
        case 'where':
        case 'filter':
          if (arg0 is Function) {
            final result = <Object?>[];
            for (final item in self) {
              var r = arg0(item);
              if (r is Future) r = await r;
              if (r == true) result.add(item);
            }
            return result;
          }
          return self;
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
        case 'toList': return self.toList();
        case 'toSet': return self.toSet().toList();
        case 'toString': return '[${self.map(_ballToString).join(', ')}]';
        case 'filled':
          // List.filled(n, value) encoded as self=[], arg0=n, arg1=value
          return List.filled(_toInt(arg0), args['arg1']);
        // Set operations (sets are encoded as arrays).
        case 'union':
          final other = arg0 is List ? arg0 : <Object?>[];
          return {...self, ...other}.toList();
        case 'intersection':
          final otherSet = (arg0 is List ? arg0 : <Object?>[]).toSet();
          return self.where((x) => otherSet.contains(x)).toList();
        case 'difference':
          final otherSet2 = (arg0 is List ? arg0 : <Object?>[]).toSet();
          return self.where((x) => !otherSet2.contains(x)).toList();
        case 'addAll':
          final other2 = arg0 is List ? arg0 : <Object?>[];
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
              if (r is List) {
                result.addAll(r);
              } else {
                result.add(r);
              }
            }
            return result;
          }
          return self;
        case 'take': return self.take(_toInt(arg0)).toList();
        case 'skip': return self.skip(_toInt(arg0)).toList();
        case 'followedBy':
          final other3 = arg0 is List ? arg0 : <Object?>[];
          return [...self, ...other3];
      }
    }

    // ── Set methods ──
    if (self is Set) {
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
    if (self is String) {
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
    if (self is num) {
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
    if (self is Map<String, Object?> && self.containsKey('__type__')) {
      // StringBuffer methods.
      final typeName = self['__type__'] as String?;
      if (typeName != null && (typeName.endsWith(':StringBuffer') || typeName == 'StringBuffer')) {
        switch (method) {
          case 'write':
            self['__buffer__'] = (self['__buffer__'] as String? ?? '') + _ballToString(arg0);
            return null;
          case 'writeln':
            self['__buffer__'] = (self['__buffer__'] as String? ?? '') + _ballToString(arg0) + '\n';
            return null;
          case 'writeCharCode':
            self['__buffer__'] = (self['__buffer__'] as String? ?? '') + String.fromCharCode(_toInt(arg0));
            return null;
          case 'toString': return self['__buffer__'] ?? '';
          case 'clear': self['__buffer__'] = ''; return null;
          case 'length': return (self['__buffer__'] as String? ?? '').length;
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
  BallValue _evalCppScopeExit(FunctionCall call, _Scope scope) {
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

  // ============================================================
  // Base Functions (std + dart_std modules)
  // ============================================================

  // Maps std function names to the Dart operator symbol used in the encoder.
  static const _stdFunctionToOperator = <String, String>{
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

  /// Try to dispatch a std operator call to a user-defined operator override.
  /// Returns `null` if no override is found.
  Future<BallValue?> _tryOperatorOverride(
    String function,
    BallValue input,
  ) async {
    final op = _stdFunctionToOperator[function];
    if (op == null || input is! Map<String, Object?>) return null;

    // For 'index', operands are in 'target'/'index'; for others, 'left'/'right'.
    final BallValue left;
    final BallValue right;
    if (function == 'index') {
      left = input['target'];
      right = input['index'];
    } else {
      left = input['left'];
      right = input['right'];
    }

    if (left is! Map<String, Object?> || !left.containsKey('__type__')) {
      return null;
    }

    final typeName = left['__type__'] as String;
    final colonIdx = typeName.indexOf(':');
    final modPart =
        colonIdx >= 0 ? typeName.substring(0, colonIdx) : _currentModule;

    // Walk the type hierarchy (self, then __super__ chain) looking for the
    // operator method, mirroring normal method dispatch.
    Map<String, Object?>? current = left;
    while (current != null) {
      final curType = current['__type__'] as String?;
      if (curType != null) {
        final cColonIdx = curType.indexOf(':');
        final cModPart =
            cColonIdx >= 0 ? curType.substring(0, cColonIdx) : modPart;
        final cTypeName =
            cColonIdx >= 0 ? curType : '$cModPart:$curType';
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
      final super_ = current['__super__'];
      current = super_ is Map<String, Object?> ? super_ : null;
    }

    return null;
  }

  /// Dispatch a static method call on a built-in class (List, Map, Set).
  /// Returns [_sentinel] if not handled.
  Future<BallValue> _dispatchBuiltinClassMethod(
    String className, String method, Map<String, Object?> args,
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
        if (source is List) return source.toList();
        if (source is Set) return source.toList();
        if (source is Iterable) return source.toList();
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

  Future<BallValue> _callBaseFunction(String module, String function, BallValue input) async {
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
  Map<String, FutureOr<BallValue> Function(BallValue)> _buildStdDispatch() {
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
        final m = i is Map<String, Object?> ? i : <String, Object?>{'value': i};
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
        if (i is Map<String, Object?>) {
          final parts = i['parts'];
          if (parts is List) {
            return parts.map((p) => _ballToString(p)).join();
          }
          final value = i['value'];
          if (value != null) return _ballToString(value);
        }
        return _ballToString(i);
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
        if (i is Map<String, Object?>) return i['callback'] ?? i['method'];
        return i;
      },
      'dart_list_generate': (i) async {
        final m = i as Map<String, Object?>;
        final count = _toInt(m['count']);
        final gen = m['generator'] as Function;
        final result = <Object?>[];
        for (var idx = 0; idx < count; idx++) {
          var v = gen(idx);
          if (v is Future) v = await v;
          result.add(v);
        }
        return result;
      },
      'dart_list_filled': (i) {
        final m = i as Map<String, Object?>;
        final count = _toInt(m['count']);
        final value = m['value'];
        return List.filled(count, value);
      },

      // Collections
      'map_create': _stdMapCreate,
      'set_create': _stdSetCreate,
      'record': _stdRecord,
      'collection_if': (_) => null,
      'collection_for': (_) => null,

      // std_collections — list operations
      'list_push': (i) {
        final m = i as Map<String, Object?>;
        final raw = m['list'];
        final list = raw is List ? raw : (raw is Set ? raw.toList() : <Object?>[]);
        list.add(m['value']);
        return list;
      },
      'list_pop': (i) {
        final list = (i as Map<String, Object?>)['list'] as List;
        if (list.isEmpty) throw BallRuntimeError('pop on empty list');
        return list.removeLast();
      },
      'list_insert': (i) {
        final m = i as Map<String, Object?>;
        final list = (m['list'] as List).toList();
        list.insert(_toInt(m['index']), m['value']);
        return list;
      },
      'list_remove_at': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        return list.removeAt(_toInt(m['index']));
      },
      'list_get': (i) {
        final m = i as Map<String, Object?>;
        return (m['list'] as List)[_toInt(m['index'])];
      },
      'list_set': (i) {
        final m = i as Map<String, Object?>;
        final list = (m['list'] as List).toList();
        list[_toInt(m['index'])] = m['value'];
        return list;
      },
      'list_length': (i) =>
          ((i as Map<String, Object?>)['list'] as List).length,
      'list_is_empty': (i) =>
          ((i as Map<String, Object?>)['list'] as List).isEmpty,
      'list_first': (i) => ((i as Map<String, Object?>)['list'] as List).first,
      'list_last': (i) => ((i as Map<String, Object?>)['list'] as List).last,
      'list_single': (i) =>
          ((i as Map<String, Object?>)['list'] as List).single,
      'list_contains': (i) {
        final m = i as Map<String, Object?>;
        final collection = m['list'];
        if (collection is String) return collection.contains(m['value'].toString());
        if (collection is List) return collection.contains(m['value']);
        if (collection is Set) return collection.contains(m['value']);
        return false;
      },
      'list_index_of': (i) {
        final m = i as Map<String, Object?>;
        return (m['list'] as List).indexOf(m['value']);
      },
      'list_map': (i) async {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        final result = <Object?>[];
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          result.add(v);
        }
        return result;
      },
      'list_filter': (i) async {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        final result = <Object?>[];
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v == true) result.add(e);
        }
        return result;
      },
      'list_reduce': (i) async {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
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
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v == true) return e;
        }
        throw StateError('No element');
      },
      'list_any': (i) async {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v == true) return true;
        }
        return false;
      },
      'list_all': (i) async {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v != true) return false;
        }
        return true;
      },
      'list_none': (i) async {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        for (final e in list) {
          var v = cb(e);
          if (v is Future) v = await v;
          if (v == true) return false;
        }
        return true;
      },
      'list_sort': (i) async {
        final m = i as Map<String, Object?>;
        final sorted = (m['list'] as List).toList();
        final cb = m['callback'] ?? m['comparator'] ?? m['compare'] ?? m['value'];
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
            var r = (cb as Function)(<String, Object?>{'left': sorted[k], 'right': key, 'arg0': sorted[k], 'arg1': key, 'a': sorted[k], 'b': key});
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
        final m = i as Map<String, Object?>;
        final list = (m['list'] as List).toList();
        final cb = m['callback'];
        // Pre-compute keys with await support.
        final keys = <Comparable>[];
        for (final e in list) {
          var k = (cb as Function)(e);
          if (k is Future) k = await k;
          keys.add(k as Comparable);
        }
        // Build index list and sort by keys.
        final indices = List.generate(list.length, (i) => i);
        indices.sort((a, b) => keys[a].compareTo(keys[b]));
        return [for (final idx in indices) list[idx]];
      },
      'list_reverse': (i) =>
          ((i as Map<String, Object?>)['list'] as List).reversed.toList(),
      'list_slice': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
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
        return list.sublist(s, e ?? list.length);
      },
      'list_flat_map': (i) async {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = (m['callback'] ?? m['function'] ?? m['value']) as Function;
        final result = <Object?>[];
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
        final m = i as Map<String, Object?>;
        final a = m['list'] as List;
        final b = m['value'] as List;
        final len = a.length < b.length ? a.length : b.length;
        return List.generate(len, (j) => [a[j], b[j]]);
      },
      'list_take': (i) {
        final m = i as Map<String, Object?>;
        return (m['list'] as List)
            .take(_toInt(m['value'] ?? m['index']))
            .toList();
      },
      'list_drop': (i) {
        final m = i as Map<String, Object?>;
        return (m['list'] as List)
            .skip(_toInt(m['value'] ?? m['index']))
            .toList();
      },
      'list_concat': (i) {
        final m = i as Map<String, Object?>;
        return [...(m['list'] as List), ...(m['value'] as List)];
      },
      'list_clear': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'];
        if (list is List) {
          list.clear();
          return list;
        }
        return <Object?>[];
      },
      'list_to_list': (i) {
        final raw = (i as Map<String, Object?>)['list'];
        if (raw is List) return raw.toList();
        if (raw is Set) return raw.toList();
        return <Object?>[];
      },
      'list_foreach': (i) async {
        final m = i as Map<String, Object?>;
        final collection = m['list'];
        final fn = m['function'] ?? m['value'] ?? m['callback'];
        if (fn is Function) {
          if (collection is List) {
            for (final item in collection) {
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
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final sep = m['separator']?.toString() ?? ',';
        return list.map((e) => _ballToString(e)).join(sep);
      },

      // std_collections — map operations
      'map_get': (i) {
        final m = i as Map<String, Object?>;
        return (m['map'] as Map)[m['key']];
      },
      'map_set': (i) {
        final m = i as Map<String, Object?>;
        final map = m['map'] as Map;
        map[m['key']] = m['value'];
        return map;
      },
      'map_delete': (i) {
        final m = i as Map<String, Object?>;
        final map = m['map'] as Map;
        map.remove(m['key']);
        return map;
      },
      'map_contains_key': (i) {
        final m = i as Map<String, Object?>;
        final target = m['map'];
        if (target is Map) return target.containsKey(m['key']);
        if (target is Set) return target.contains(m['key']);
        throw BallRuntimeError('map_contains_key: expected Map or Set');
      },
      'map_contains_value': (i) {
        final m = i as Map<String, Object?>;
        return (m['map'] as Map).containsValue(m['value']);
      },
      'map_put_if_absent': (i) {
        final m = i as Map<String, Object?>;
        final map = m['map'] as Map;
        final key = m['key'] as String;
        if (!map.containsKey(key)) {
          final val = m['value'];
          map[key] = val is Function ? val() : val;
        }
        return map[key];
      },
      'map_keys': (i) =>
          ((i as Map<String, Object?>)['map'] as Map).keys.toList(),
      'map_values': (i) =>
          ((i as Map<String, Object?>)['map'] as Map).values.toList(),
      'map_entries': (i) => ((i as Map<String, Object?>)['map'] as Map).entries
          .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
          .toList(),
      'map_from_entries': (i) {
        final list = (i as Map<String, Object?>)['list'] as List;
        final result = <String, Object?>{};
        for (final e in list) {
          if (e is Map) {
            final k = e['key'] ?? e['arg0'];
            final v = e['value'] ?? e['arg1'];
            if (k != null) result[k.toString()] = v;
          }
        }
        return result;
      },
      'map_merge': (i) {
        final m = i as Map<String, Object?>;
        return <String, Object?>{
          ...(m['map'] as Map).cast<String, Object?>(),
          ...(m['value'] as Map).cast<String, Object?>(),
        };
      },
      'map_map': (i) async {
        final m = i as Map<String, Object?>;
        final map = m['map'] as Map;
        final cb = m['callback'];
        final result = <String, Object?>{};
        for (final entry in map.entries) {
          var r = (cb as Function)(<String, Object?>{
            'key': entry.key,
            'value': entry.value,
          });
          if (r is Future) r = await r;
          if (r is Map<String, Object?>) {
            result[r['key'] as String] = r['value'];
          } else {
            result[entry.key as String] = r;
          }
        }
        return result;
      },
      'map_filter': (i) async {
        final m = i as Map<String, Object?>;
        final map = m['map'] as Map;
        final cb = m['callback'];
        final result = <String, Object?>{};
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
      'map_is_empty': (i) =>
          ((i as Map<String, Object?>)['map'] as Map).isEmpty,
      'map_length': (i) => ((i as Map<String, Object?>)['map'] as Map).length,

      // std_collections — string join
      'string_join': (i) {
        final m = i as Map<String, Object?>;
        return (m['list'] as List)
            .map((e) => '$e')
            .join(m['separator'] as String? ?? '');
      },

      // std_collections — set operations
      'set_add': (i) {
        final m = i as Map<String, Object?>;
        final s = (m['set'] as Set).toSet();
        s.add(m['value']);
        return s;
      },
      'set_remove': (i) {
        final m = i as Map<String, Object?>;
        final s = (m['set'] as Set).toSet();
        s.remove(m['value']);
        return s;
      },
      'set_contains': (i) {
        final m = i as Map<String, Object?>;
        return (m['set'] as Set).contains(m['value']);
      },
      'set_union': (i) {
        final m = i as Map<String, Object?>;
        return (m['left'] as Set).union(m['right'] as Set);
      },
      'set_intersection': (i) {
        final m = i as Map<String, Object?>;
        return (m['left'] as Set).intersection(m['right'] as Set);
      },
      'set_difference': (i) {
        final m = i as Map<String, Object?>;
        return (m['left'] as Set).difference(m['right'] as Set);
      },
      'set_length': (i) => ((i as Map<String, Object?>)['set'] as Set).length,
      'set_is_empty': (i) =>
          ((i as Map<String, Object?>)['set'] as Set).isEmpty,
      'set_to_list': (i) =>
          ((i as Map<String, Object?>)['set'] as Set).toList(),

      // Switch expression
      'switch_expr': _stdSwitchExpr,

      // Exceptions
      'throw': (i) {
        final val = _extractUnaryArg(i);
        String typeName = 'Exception';
        if (val is Map<String, Object?>) {
          typeName = (val['__type__'] as String?) ??
              (val['__type'] as String?) ?? 'Exception';
          // Ensure 'message' field exists for standard exception types.
          // The encoder stores the message as arg0; Dart code accesses e.message.
          if (!val.containsKey('message') && val.containsKey('arg0')) {
            val['message'] = val['arg0'];
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
        // Unwrap BallFuture (legacy synchronous simulation).
        if (val is BallFuture) return val.value;
        return val;
      },
      'yield': (i) {
        final val = _extractUnaryArg(i);
        // In generator context, the caller collects yields via _FlowSignal.
        // Outside generator context, just return the value.
        return val;
      },
      'yield_each': (i) {
        final val = _extractUnaryArg(i);
        // Flatten iterable yields.
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
        if (i is Map<String, Object?>) {
          final str = (i['string'] ?? i['value'] ?? i['left'] ?? '') as String;
          final delim = (i['delimiter'] ?? i['separator'] ?? i['right'] ?? '') as String;
          return str.split(delim);
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
        final msg = i is Map<String, Object?>
            ? i['message']?.toString() ?? ''
            : '$i';
        stderr(msg);
        return null;
      },
      'read_line': (_) => stdinReader?.call() ?? '',
      'exit': (i) {
        final code = i is Map<String, Object?> ? (i['code'] as int?) ?? 0 : 0;
        throw _ExitSignal(code);
      },
      'panic': (i) {
        final msg = i is Map<String, Object?>
            ? i['message']?.toString() ?? ''
            : '$i';
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
        final m = i as Map<String, Object?>;
        final min = (m['min'] as num?)?.toInt() ?? 0;
        final max = (m['max'] as num?)?.toInt() ?? 100;
        return min + _random.nextInt(max - min + 1);
      },
      'random_double': (_) => _random.nextDouble(),
      'env_get': (i) {
        final name = i is Map<String, Object?>
            ? i['name'] as String? ?? ''
            : '$i';
        return _envGet(name);
      },
      'args_get': (_) => _args,

      // ── std_convert ────────────────────────────────────────────
      'json_encode': (i) {
        final val = i is Map<String, Object?> ? i['value'] : i;
        return _jsonEncode(val);
      },
      'json_decode': (i) {
        final str = i is Map<String, Object?>
            ? i['value'] as String? ?? ''
            : '$i';
        return _jsonDecode(str);
      },
      'utf8_encode': (i) {
        final str = i is Map<String, Object?>
            ? i['value'] as String? ?? ''
            : '$i';
        return _utf8Encode(str);
      },
      'utf8_decode': (i) {
        final bytes = i is Map<String, Object?>
            ? i['value'] as List<int>? ?? []
            : <int>[];
        return _utf8Decode(bytes);
      },
      'base64_encode': (i) {
        final bytes = i is Map<String, Object?>
            ? i['value'] as List<int>? ?? []
            : <int>[];
        return _base64Encode(bytes);
      },
      'base64_decode': (i) {
        final str = i is Map<String, Object?>
            ? i['value'] as String? ?? ''
            : '$i';
        return _base64Decode(str);
      },

      // ── std_time ───────────────────────────────────────────────
      'now': (_) => DateTime.now().millisecondsSinceEpoch,
      'now_micros': (_) => DateTime.now().microsecondsSinceEpoch,
      'format_timestamp': (i) {
        final m = i as Map<String, Object?>;
        final ms = (m['timestamp_ms'] as num?)?.toInt() ?? 0;
        final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
        return dt.toIso8601String();
      },
      'parse_timestamp': (i) {
        final m = i as Map<String, Object?>;
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
        final m = i as Map<String, Object?>;
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
        final m = i as Map<String, Object?>;
        final body = m['body'];
        if (body is Function) {
          var v = body(null);
          if (v is Future) v = await v;
          return v;
        }
        return null;
      },
      'atomic_load': (i) {
        final m = i as Map<String, Object?>;
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
        if (i is Map<String, Object?>) return i['value'];
        return i;
      },
      'cpp_forward': (i) {
        if (i is Map<String, Object?>) return i['value'];
        return i;
      },
      'cpp_make_unique': (i) => i,
      'cpp_make_shared': (i) => i,
      'cpp_unique_ptr_get': (i) {
        if (i is Map<String, Object?>) return i['value'];
        return i;
      },
      'cpp_shared_ptr_get': (i) {
        if (i is Map<String, Object?>) return i['value'];
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
        if (i is Map<String, Object?>) return i['value'];
        return i;
      },
      'arrow': (i) {
        if (i is Map<String, Object?>) {
          final target = i['target'];
          final field = i['field'];
          if (target is Map<String, Object?> && field is String) {
            return target[field];
          }
        }
        return null;
      },
      'deref': (i) {
        if (i is Map<String, Object?>) return i['value'];
        return i;
      },
      'address_of': (i) => i,
      'init_list': (i) => i,
      'nullptr': (_) => null,
      'cpp_ifdef': (i) {
        // Runtime: just evaluate 'then' side (no compile-time symbols in engine)
        if (i is Map<String, Object?>) return i['then_body'];
        return null;
      },
      'cpp_defined': (_) => false,
      'goto': (i) {
        if (i is Map<String, Object?>) {
          final label = i['label'] as String? ?? '';
          throw _FlowSignal('goto', label: label);
        }
        return null;
      },
      'label': (i) {
        if (i is Map<String, Object?>) return i['body'];
        return null;
      },
    };
  }

  // ---- std function implementations ----

  /// Convert a Ball value to its string representation.
  ///
  /// For typed objects with a user-defined `toString` method, invokes that
  /// method. For StringBuffer objects, returns the buffer contents.
  /// Falls back to Dart's native `toString()`.
  String _ballToString(BallValue v) {
    if (v == null) return 'null';
    if (v is String) return v;
    if (v is bool) return v.toString();
    if (v is int) return v.toString();
    if (v is double) return v.toString();
    if (v is List) return '[${v.map(_ballToString).join(', ')}]';
    if (v is Map<String, Object?>) {
      // StringBuffer: return the buffer contents.
      final typeName = v['__type__'] as String?;
      if (typeName != null && (typeName.endsWith(':StringBuffer') || typeName == 'StringBuffer')) {
        return (v['__buffer__'] as String?) ?? '';
      }
      // Typed object: try to invoke the user's toString method.
      if (typeName != null) {
        final resolved = _resolveMethod(typeName, 'toString');
        if (resolved != null) {
          try {
            final future = _callFunction(resolved.module, resolved.func, <String, Object?>{'self': v});
            // _callFunction returns Future<BallValue>. Most calls complete
            // synchronously (Dart optimises already-completed Futures).
            // Use .then to grab the value if already resolved.
            BallValue syncResult;
            var done = false;
            future.then((r) { syncResult = r; done = true; });
            if (done) return syncResult?.toString() ?? 'null';
            // If truly async, fall back to default representation.
            return v.toString();
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
    final modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : _currentModule;

    // Try "module.typeName.methodName" in _functions.
    final methodKey = '$modPart.$typeName.$methodName';
    final method = _functions[methodKey];
    if (method != null && !method.isBase) {
      return (module: modPart, func: method);
    }

    // Walk superclass chain via _findTypeDef.
    final typeDef = _findTypeDef(typeName);
    if (typeDef != null && typeDef.superclass != null && typeDef.superclass!.isNotEmpty) {
      final superclass = typeDef.superclass!;
      final qualSuper = superclass.contains(':') ? superclass : '$modPart:$superclass';
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

  FutureOr<BallValue> _stdPrint(BallValue input) async {
    if (input is Map<String, Object?>) {
      final message = input['message'];
      if (message != null) {
        stdout(await _ballToStringAsync(message));
        return null;
      }
    }
    stdout(await _ballToStringAsync(input));
    return null;
  }

  /// Async version of [_ballToString] that can await method calls.
  Future<String> _ballToStringAsync(BallValue v) async {
    if (v == null) return 'null';
    if (v is String) return v;
    if (v is bool) return v.toString();
    if (v is int) return v.toString();
    if (v is double) return v.toString();
    if (v is List) {
      final parts = <String>[];
      for (final item in v) {
        parts.add(await _ballToStringAsync(item));
      }
      return '[${parts.join(', ')}]';
    }
    if (v is Map<String, Object?>) {
      final typeName = v['__type__'] as String?;
      if (typeName != null && (typeName.endsWith(':StringBuffer') || typeName == 'StringBuffer')) {
        return (v['__buffer__'] as String?) ?? '';
      }
      if (typeName != null) {
        final resolved = _resolveMethod(typeName, 'toString');
        if (resolved != null) {
          try {
            final result = await _callFunction(resolved.module, resolved.func, <String, Object?>{'self': v});
            return result?.toString() ?? 'null';
          } catch (_) {
            // Fall back on error.
          }
        }
      }
    }
    return v.toString();
  }

  BallValue _stdIf(BallValue input) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('std.if input must be a message');
    }
    final condition = input['condition'];
    if (condition == true) return input['then'];
    return input['else'];
  }

  BallValue _stdIndex(BallValue input) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('std.index: expected message');
    }
    final target = input['target'];
    final index = input['index'];
    if (target is List) return target[_toInt(index)];
    if (target is Map) return target[index is int ? index : (index is String ? index : index.toString())];
    if (target is String) return target[_toInt(index)];
    throw BallRuntimeError('std.index: unsupported types');
  }

  BallValue _stdCascade(BallValue input) {
    if (input is! Map<String, Object?>) return input;
    return input['target'];
  }

  BallValue _stdNullAwareCascade(BallValue input) {
    if (input is! Map<String, Object?>) return input;
    final target = input['target'];
    if (target == null) return null;
    return target;
  }

  FutureOr<BallValue> _stdInvoke(BallValue input) async {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('std.invoke: expected message');
    }
    final callee = input['callee'];
    if (callee is! Function) {
      throw BallRuntimeError('std.invoke: callee is not callable');
    }
    // Strip metadata keys to get the actual arguments.
    final args = Map<String, Object?>.from(input)
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

  BallValue _stdNullAwareAccess(BallValue input) {
    if (input is! Map<String, Object?>) return null;
    final target = input['target'];
    final field = input['field'] as String?;
    if (target == null) return null;
    if (target is Map<String, Object?> && field != null) {
      return target[field];
    }
    return null;
  }

  BallValue _stdNullAwareCall(BallValue input) {
    if (input is! Map<String, Object?>) return null;
    final target = input['target'];
    if (target == null) return null;
    // In the interpreter, method calls are resolved through function lookup
    return null;
  }

  BallValue _stdTypeCheck(BallValue input) {
    if (input is! Map<String, Object?>) return false;
    final value = input['value'];
    final type = input['type'] as String?;
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

      if (baseType == 'List' && value is List) {
        if (typeArgs.length == 1) {
          return value.every((e) => _typeMatches(e, typeArgs[0]));
        }
        return true;
      }
      if (baseType == 'Map' && value is Map) {
        if (typeArgs.length == 2) {
          return value.entries.every(
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
      if (value is Map<String, Object?> && _typeNameMatches(value['__type__'] as String?, baseType)) {
        final objArgs = value['__type_args__'];
        if (objArgs is List && objArgs.length == typeArgs.length) {
          for (var i = 0; i < typeArgs.length; i++) {
            if (objArgs[i] != typeArgs[i]) return false;
          }
          return true;
        }
      }
      return false;
    }

    // Simple types
    return switch (type) {
      'int' => value is int,
      'double' => value is double,
      'num' => value is num,
      'String' => value is String,
      'bool' => value is bool,
      'List' => value is List,
      'Map' => value is Map,
      'Set' => value is Set,
      'Null' || 'void' => value == null,
      'Object' || 'dynamic' => true,
      'Function' => value is Function,
      _ => _objectTypeMatches(value, type),
    };
  }

  bool _objectTypeMatches(Object? value, String type) {
    if (value is! Map<String, Object?>) return false;
    if (_typeNameMatches(value['__type__'] as String?, type)) return true;
    // Walk __super__ chain
    var superObj = value['__super__'];
    while (superObj is Map<String, Object?>) {
      if (_typeNameMatches(superObj['__type__'] as String?, type)) return true;
      superObj = superObj['__super__'];
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
      return objType.substring(objColon + 1) == checkType.substring(checkColon + 1);
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

  BallValue _stdMapCreate(BallValue input) {
    if (input is! Map<String, Object?>) return <String, Object?>{};
    // Support both 'entries' (list of {name, value}) and 'entry' (single or
    // list of {key, value}) formats.
    final entries = input['entries'] ?? input['entry'];
    if (entries is List) {
      final result = <Object?, Object?>{};
      for (final entry in entries) {
        if (entry is Map<String, Object?>) {
          final key = entry['key'] ?? entry['name'];
          result[key] = entry['value'];
        }
      }
      return result;
    }
    if (entries is Map<String, Object?>) {
      // Single entry (not wrapped in a list).
      final key = entries['key'] ?? entries['name'];
      return <Object?, Object?>{key: entries['value']};
    }
    return <String, Object?>{};
  }

  BallValue _stdSetCreate(BallValue input) {
    if (input is! Map<String, Object?>) return <Object?>{};
    final elements = input['elements'];
    if (elements is List) return elements.toSet();
    return <Object?>{};
  }

  BallValue _stdRecord(BallValue input) {
    if (input is! Map<String, Object?>) return input;
    return input['fields'] ?? input;
  }

  FutureOr<BallValue> _stdSwitchExpr(BallValue input) async {
    if (input is! Map<String, Object?>) return null;
    final subject = input['subject'];
    final cases = input['cases'];
    if (cases is! List) return null;
    Object? defaultBody;
    for (final c in cases) {
      if (c is! Map<String, Object?>) continue;
      final pattern = c['pattern'];
      final body = c['body'];
      final guard = c['guard'];
      // Default / wildcard.
      if (pattern == null || pattern == '_') {
        defaultBody = body;
        continue;
      }
      // Try structured pattern matching first.
      final bindings = <String, Object?>{};
      if (_matchPattern(subject, pattern, bindings)) {
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
    return defaultBody;
  }

  /// Structured pattern matching supporting Dart 3 patterns.
  ///
  /// Returns `true` if [value] matches [pattern], and populates [bindings]
  /// with any destructured variable names.
  bool _matchPattern(
    BallValue value,
    Object? pattern,
    Map<String, Object?> bindings,
  ) {
    if (pattern == null || pattern == '_') return true; // wildcard
    if (pattern is String) return _matchStringPattern(value, pattern, bindings);
    if (pattern is Map<String, Object?>) {
      return _matchStructuredPattern(value, pattern, bindings);
    }
    // Direct value equality.
    return pattern == value || pattern.toString() == value?.toString();
  }

  /// Match a string pattern like 'int x', 'String s', '> 5', etc.
  bool _matchStringPattern(
    BallValue value,
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
    BallValue value,
    Map<String, Object?> pattern,
    Map<String, Object?> bindings,
  ) {
    final kind = pattern['__pattern_kind__'] as String?;
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

      case 'list':
        // { __pattern_kind__: 'list', elements: [...patterns], rest: 'restVar' }
        if (value is! List) return false;
        final elements = pattern['elements'] as List? ?? [];
        final rest = pattern['rest'] as String?;
        if (rest == null && value.length != elements.length) return false;
        if (rest != null && value.length < elements.length) return false;
        for (var i = 0; i < elements.length; i++) {
          if (!_matchPattern(value[i], elements[i], bindings)) return false;
        }
        if (rest != null) {
          bindings[rest] = value.sublist(elements.length);
        }
        return true;

      case 'object':
        // { __pattern_kind__: 'object', type: 'Point', fields: {x: patX, y: patY} }
        if (value is! Map<String, Object?>) return false;
        final objType = pattern['type'] as String?;
        if (objType != null && value['__type__'] != objType) return false;
        final fieldPatterns = pattern['fields'] as Map<String, Object?>?;
        if (fieldPatterns != null) {
          for (final entry in fieldPatterns.entries) {
            final fieldVal = value[entry.key];
            if (!_matchPattern(fieldVal, entry.value, bindings)) return false;
          }
        }
        return true;

      case 'record':
        // { __pattern_kind__: 'record', fields: {named_field: pattern, $1: pattern} }
        if (value is! Map<String, Object?>) return false;
        final fieldPatterns = pattern['fields'] as Map<String, Object?>?;
        if (fieldPatterns != null) {
          for (final entry in fieldPatterns.entries) {
            final fieldVal = value[entry.key];
            if (!_matchPattern(fieldVal, entry.value, bindings)) return false;
          }
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
        final varName = pattern['name'] as String?;
        if (varName != null) bindings[varName] = value;
        return true;

      default:
        // No special kind — try value equality on each field.
        if (value is Map<String, Object?>) {
          for (final entry in pattern.entries) {
            if (entry.key.startsWith('__')) continue;
            if (!_matchPattern(value[entry.key], entry.value, bindings)) {
              return false;
            }
          }
          return true;
        }
        return false;
    }
  }

  /// Returns true if [value] matches the type-name pattern string.
  /// Enables switch expressions with type arms like `case int: ...`.
  bool _matchesTypePattern(BallValue value, String pattern) {
    return switch (pattern) {
      'int' => value is int,
      'double' => value is double,
      'num' => value is num,
      'String' => value is String,
      'bool' => value is bool,
      'List' => value is List,
      'Map' => value is Map,
      'Set' => value is Set,
      'Null' || 'null' => value == null,
      _ => false,
    };
  }

  BallValue _stdAssert(BallValue input) {
    if (input is! Map<String, Object?>) return null;
    final condition = input['condition'];
    final message = input['message'];
    if (!_toBool(condition)) {
      throw BallRuntimeError(
        'Assertion failed${message != null ? ": $message" : ""}',
      );
    }
    return null;
  }

  // ---- Arithmetic helpers ----

  /// `std.add` — numeric addition or string concatenation.
  BallValue _stdAdd(BallValue input) {
    final (left, right) = _extractBinaryArgs(input);
    if (left is String || right is String) {
      return '${left ?? ''}${right ?? ''}';
    }
    return _toNum(left) + _toNum(right);
  }

  BallValue _stdBinary(BallValue input, num Function(num, num) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toNum(left), _toNum(right));
  }

  BallValue _stdBinaryInt(BallValue input, int Function(int, int) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toInt(left), _toInt(right));
  }

  BallValue _stdBinaryDouble(
    BallValue input,
    double Function(double, double) op,
  ) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toDouble(left), _toDouble(right));
  }

  BallValue _stdBinaryComp(BallValue input, bool Function(num, num) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toNum(left), _toNum(right));
  }

  BallValue _stdBinaryBool(BallValue input, bool Function(bool, bool) op) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toBool(left), _toBool(right));
  }

  BallValue _stdBinaryAny(
    BallValue input,
    Object? Function(Object?, Object?) op,
  ) {
    final (left, right) = _extractBinaryArgs(input);
    return op(left, right);
  }

  BallValue _stdUnaryNum(BallValue input, num Function(num) op) {
    final value = _extractUnaryArg(input);
    return op(_toNum(value));
  }

  BallValue _stdNot(BallValue input) {
    final value = _extractUnaryArg(input);
    return !_toBool(value);
  }

  BallValue _stdConcat(BallValue input) {
    final (left, right) = _extractBinaryArgs(input);
    return '$left$right';
  }

  BallValue _stdLength(BallValue input) {
    final value = _extractUnaryArg(input);
    if (value is String) return value.length;
    if (value is List) return value.length;
    throw BallRuntimeError('std.length: unsupported type ${value.runtimeType}');
  }

  BallValue _stdConvert(BallValue input, Object? Function(Object?) converter) {
    final value = _extractUnaryArg(input);
    return converter(value);
  }

  // ---- Value extraction helpers ----

  (BallValue, BallValue) _extractBinaryArgs(BallValue input) {
    if (input is Map<String, Object?>) {
      return (input['left'], input['right']);
    }
    throw BallRuntimeError('Expected message with left/right fields');
  }

  BallValue _extractUnaryArg(BallValue input) {
    if (input is Map<String, Object?>) return input['value'];
    return input;
  }

  BallValue _extractField(BallValue input, String name) {
    if (input is Map<String, Object?>) return input[name];
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

  int _toInt(BallValue v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    if (v is bool) return v ? 1 : 0;
    return 0;
  }

  double _toDouble(BallValue v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.parse(v);
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to double');
  }

  num _toNum(BallValue v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? 0;
    if (v is bool) return v ? 1 : 0;
    if (v == null) return 0;
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to num');
  }

  /// Convert a runtime value to an iterable list for for_in loops.
  /// Handles List, Set, Map (iterates entries as {key, value} maps), and String.
  List<Object?> _toIterable(BallValue v) {
    if (v is List) return v;
    if (v is Set) return v.toList();
    if (v is Map) {
      return v.entries
          .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
          .toList();
    }
    if (v is String) return v.split('');
    throw BallRuntimeError('for_in: value is not iterable (${v.runtimeType})');
  }

  bool _toBool(BallValue v) {
    if (v is bool) return v;
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to bool');
  }

  // ---- String helpers ----

  BallValue _stdStringSubstring(BallValue input) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('Expected message');
    }
    final value = input['value'] as String;
    final start = _toInt(input['start']);
    final end = input['end'];
    return end != null
        ? value.substring(start, _toInt(end))
        : value.substring(start);
  }

  BallValue _stdStringCharAt(BallValue input) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('Expected message');
    }
    final target = input['target'] as String;
    final index = _toInt(input['index']);
    return target[index];
  }

  BallValue _stdStringCharCodeAt(BallValue input) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('Expected message');
    }
    final target = (input['target'] ?? input['value'] ?? input['string']) as String;
    final index = _toInt(input['index']);
    return target.codeUnitAt(index);
  }

  BallValue _stdStringReplace(BallValue input, bool all) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('Expected message');
    }
    final value = input['value'] as String;
    final from = input['from'] as String;
    final to = input['to'] as String;
    return all ? value.replaceAll(from, to) : value.replaceFirst(from, to);
  }

  BallValue _stdRegexReplace(BallValue input, bool all) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('Expected message');
    }
    final value = input['value'] as String;
    final from = input['from'] as String;
    final to = input['to'] as String;
    final pattern = RegExp(from);
    return all
        ? value.replaceAll(pattern, to)
        : value.replaceFirst(pattern, to);
  }

  BallValue _stdStringRepeat(BallValue input) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('Expected message');
    }
    final value = input['value'] as String;
    final count = _toInt(input['count']);
    return value * count;
  }

  BallValue _stdStringPad(BallValue input, bool left) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('Expected message');
    }
    final value = input['value'] as String;
    final width = _toInt(input['width']);
    final padding = (input['padding'] as String?) ?? ' ';
    return left
        ? value.padLeft(width, padding)
        : value.padRight(width, padding);
  }

  // ---- Math helpers (using dart:math would need import, so inline) ----

  BallValue _stdMathUnary(BallValue input, double Function(double) op) {
    final value = _extractUnaryArg(input);
    return op(_toDouble(value));
  }

  BallValue _stdMathBinary(
    BallValue input,
    double Function(double, double) op,
  ) {
    final (left, right) = _extractBinaryArgs(input);
    return op(_toDouble(left), _toDouble(right));
  }

  BallValue _stdMathClamp(BallValue input) {
    if (input is! Map<String, Object?>) {
      throw BallRuntimeError('Expected message');
    }
    // Handle static method style: math_clamp({value: classRef, min: val, max: lo, arg2: hi})
    // where value is a class reference object, not a number.
    final rawValue = input['value'];
    num value;
    num min;
    num max;
    if (rawValue is Map<String, Object?>) {
      // Static method dispatch: shift args.
      value = _toNum(input['min']);
      min = _toNum(input['max']);
      max = _toNum(input['arg2']);
    } else {
      value = _toNum(rawValue);
      min = _toNum(input['min']);
      max = _toNum(input['max']);
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
    if (v == null || v is num || v is bool || v is String) return v;
    if (v is Map) {
      return {
        for (final e in v.entries)
          if (e.key is String && !(e.key as String).startsWith('__'))
            e.key: _toJsonSafe(e.value),
      };
    }
    if (v is List) return v.map(_toJsonSafe).toList();
    if (v is Set) return v.map(_toJsonSafe).toList();
    return v.toString();
  }

  List<int> _utf8Encode(String s) => utf8.encode(s);
  String _utf8Decode(List<int> bytes) => utf8.decode(bytes);
  String _base64Encode(List<int> bytes) => base64.encode(bytes);
  List<int> _base64Decode(String s) => base64.decode(s);

  // ---- std_fs helpers ----

  BallValue _stdFileRead(BallValue input) {
    final path = input is Map<String, Object?>
        ? input['path'] as String? ?? ''
        : '$input';
    return io.File(path).readAsStringSync();
  }

  BallValue _stdFileReadBytes(BallValue input) {
    final path = input is Map<String, Object?>
        ? input['path'] as String? ?? ''
        : '$input';
    return io.File(path).readAsBytesSync().toList();
  }

  BallValue _stdFileWrite(BallValue input) {
    final m = input as Map<String, Object?>;
    io.File(m['path'] as String).writeAsStringSync(m['content'] as String);
    return null;
  }

  BallValue _stdFileWriteBytes(BallValue input) {
    final m = input as Map<String, Object?>;
    io.File(m['path'] as String).writeAsBytesSync(m['content'] as List<int>);
    return null;
  }

  BallValue _stdFileAppend(BallValue input) {
    final m = input as Map<String, Object?>;
    io.File(
      m['path'] as String,
    ).writeAsStringSync(m['content'] as String, mode: io.FileMode.append);
    return null;
  }

  BallValue _stdFileExists(BallValue input) {
    final path = input is Map<String, Object?>
        ? input['path'] as String? ?? ''
        : '$input';
    return io.File(path).existsSync();
  }

  BallValue _stdFileDelete(BallValue input) {
    final path = input is Map<String, Object?>
        ? input['path'] as String? ?? ''
        : '$input';
    io.File(path).deleteSync();
    return null;
  }

  BallValue _stdDirList(BallValue input) {
    final path = input is Map<String, Object?>
        ? input['path'] as String? ?? ''
        : '$input';
    return io.Directory(path).listSync().map((e) => e.path).toList();
  }

  BallValue _stdDirCreate(BallValue input) {
    final path = input is Map<String, Object?>
        ? input['path'] as String? ?? ''
        : '$input';
    io.Directory(path).createSync(recursive: true);
    return null;
  }

  BallValue _stdDirExists(BallValue input) {
    final path = input is Map<String, Object?>
        ? input['path'] as String? ?? ''
        : '$input';
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
