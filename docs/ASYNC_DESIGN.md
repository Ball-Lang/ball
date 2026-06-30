# Async Engine Architecture: Limitations and Design Options

## Current State

Both the Dart and C++ engines implement `async`/`await` as a synchronous simulation:
- `async` functions wrap their return value in a `BallFuture` (a marker wrapper)
- `await` recursively unwraps `BallFuture` values synchronously
- There is no event loop, no microtask queue, and no deferred execution

This means:
- `await Future.delayed(Duration(seconds: 1))` completes instantly (no actual delay)
- Multiple concurrent async operations execute sequentially
- `Stream` operations are not supported
- Any package using real async I/O (HTTP clients, file I/O, timers) will behave incorrectly

## Impact Assessment

Of the top-20 pub packages:
- **17 packages** are pure computation — async doesn't matter
- **3 packages** have I/O (args, yaml, shelf) — but their I/O is synchronous
- **0 packages** require real async in their core logic

For broader ecosystem adoption, the packages most affected are:
- `http` / `dio` — HTTP clients (fundamentally async)
- `shelf` — HTTP server (listener is async)
- `stream_channel` — bidirectional async communication
- Any package using `dart:io` socket/file APIs in async mode

## Design Options

### Option A: CPS Transform (Continuation-Passing Style)

Rewrite every expression evaluator to return a continuation:

```dart
typedef Continuation = void Function(BallValue result);
void evalExpr(Expression expr, Scope scope, Continuation k) {
  // Instead of: return value;
  // Do:         k(value);
}
```

**Pros:** True async without language-level async/await in the engine.
**Cons:** Complete rewrite of the engine (~7,600 lines across multiple files). Every expression evaluation path changes. Hard to debug. Stack overflow risk for deep expressions unless trampolined.

### Option B: Dart async/await in Engine

Make `_evalExpression` return `Future<BallValue>` and mark everything async:

```dart
Future<BallValue> _evalExpression(Expression expr, Scope scope) async {
  return switch (expr.whichExpr()) {
    Expression_Expr.call => await _evalCall(expr.call, scope),
    // ...
  };
}
```

**Pros:** Simplest conceptually. Dart's runtime handles scheduling.
**Cons:** ~2x performance overhead from Future allocation on every expression eval. Changes the return type signature of ~100 methods (engine is already async internally). Requires careful handling of FlowSignals across async boundaries.

### Option C: Selective Async (Recommended)

Keep the synchronous fast path for pure expressions. Only go async when an `await` expression is actually encountered:

```dart
BallValue _evalExpression(Expression expr, Scope scope) {
  // Fast path: synchronous eval for 99% of expressions
  final result = _evalExprSync(expr, scope);
  if (result is BallPendingFuture) {
    // Slow path: expression produced a real async value
    throw _AsyncEscapeSignal(result);
  }
  return result;
}
```

The engine runs synchronously by default. When an `await` on a real async value is encountered, it throws a special signal that unwinds the call stack to an async trampoline at the top level, which schedules resumption.

**Pros:** Zero overhead for synchronous code. Only async code pays the async cost.
**Cons:** Complex implementation. Requires saving/restoring evaluation context (like coroutines).

### Option D: Zone-Based Async (Pragmatic Compromise)

Wrap the entire `BallEngine.run()` in a Dart Zone that captures async operations:

```dart
Future<void> runAsync() async {
  await runZonedGuarded(() {
    run(); // Synchronous execution
  }, (error, stack) {
    // Handle async errors
  });
}
```

Use `dart:async` `Completer` for explicit async points. The engine stays synchronous but base functions that need async (HTTP, file I/O) return `Completer` futures that the zone resolves.

**Pros:** Minimal engine changes. Base function authors handle async.
**Cons:** Only works for base function calls, not for user-defined async functions.

---

These four options remain the design menu for moving the engine off synchronous
async-simulation. Sequencing and effort estimates are tracked as GitHub issues,
not pinned here.
