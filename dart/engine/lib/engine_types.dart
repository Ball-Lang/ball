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

/// Runtime representation of a Ball class instance.
///
/// The public shape mirrors the object metadata expected by conformance tests:
/// `__type__`, `__super__`, `__fields__`, and `__methods__`.  It also extends
/// [BallMap] so existing map-oriented engine paths keep working while class
/// fields remain grouped under [fields].
class BallObject extends BallMap {
  final String typeName;
  Object? superObject;
  final Map<String, Object?> fields;
  final Map<String, Object?> methods;

  BallObject({
    required this.typeName,
    this.superObject,
    Map<String, Object?>? fields,
    Map<String, Object?>? methods,
  }) : fields = fields ?? <String, Object?>{},
       methods = methods ?? <String, Object?>{},
       super(<String, Object?>{}) {
    _refreshEntries();
  }

  void _refreshEntries() {
    entries
      ..clear()
      ..addAll(fields)
      ..['__type__'] = typeName
      ..['__super__'] = superObject
      ..['__fields__'] = fields
      ..['__methods__'] = methods;
  }

  void setField(String name, Object? value) {
    fields[name] = value;
    entries[name] = value;
  }

  @override
  void operator []=(String key, Object? value) {
    if (key == '__super__') {
      superObject = value;
      entries[key] = value;
      return;
    }
    if (key == '__methods__') {
      methods
        ..clear()
        ..addAll(value is Map<String, Object?> ? value : <String, Object?>{});
      entries[key] = methods;
      return;
    }
    if (!key.startsWith('__')) fields[key] = value;
    entries[key] = value;
  }
}

/// Insertion-ordered map for runtime containers (Dart LinkedHashMap semantics).
/// Emitted as `BallOrderedMap{}` in C++ self-host — NOT `std::map` (key-sorted).
Map<Object?, Object?> _ballUserMap() => LinkedHashMap<Object?, Object?>();

/// Fresh sync*/async* yield collector — emitted as `BallDyn(BallGenerator{})`.
BallGenerator _ballNewGenerator() => BallGenerator();

/// Dart `double.toInt()` / `truncate()` semantics with int64 clamping.
int _ballDoubleToInt64(Object? value) {
  if (value is int) return value;
  if (value is BallInt) return value.value;
  final d = (value is BallDouble ? value.value : (value as num).toDouble());
  if (d >= 9223372036854775808.0) return 9223372036854775807;
  if (d <= -9223372036854775808.0) return -9223372036854775808;
  final r = d.toInt();
  if (d > 0.0 && r < 0) return 9223372036854775807;
  return r;
}

/// UTF-16 code unit access — emitted as `ball_code_unit_at` in C++ self-host.
int _ballCodeUnitAt(Object? s, Object? index) =>
    (s as String).codeUnitAt(index as int);

/// Dart `Object.runtimeType.toString()` for primitive Ball values.
String _ballRuntimeTypeName(Object? value) {
  if (value == null || value is BallNull) return 'Null';
  if (value is int || value is BallInt) return 'int';
  if (value is double || value is BallDouble) return 'double';
  if (value is String || value is BallString) return 'String';
  if (value is bool || value is BallBool) return 'bool';
  if (value is List || value is BallList) return 'List';
  if (value is Map || value is BallMap) return 'Map';
  return 'Object';
}

/// Dart num.toDouble() — always stores as double (avoids int64 wrap on large ints).
double _ballToDouble(Object? value) {
  if (value is double) return value;
  if (value is BallDouble) return value.value;
  if (value is int) return value.toDouble();
  if (value is BallInt) return value.value.toDouble();
  if (value is num) return value.toDouble();
  return 0.0;
}

/// Strict runtime type tests for pattern matching (avoid `is double` → num widen).
bool _ballIsInt(Object? v) => v is int || v is BallInt;
bool _ballIsDouble(Object? v) => v is double || v is BallDouble;
bool _ballIsNum(Object? v) => v is num || v is BallInt || v is BallDouble;
bool _ballIsString(Object? v) => v is String || v is BallString;
bool _ballIsBool(Object? v) => v is bool || v is BallBool;
bool _ballIsList(Object? v) => v is List || v is BallList;
bool _ballIsMap(Object? v) => v is Map || v is BallMap;

/// Yield values collected by a sync*/async* generator.
List<Object?> _ballGeneratorValues(BallGenerator gen) => gen.values;

/// Map values in insertion order — emitted as `ball_map_values(BallDyn(...))` in C++.
List<Object?> _ballMapValues(Map map) => map.values.toList();

Object? _ballMapHandleEntries(Object? map) {
  if (map is BallMap) return map.entries;
  return map;
}

