part of 'engine.dart';

/// without holding a direct [BallEngine] reference.
typedef BallCallable =
    FutureOr<Object?> Function(String module, String function, Object? input);

/// Sentinel for break/continue/return flow control.
class _FlowSignal extends BallValue {
  final String kind; // 'break', 'continue', 'return'
  final String? label;
  final Object? value; // only for 'return'
  _FlowSignal(this.kind, {this.label, this.value});
}

/// A scope contains variable bindings. Scopes are chained for lexical nesting.
class _Scope {
  final Map<String, Object?> _bindings = {};
  final _Scope? _parent;

  /// Registered scope-exit cleanups added by `cpp_std.cpp_scope_exit`.
  /// Each entry is an (expression, evalScope) pair executed in LIFO order
  /// when the scope that owns this list is torn down.
  final List<(Expression, _Scope)> _scopeExits = [];

  _Scope([this._parent]);

  Object? lookup(String name) {
    if (_bindings.containsKey(name)) return _bindings[name];
    if (_parent != null) return _parent.lookup(name);
    throw BallRuntimeError('Undefined variable: "$name"');
  }

  void bind(String name, Object? value) {
    _bindings[name] = value;
  }

  bool has(String name) {
    if (_bindings.containsKey(name)) return true;
    return _parent?.has(name) ?? false;
  }

  void set(String name, Object? value) {
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
class BallFuture extends BallValue {
  /// The resolved value (always completed in a synchronous interpreter).
  final Object? value;

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
class BallGenerator extends BallValue {
  /// The yielded values.
  final List<Object?> values = [];

  /// Whether this generator has completed.
  bool completed = false;

  /// Add a yielded value.
  void yield_(Object? value) => values.add(value);

  /// Add all values from an iterable (yield*).
  void yieldAll(Iterable<Object?> items) => values.addAll(items);

  @override
  String toString() => 'BallGenerator(${values.length} values)';
}

/// A typed exception thrown by a Ball program's `throw` expression.
/// Preserves the original value so catch clauses can match on type.
class BallException extends BallValue implements Exception {
  /// The type name of the thrown value (e.g. "FormatException").
  final String typeName;

  /// The actual thrown value (could be a string, map, etc.).
  final Object? value;

  BallException(this.typeName, this.value);

  @override
  String toString() => value?.toString() ?? typeName;
}

/// Thrown by `std_io.exit` / `std_io.panic` to terminate gracefully.
class _ExitSignal extends BallValue implements Exception {
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
///   @override Object? call(String fn, Object? input, BallCallable engine) {
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
///   @override Object? call(String fn, Object? input, BallCallable engine) {
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
  FutureOr<Object?> call(String function, Object? input, BallCallable engine);

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
  final Map<String, FutureOr<Object?> Function(Object?)> _dispatch = {};

  /// Composition-aware dispatch table for closures that need [BallCallable].
  /// Checked before [_dispatch] so [registerComposer] can override built-ins.
  final Map<String, FutureOr<Object?> Function(Object?, BallCallable)>
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
  void register(String function, FutureOr<Object?> Function(Object?) handler) {
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
    FutureOr<Object?> Function(Object?, BallCallable) handler,
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
  FutureOr<Object?> call(String function, Object? input, BallCallable engine) {
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
