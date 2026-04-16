/// Ball engine — interprets and executes ball programs at runtime.
///
/// The engine walks the expression tree and evaluates it directly,
/// without generating any intermediate source code.
///
/// Fully compliant with the ball.v1 proto schema.
/// Supports all 73 std base functions.
library;

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
    BallValue Function(String module, String function, BallValue input);

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
  BallValue call(String function, BallValue input, BallCallable engine);

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
  final Map<String, BallValue Function(BallValue)> _dispatch = {};

  /// Composition-aware dispatch table for closures that need [BallCallable].
  /// Checked before [_dispatch] so [registerComposer] can override built-ins.
  final Map<String, BallValue Function(BallValue, BallCallable)>
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
  void register(String function, BallValue Function(BallValue) handler) {
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
    BallValue Function(BallValue, BallCallable) handler,
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
  BallValue call(String function, BallValue input, BallCallable engine) {
    final composed = _composedDispatch[function];
    if (composed != null) return composed(input, engine);
    final handler = _dispatch[function];
    if (handler == null) {
      throw BallRuntimeError('Unknown std function: "$function"');
    }
    return handler(input);
  }
}

/// Executes ball programs directly at runtime.
class BallEngine {
  final Program program;

  /// Resolved type definitions by name.
  final Map<String, google.DescriptorProto> _types = {};