/// Map keys for a runtime map handle (BallOrderedMap / BallDyn) — C++ intrinsic.
List<Object?> _ballMapKeysDyn(Object? map) {
  final handle = _ballMapHandleEntries(map);
  if (handle is Map) return handle.keys.toList();
  return [];
}

/// Map values for a runtime map handle (BallOrderedMap / BallDyn) — C++ intrinsic.
List<Object?> _ballMapValuesDyn(Object? map) {
  final handle = _ballMapHandleEntries(map);
  if (handle is Map) return _ballMapValues(handle);
  return [];
}

/// Key check for runtime map handles — C++ intrinsic.
bool _ballMapContainsKeyDyn(Object? map, Object? key) {
  final handle = _ballMapHandleEntries(map);
  if (handle is Map) return handle.containsKey(key);
  return false;
}

/// In-place map write for BallOrderedMap / BallDyn — C++ intrinsic (ball_set).
void _ballMapSetDyn(Object? map, Object? key, Object? value) {
  final handle = _ballMapHandleEntries(map);
  if (handle is Map) handle[key] = value;
}

/// Write [fieldName] on a live instance map (BallObject or __type__ map).
/// Emitted as a call to preamble `ball_object_set_field` in C++ self-host.
void ballObjectSetField(Object? target, String fieldName, Object? val) {
  if (target is BallObject) {
    target.setField(fieldName, val);
    return;
  }
  if (target is BallMap) {
    if (target.entries.containsKey('__type__')) {
      target[fieldName] = val;
    }
    return;
  }
  if (target is Map<String, Object?> && target.containsKey('__type__')) {
    target[fieldName] = val;
  }
}

/// Read a protobuf-Struct bool metadata field.
///
/// Handles native [structpb.Value] (Dart engine) and map-shaped proto3-JSON
/// Value objects (`{boolValue: true}`) used by the C++ self-host loader.
bool _metadataBool(Object? field) {
  if (field == null) return false;
  if (field is bool) return field;
  if (field is structpb.Value) {
    return field.hasBoolValue() && field.boolValue;
  }
  if (field is Map) {
    final bv = field['boolValue'];
    if (bv is bool) return bv;
  }
  return false;
}

/// Numeric predicates using operators the Ball→C++ compiler lowers directly
/// (not BallDyn property dispatch like `.isNaN`, which recurses infinitely).
bool _ballNumIsNaN(Object? v) {
  if (v is int) return false;
  if (v is double) {
    final d = v;
    return d != d;
  }
  return false;
}

bool _ballNumIsFinite(Object? v) {
  if (v is int) return true;
  if (v is double) {
    final d = v;
    if (d != d) return false;
    return d.isFinite;
  }
  return false;
}

bool _ballNumIsInfinite(Object? v) {
  if (v is int) return false;
  if (v is double) {
    final d = v;
    return d.isInfinite;
  }
  return false;
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

/// Creates a BallFuture map: {__ball_future__: true, value: v, completed: true}.
///
/// BallFuture is a synchronous simulation of async results. Async functions
/// wrap their return values in a BallFuture map, and `await` unwraps them.
/// The `__ball_future__` marker makes futures detectable by Ball programs
/// and the engine alike.
Map<String, Object?> _ballFuture(Object? value) => {
  '__ball_future__': true,
  'value': value,
  'completed': true,
};

/// Creates a BallFuture in error state: {__ball_future__: true, error: e, completed: true}.
///
/// When an async function throws, the error is captured into a BallFuture
/// so that `await` can rethrow it at the call site.
Map<String, Object?> _ballFutureError(Object? error) => {
  '__ball_future__': true,
  'error': error,
  'completed': true,
};

/// Returns `true` if [value] is a BallFuture map.
bool _isBallFuture(Object? value) =>
    value is Map<String, Object?> && value['__ball_future__'] == true;

/// Returns `true` if [value] is a BallFuture in error state.
bool _isBallFutureError(Object? value) =>
    _isBallFuture(value) &&
    (value as Map<String, Object?>).containsKey('error');

/// Unwraps a BallFuture map, returning the inner value.
/// If [value] is a BallFuture in error state, rethrows the stored error.
/// If [value] is not a BallFuture, returns it unchanged.
Object? _unwrapBallFuture(Object? value) {
  if (_isBallFuture(value)) {
    final map = value as Map<String, Object?>;
    if (map.containsKey('error')) {
      final error = map['error'];
      if (error is BallException) throw error;
      if (error is BallRuntimeError) throw error;
      throw BallRuntimeError(error?.toString() ?? 'Unknown async error');
    }
    return map['value'];
  }
  return value;
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
  'int',
  'double',
  'num',
  'String',
  'bool',
  'List',
  'Map',
  'Set',
  'Null',
  'void',
  'Object',
  'dynamic',
  'Function',
  'Future',
  'Stream',
  'Iterable',
  'Iterator',
  'Type',
  'Symbol',
  'Never',
};