  /// Resolved functions by "module.function" key.
  final Map<String, FunctionDefinition> _functions = {};

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
    _initTopLevelVariables();
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
  BallValue callFunction(String module, String function, BallValue input) =>
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
      for (final func in module.functions) {
        final key = '${module.name}.${func.name}';
        _functions[key] = func;
        // Pre-cache parameter lists from metadata so _callFunction is
        // allocation-free on repeated calls (mirrors V8's constant pool).
        if (func.hasMetadata()) {
          final params = _extractParams(func.metadata);
          if (params.isNotEmpty) _paramCache[key] = params;
        }
      }
    }
  }

  /// Initialize top-level variables by evaluating their body expressions.
  void _initTopLevelVariables() {
    for (final module in program.modules) {
      if (module.name == 'std' || module.name == 'dart_std') continue;
      for (final func in module.functions) {
        if (!func.hasMetadata()) continue;
        final kindValue = func.metadata.fields['kind'];
        if (kindValue?.stringValue != 'top_level_variable') continue;
        _currentModule = module.name;
        final value = func.hasBody()
            ? _evalExpression(func.body, _globalScope)
            : null;
        _globalScope.bind(func.name, value);
      }
    }
  }

  /// Execute the program starting from the entry point.
  BallValue run() {
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

  BallValue _callFunction(
    String moduleName,
    FunctionDefinition func,
    BallValue input,
  ) {
    if (func.isBase) {
      return _callBaseFunction(moduleName, func.name, input);
    }
    if (!func.hasBody()) return null;

    final prevModule = _currentModule;
    _currentModule = moduleName;
    final scope = _Scope(_globalScope);

    // Bind parameters: use pre-built param cache for O(1) lookup.
    final params =
        _paramCache['$moduleName.${func.name}'] ??
        (func.hasMetadata() ? _extractParams(func.metadata) : const []);
    if (params.isNotEmpty) {
      if (params.length == 1) {
        // Single parameter — bind the input directly.
        scope.bind(params[0], input);
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

    if (func.inputType.isNotEmpty && input != null) {
      scope.bind('input', input);
    }
    final result = _evalExpression(func.body, scope);
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

  BallValue _resolveAndCallFunction(
    String module,
    String function,
    BallValue input,
  ) {
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

    // Lazy module loading: if a resolver is available, check whether any
    // module declares an import for the missing module and resolve it.
    if (_resolver != null) {
      final resolved = _tryLazyResolve(moduleName);
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

  Module? _tryLazyResolve(String moduleName) {
    for (final m in program.modules) {
      for (final import_ in m.moduleImports) {
        if (import_.name == moduleName && import_.whichSource() != ModuleImport_Source.notSet) {
          try {
            // Synchronous wait — acceptable for lazy loading since module
            // resolution is typically cached after first fetch.
            // ignore: discarded_futures
            final future = _resolver!.resolve(import_);
            // Use a zone-based sync wait if possible; fallback to blocking.
            Module? result;
            bool done = false;
            future.then((m) { result = m; done = true; });
            // If the future completed synchronously (cache hit), use it.
            if (done && result != null) return result;
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
      }
    }
  }

  // ============================================================
  // Expression Evaluation
  // ============================================================

  BallValue _evalExpression(Expression expr, _Scope scope) {
    return switch (expr.whichExpr()) {
      Expression_Expr.call => _evalCall(expr.call, scope),
      Expression_Expr.literal => _evalLiteral(expr.literal, scope),
      Expression_Expr.reference => _evalReference(expr.reference, scope),
      Expression_Expr.fieldAccess => _evalFieldAccess(expr.fieldAccess, scope),
      Expression_Expr.messageCreation => _evalMessageCreation(
        expr.messageCreation,
        scope,
      ),
      Expression_Expr.block => _evalBlock(expr.block, scope),
      Expression_Expr.lambda => _evalLambda(expr.lambda, scope),
      Expression_Expr.notSet => null,
    };
  }

  // ---- Function Calls ----

  BallValue _evalCall(FunctionCall call, _Scope scope) {
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
      }
    }

    // cpp_scope_exit must be lazy: register the cleanup expression without
    // evaluating it, then execute in LIFO order when the enclosing block exits.
    if (moduleName == 'cpp_std' && call.function == 'cpp_scope_exit') {
      return _evalCppScopeExit(call, scope);
    }

    // Eager evaluation for all other calls
    final input = call.hasInput() ? _evalExpression(call.input, scope) : null;

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
      if (bound is BallValue Function(BallValue)) {
        return bound(input);
      }
    }

    // Method call on object (has 'self' field)
    if (input is Map<String, Object?> && input.containsKey('self')) {
      // This is how the encoder represents method calls
      return _resolveAndCallFunction(call.module, call.function, input);
    }

    return _resolveAndCallFunction(call.module, call.function, input);
  }

  // ---- Literals ----

  BallValue _evalLiteral(Literal lit, _Scope scope) {
    return switch (lit.whichValue()) {
      Literal_Value.intValue => lit.intValue.toInt(),
      Literal_Value.doubleValue => lit.doubleValue,
      Literal_Value.stringValue => lit.stringValue,
      Literal_Value.boolValue => lit.boolValue,
      Literal_Value.bytesValue => lit.bytesValue.toList(),
      Literal_Value.listValue => _evalListLiteral(lit.listValue, scope),
      Literal_Value.notSet => null,
    };
  }

  /// Evaluates a list literal, handling collection_if and collection_for.
  List<Object?> _evalListLiteral(ListLiteral listVal, _Scope scope) {
    final result = <Object?>[];
    for (final element in listVal.elements) {
      if (element.hasCall()) {
        final call = element.call;
        final fn = call.function;
        if ((call.module == 'dart_std' || call.module == 'std') &&
            fn == 'collection_if') {
          _evalCollectionIf(call, scope, result);
          continue;
        }
        if ((call.module == 'dart_std' || call.module == 'std') &&
            fn == 'collection_for') {
          _evalCollectionFor(call, scope, result);
          continue;
        }
      }
      result.add(_evalExpression(element, scope));
    }
    return result;
  }

  /// Evaluates collection_if: if (condition) value [else elseValue]
  void _evalCollectionIf(
    FunctionCall call,
    _Scope scope,
    List<Object?> result,
  ) {
    final fields = _lazyFields(call);
    final condExpr = fields['condition'];
    if (condExpr == null) return;
    final cond = _toBool(_evalExpression(condExpr, scope));
    if (cond) {
      final thenExpr = fields['then'];
      if (thenExpr != null) {
        _addCollectionElement(thenExpr, scope, result);
      }
    } else {
      final elseExpr = fields['else'];
      if (elseExpr != null) {
        _addCollectionElement(elseExpr, scope, result);
      }
    }
  }

  /// Evaluates collection_for: for (var in iterable) body
  void _evalCollectionFor(
    FunctionCall call,
    _Scope scope,
    List<Object?> result,
  ) {
    final fields = _lazyFields(call);
    final variable = _stringFieldVal(fields, 'variable');
    final iterableExpr = fields['iterable'];
    final bodyExpr = fields['body'];
    if (iterableExpr == null || bodyExpr == null) return;
    final iterable = _evalExpression(iterableExpr, scope);
    if (iterable is! List) return;
    for (final item in iterable) {
      final loopScope = scope.child();
      loopScope.bind((variable ?? '').isEmpty ? 'item' : variable!, item);
      _addCollectionElement(bodyExpr, loopScope, result);
    }
  }

  /// Adds a collection element, recursively handling nested collection_if/for.
  void _addCollectionElement(
    Expression expr,
    _Scope scope,
    List<Object?> result,
  ) {
    if (expr.hasCall()) {
      final call = expr.call;
      final fn = call.function;
      if ((call.module == 'dart_std' || call.module == 'std') &&
          fn == 'collection_if') {
        _evalCollectionIf(call, scope, result);
        return;
      }
      if ((call.module == 'dart_std' || call.module == 'std') &&
          fn == 'collection_for') {
        _evalCollectionFor(call, scope, result);
        return;
      }
    }
    result.add(_evalExpression(expr, scope));
  }

  // ---- References ----

  BallValue _evalReference(Reference ref, _Scope scope) {
    return scope.lookup(ref.name);
  }

  // ---- Field Access ----

  BallValue _evalFieldAccess(FieldAccess access, _Scope scope) {
    final object = _evalExpression(access.object, scope);
    final fieldName = access.field_2;

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

  // ---- Message Creation ----

  BallValue _evalMessageCreation(MessageCreation msg, _Scope scope) {
    final fields = <String, Object?>{};
    for (final pair in msg.fields) {
      fields[pair.name] = _evalExpression(pair.value, scope);
    }
    if (msg.typeName.isNotEmpty) {
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
        final superclass = _getMetaString(typeDef, 'superclass');
        if (superclass != null && superclass.isNotEmpty) {
          // Build super object with inherited fields.
          final superFields = <String, Object?>{};
          superFields['__type__'] = superclass;
          // Copy fields that belong to the superclass into __super__.
          fields['__super__'] = superFields;
        }

        // Resolve methods from the type's module.
        final methods = _resolveTypeMethods(msg.typeName);
        if (methods.isNotEmpty) {
          fields['__methods__'] = methods;
        }
      }
    }
    return fields;
  }

  /// Find a TypeDefinition by name across all modules.
  ({String? superclass, Map<String, FunctionDefinition> methods})? _findTypeDef(
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
          return (
            superclass: superclass,
            methods: <String, FunctionDefinition>{},
          );
        }
      }
    }
    return null;
  }

  /// Get a string value from TypeDefinition metadata.
  String? _getMetaString(
    ({String? superclass, Map<String, FunctionDefinition> methods}) typeDef,
    String key,
  ) {
    if (key == 'superclass') return typeDef.superclass;
    return null;
  }

  /// Resolve methods associated with a type name from its module.
  Map<String, Function> _resolveTypeMethods(String typeName) {
    final methods = <String, Function>{};
    for (final module in program.modules) {
      for (final func in module.functions) {
        if (func.hasMetadata()) {
          final className = func.metadata.fields['class'];
          if (className != null &&
              className.hasStringValue() &&
              className.stringValue == typeName &&
              func.hasBody()) {
            methods[func.name] = (BallValue input) {
              return _callFunction(module.name, func, input);
            };
          }
        }
      }
    }
    return methods;
  }

  // ---- Block ----

  BallValue _evalBlock(Block block, _Scope scope) {
    final blockScope = scope.child();
    BallValue flowResult;
    for (final stmt in block.statements) {
      final result = _evalStatement(stmt, blockScope);
      if (result is _FlowSignal) {
        // Run scope-exits in LIFO order before propagating the signal.
        _runScopeExits(blockScope);
        return result;
      }
    }
    if (block.hasResult()) {
      flowResult = _evalExpression(block.result, blockScope);
    } else {
      flowResult = null;
    }
    // Run scope-exits in LIFO order (normal exit).
    _runScopeExits(blockScope);
    return flowResult;
  }

  /// Execute all registered scope-exit cleanups in LIFO order.
  void _runScopeExits(_Scope blockScope) {
    if (blockScope._scopeExits.isEmpty) return;
    for (final (expr, evalScope) in blockScope._scopeExits.reversed) {
      try {
        _evalExpression(expr, evalScope);
      } catch (_) {
        // Scope-exit cleanup errors are swallowed (RAII destructor semantics).
      }
    }
  }

  BallValue _evalStatement(Statement stmt, _Scope scope) {
    switch (stmt.whichStmt()) {
      case Statement_Stmt.let:
        final value = _evalExpression(stmt.let.value, scope);
        if (value is _FlowSignal) return value;
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
    return (BallValue input) {
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
      }
      if (!func.hasBody()) return null;
      final result = _evalExpression(func.body, lambdaScope);
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

  BallValue _evalLazyIf(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final condition = fields['condition'];
    final thenBranch = fields['then'];
    final elseBranch = fields['else'];
    if (condition == null || thenBranch == null) {
      throw BallRuntimeError('std.if missing condition or then');
    }
    final condVal = _evalExpression(condition, scope);
    if (_toBool(condVal)) {
      return _evalExpression(thenBranch, scope);
    } else if (elseBranch != null) {
      return _evalExpression(elseBranch, scope);
    }
    return null;
  }

  BallValue _evalLazyFor(FunctionCall call, _Scope scope) {
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
          _evalStatement(stmt, forScope);
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
        _evalExpression(initExpr, forScope);
      }
    }

    while (true) {
      if (condition != null) {
        final condVal = _evalExpression(condition, forScope);
        if (!_toBool(condVal)) break;
      }
      if (body != null) {
        final result = _evalExpression(body, forScope);
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
      if (update != null) _evalExpression(update, forScope);
    }
    return null;
  }

  BallValue _evalLazyForIn(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final variable = _stringFieldVal(fields, 'variable') ?? 'item';
    final iterable = fields['iterable'];
    final body = fields['body'];
    if (iterable == null || body == null) return null;

    final iterVal = _evalExpression(iterable, scope);
    if (iterVal is! List) {
      throw BallRuntimeError('std.for_in: iterable is not a List');
    }
    for (final item in iterVal) {
      final loopScope = scope.child();
      loopScope.bind(variable, item);
      final result = _evalExpression(body, loopScope);
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

  BallValue _evalLazyWhile(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final condition = fields['condition'];
    final body = fields['body'];
    while (true) {
      if (condition != null) {
        final condVal = _evalExpression(condition, scope);
        if (!_toBool(condVal)) break;
      }
      if (body != null) {
        final result = _evalExpression(body, scope);
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

  BallValue _evalLazyDoWhile(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final body = fields['body'];
    final condition = fields['condition'];
    do {
      if (body != null) {
        final result = _evalExpression(body, scope);
        if (result is _FlowSignal) {
          if (result.kind == 'return') return result;
          if (result.label != null && result.label!.isNotEmpty) {
            return result;
          }
          if (result.kind == 'break') break;
        }
      }
      if (condition != null) {
        final condVal = _evalExpression(condition, scope);
        if (!_toBool(condVal)) break;
      } else {
        break;
      }
    } while (true);
    return null;
  }

  BallValue _evalLazySwitch(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final subject = fields['subject'];
    final cases = fields['cases'];
    if (subject == null || cases == null) return null;

    final subjectVal = _evalExpression(subject, scope);
    if (cases.whichExpr() != Expression_Expr.literal ||
        cases.literal.whichValue() != Literal_Value.listValue) {
      return null;
    }
    Expression? defaultBody;
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
      final value = cf['value'];
      if (value != null) {
        final caseVal = _evalExpression(value, scope);
        if (caseVal == subjectVal) {
          final body = cf['body'];
          if (body != null) return _evalExpression(body, scope);
        }
      }
    }
    if (defaultBody != null) {
      return _evalExpression(defaultBody, scope);
    }
    return null;
  }

  BallValue _evalLazyTry(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final body = fields['body'];
    final catches = fields['catches'];
    final finallyBlock = fields['finally'];

    BallValue result;
    try {
      result = body != null ? _evalExpression(body, scope) : null;
    } catch (e) {
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
            final matches = e is BallException
                ? e.typeName == catchType
                : e.runtimeType.toString() == catchType;
            if (!matches) continue;
          }
          final variable = _stringFieldVal(cf, 'variable') ?? 'e';
          final catchBody = cf['body'];
          if (catchBody != null) {
            final catchScope = scope.child();
            // Bind original thrown value for BallException (so catch
            // bodies can read field data); fall back to string form for
            // real Dart runtime errors.
            catchScope.bind(variable, e is BallException ? e.value : e.toString());
            // Save/restore the active exception so `rethrow` re-raises
            // the original error and nested tries unwind cleanly.
            final previousActive = _activeException;
            _activeException = e;
            try {
              result = _evalExpression(catchBody, catchScope);
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
        _evalExpression(finallyBlock, scope);
      }
    }
    return result;
  }

  BallValue _evalShortCircuitAnd(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final left = fields['left'];
    final right = fields['right'];
    if (left == null || right == null) return false;
    final leftVal = _evalExpression(left, scope);
    if (!_toBool(leftVal)) return false;
    return _toBool(_evalExpression(right, scope));
  }

  BallValue _evalShortCircuitOr(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final left = fields['left'];
    final right = fields['right'];
    if (left == null || right == null) return false;
    final leftVal = _evalExpression(left, scope);
    if (_toBool(leftVal)) return true;
    return _toBool(_evalExpression(right, scope));
  }

  BallValue _evalReturn(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final value = fields['value'];
    final val = value != null ? _evalExpression(value, scope) : null;
    return _FlowSignal('return', value: val);
  }

  BallValue _evalBreak(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    return _FlowSignal('break', label: label);
  }

  BallValue _evalContinue(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    return _FlowSignal('continue', label: label);
  }

  BallValue _evalAssign(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final target = fields['target'];
    final value = fields['value'];
    if (target == null || value == null) return null;

    final val = _evalExpression(value, scope);
    final op = _stringFieldVal(fields, 'op');

    // Simple reference assignment
    if (target.whichExpr() == Expression_Expr.reference) {
      final name = target.reference.name;
      if (op != null && op.isNotEmpty && op != '=') {
        final current = scope.lookup(name);
        final computed = _applyCompoundOp(op, current, val);
        scope.set(name, computed);
        return computed;
      }
      scope.set(name, val);
      return val;
    }

    // Field access assignment (obj.field = val)
    if (target.whichExpr() == Expression_Expr.fieldAccess) {
      final obj = _evalExpression(target.fieldAccess.object, scope);
      if (obj is Map<String, Object?>) {
        obj[target.fieldAccess.field_2] = val;
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
        final list = _evalExpression(indexTarget, scope);
        final idx = _evalExpression(indexExpr, scope);
        if (list is List && idx is int) {
          list[idx] = val;
          return val;
        }
        if (list is Map<String, Object?> && idx is String) {
          list[idx] = val;
          return val;
        }
      }
    }

    return val;
  }

  /// Handle ++/-- as lazy scope-mutating operations.
  BallValue _evalIncDec(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final valueExpr = fields['value'];
    if (valueExpr == null) return null;

    // Must be a reference so we can update the variable in scope.
    if (valueExpr.whichExpr() == Expression_Expr.reference) {
      final name = valueExpr.reference.name;
      final current = scope.lookup(name) as num;
      final isInc = call.function.contains('increment');
      final isPre = call.function.startsWith('pre');
      final updated = isInc ? current + 1 : current - 1;
      scope.set(name, updated);
      return isPre ? updated : current;
    }

    // Fallback: just compute
    final val = _evalExpression(valueExpr, scope) as num;
    final isInc = call.function.contains('increment');
    return isInc ? val + 1 : val - 1;
  }

  BallValue _applyCompoundOp(String op, BallValue current, BallValue val) {
    return switch (op) {
      '+=' => _numOp(current, val, (a, b) => a + b),
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

  BallValue _evalLabeled(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    final body = fields['body'];
    if (body == null) return null;
    final result = _evalExpression(body, scope);
    if (result is _FlowSignal &&
        (result.kind == 'break' || result.kind == 'continue') &&
        result.label == label) {
      return null; // consumed
    }
    return result;
  }

  BallValue _evalGoto(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'label');
    throw _FlowSignal('goto', label: label);
  }

  BallValue _evalLabel(FunctionCall call, _Scope scope) {
    final fields = _lazyFields(call);
    final label = _stringFieldVal(fields, 'name');
    final body = fields['body'];
    if (body == null) return null;
    // Execute the body; if a goto signal targeting THIS label arrives,
    // re-execute the body (backward goto). For forward gotos, the signal
    // propagates up until the matching label handler catches it.
    BallValue result;
    do {
      result = _evalExpression(body, scope);
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
  BallValue _evalAwaitFor(FunctionCall call, _Scope scope) {
    // Reuse for_in logic — single-threaded simulation.
    return _evalLazyForIn(call, scope);
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

  BallValue _callBaseFunction(String module, String function, BallValue input) {
    for (final handler in moduleHandlers) {
      if (handler.handles(module)) {
        final result = handler.call(function, input, callFunction);
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
  Map<String, BallValue Function(BallValue)> _buildStdDispatch() {
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
      'to_string': (i) => _stdConvert(i, (v) => v.toString()),
      'int_to_string': (i) => _stdConvert(i, (v) => (v as int).toString()),
      'double_to_string': (i) =>
          _stdConvert(i, (v) => (v as double).toString()),
      'string_to_int': (i) => _stdConvert(i, (v) => int.parse(v as String)),
      'string_to_double': (i) =>
          _stdConvert(i, (v) => double.parse(v as String)),

      // String interpolation — concatenates evaluated parts list.
      // Encoders emit this frequently; was previously missing from the engine.
      'string_interpolation': (i) {
        if (i is Map<String, Object?>) {
          final parts = i['parts'];
          if (parts is List) {
            return parts.map((p) => p?.toString() ?? '').join();
          }
          final value = i['value'];
          if (value != null) return value.toString();
        }
        return i?.toString() ?? '';
      },

      // Null safety
      'null_coalesce': (i) => _stdBinaryAny(i, (a, b) => a ?? b),
      'null_check': (i) => _extractUnaryArg(i)!,
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
      'dart_list_generate': (i) {
        final m = i as Map<String, Object?>;
        final count = _toInt(m['count']);
        final gen = m['generator'] as Function;
        return List.generate(count, (idx) => gen(idx));
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
        final list = (m['list'] as List).toList();
        list.add(m['value']);
        return list;
      },
      'list_pop': (i) {
        final list = ((i as Map<String, Object?>)['list'] as List).toList();
        if (list.isEmpty) throw BallRuntimeError('pop on empty list');
        final last = list.removeLast();
        return last;
      },
      'list_insert': (i) {
        final m = i as Map<String, Object?>;
        final list = (m['list'] as List).toList();
        list.insert(_toInt(m['index']), m['value']);
        return list;
      },
      'list_remove_at': (i) {
        final m = i as Map<String, Object?>;
        final list = (m['list'] as List).toList();
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
        return (m['list'] as List).contains(m['value']);
      },
      'list_index_of': (i) {
        final m = i as Map<String, Object?>;
        return (m['list'] as List).indexOf(m['value']);
      },
      'list_map': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = m['callback'] as Function;
        return list.map((e) => cb(e)).toList();
      },
      'list_filter': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = m['callback'] as Function;
        return list.where((e) => cb(e) == true).toList();
      },
      'list_reduce': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = m['callback'];
        var acc = m['initial'];
        for (final e in list) {
          acc = (cb as Function)(<String, Object?>{'left': acc, 'right': e});
        }
        return acc;
      },
      'list_find': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = m['callback'] as Function;
        return list.firstWhere((e) => cb(e) == true);
      },
      'list_any': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = m['callback'] as Function;
        return list.any((e) => cb(e) == true);
      },
      'list_all': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = m['callback'] as Function;
        return list.every((e) => cb(e) == true);
      },
      'list_none': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = m['callback'] as Function;
        return !list.any((e) => cb(e) == true);
      },
      'list_sort': (i) {
        final m = i as Map<String, Object?>;
        final sorted = (m['list'] as List).toList();
        final cb = m['callback'];
        sorted.sort((a, b) {
          final r = (cb as Function)(<String, Object?>{'left': a, 'right': b});
          return (r is int) ? r : (r as num).toInt();
        });
        return sorted;
      },
      'list_sort_by': (i) {
        final m = i as Map<String, Object?>;
        final sorted = (m['list'] as List).toList();
        final cb = m['callback'];
        sorted.sort((a, b) {
          final ka = (cb as Function)(a) as Comparable;
          final kb = (cb as Function)(b) as Comparable;
          return ka.compareTo(kb);
        });
        return sorted;
      },
      'list_reverse': (i) =>
          ((i as Map<String, Object?>)['list'] as List).reversed.toList(),
      'list_slice': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final start = _toInt(m['start']);
        final end = m['end'] != null ? _toInt(m['end']) : list.length;
        return list.sublist(start, end);
      },
      'list_flat_map': (i) {
        final m = i as Map<String, Object?>;
        final list = m['list'] as List;
        final cb = m['callback'] as Function;
        return list.expand((e) {
          final r = cb(e);
          return r is List ? r : [r];
        }).toList();
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

      // std_collections — map operations
      'map_get': (i) {
        final m = i as Map<String, Object?>;
        return (m['map'] as Map)[m['key']];
      },
      'map_set': (i) {
        final m = i as Map<String, Object?>;
        final map = Map<String, Object?>.from(m['map'] as Map);
        map[m['key'] as String] = m['value'];
        return map;
      },
      'map_delete': (i) {
        final m = i as Map<String, Object?>;
        final map = Map<String, Object?>.from(m['map'] as Map);
        map.remove(m['key']);
        return map;
      },
      'map_contains_key': (i) {
        final m = i as Map<String, Object?>;
        return (m['map'] as Map).containsKey(m['key']);
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
        return Map.fromEntries(
          list.map((e) => MapEntry((e as Map)['key'] as String, e['value'])),
        );
      },
      'map_merge': (i) {
        final m = i as Map<String, Object?>;
        return <String, Object?>{
          ...(m['map'] as Map).cast<String, Object?>(),
          ...(m['value'] as Map).cast<String, Object?>(),
        };
      },
      'map_map': (i) {
        final m = i as Map<String, Object?>;
        final map = m['map'] as Map;
        final cb = m['callback'];
        final result = <String, Object?>{};
        for (final entry in map.entries) {
          final r = (cb as Function)(<String, Object?>{
            'key': entry.key,
            'value': entry.value,
          });
          if (r is Map<String, Object?>) {
            result[r['key'] as String] = r['value'];
          } else {
            result[entry.key as String] = r;
          }
        }
        return result;
      },
      'map_filter': (i) {
        final m = i as Map<String, Object?>;
        final map = m['map'] as Map;
        final cb = m['callback'];
        final result = <String, Object?>{};
        for (final entry in map.entries) {
          if ((cb as Function)(<String, Object?>{
                'key': entry.key,
                'value': entry.value,
              }) ==
              true) {
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
          typeName = (val['__type'] as String?) ?? 'Exception';
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
      'await': (i) {
        final val = _extractUnaryArg(i);
        // Unwrap BallFuture; pass through anything else.
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
      'string_split': (i) =>
          _stdBinaryAny(i, (a, b) => (a as String).split(b as String)),
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
      'sleep_ms': (i) {
        // No-op in synchronous interpreter
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
      'thread_spawn': (i) {
        // Single-threaded: execute body synchronously, return 0 as handle.
        final m = i as Map<String, Object?>;
        final body = m['body'];
        if (body is Function) body(null);
        return 0;
      },
      'thread_join': (_) => null, // no-op in single-threaded mode
      'mutex_create': (_) => _nextMutexId++,
      'mutex_lock': (_) => null, // no-op
      'mutex_unlock': (_) => null, // no-op
      'scoped_lock': (i) {
        // Execute body directly (no actual locking).
        final m = i as Map<String, Object?>;
        final body = m['body'];
        if (body is Function) return body(null);
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

  BallValue _stdPrint(BallValue input) {
    if (input is Map<String, Object?>) {
      final message = input['message'];
      if (message != null) {
        stdout(message.toString());
        return null;
      }
    }
    stdout(input.toString());
    return null;
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
    if (target is List && index is int) return target[index];
    if (target is Map && index is String) return target[index];
    if (target is String && index is int) return target[index];
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

  BallValue _stdInvoke(BallValue input) {
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
    if (args.length == 1) return Function.apply(callee, [args.values.first]);
    // No arguments: pass null.
    if (args.isEmpty) return Function.apply(callee, [null]);
    // Multiple / named arguments: pass the full args map.
    return Function.apply(callee, [args]);
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
      if (value is Map<String, Object?> && value['__type__'] == baseType) {
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
    if (value['__type__'] == type) return true;
    // Walk __super__ chain
    var superObj = value['__super__'];
    while (superObj is Map<String, Object?>) {
      if (superObj['__type__'] == type) return true;
      superObj = superObj['__super__'];
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
    final entries = input['entries'];
    if (entries is List) {
      final result = <Object?, Object?>{};
      for (final entry in entries) {
        if (entry is Map<String, Object?>) {
          result[entry['name']] = entry['value'];
        }
      }
      return result;
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

  BallValue _stdSwitchExpr(BallValue input) {
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
          if (guard(bindings) != true) continue;
        }
        // If body is a function, call it with bindings to inject destructured vars.
        if (body is Function) return body(bindings);
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
    if (v is String) return int.parse(v);
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to int');
  }

  double _toDouble(BallValue v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.parse(v);
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to double');
  }

  num _toNum(BallValue v) {
    if (v is num) return v;
    throw BallRuntimeError('Cannot convert ${v.runtimeType} to num');
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
    final target = input['target'] as String;
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
    final value = _toNum(input['value']);
    final min = _toNum(input['min']);
    final max = _toNum(input['max']);
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
