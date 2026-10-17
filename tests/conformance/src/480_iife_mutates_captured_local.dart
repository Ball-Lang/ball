// An immediately-invoked anonymous function (`(() { ... })()`) that mutates a
// local captured from its ENCLOSING scope must leave that mutation visible to
// the caller once the call returns — Dart's closures share the enclosing
// lexical scope, they never clone it. `dart/encoder/lib/encoder.dart`'s
// `FunctionExpressionInvocation` arm lowers every such call, early-exiting or
// not, to the SAME Ball shape: `std.invoke(callee: <lambda>)`.
//
// Issue #734: `rust/compiler`'s `compile_lambda` pre-clones every local a
// `lambda` captures into the `move` closure's own copy, to dodge a Rust
// `error[E0382]` when the same local is captured by more than one closure.
// That is sound for a closure that is stored and might be invoked again
// later, but this lambda is constructed and invoked exactly once, right
// here — so the pre-clone silently drops the write-back to the caller's own
// binding. The defect is reachable both when the call exits EARLY (a Rust
// `return`/`?` inside the closure, #687/#725's IIFE lowering) and when it
// simply runs to completion, so this fixture exercises both shapes.

int earlyExitMutation() {
  int counter = 0;
  int result = (() {
    counter = counter + 1;
    if (counter > 0) {
      return counter * 10;
    }
    return -1;
  })();
  return counter + result;
}

int completionMutation() {
  int total = 0;
  (() {
    total = total + 5;
    total = total + 2;
  })();
  return total;
}

void main() {
  print(earlyExitMutation());
  print(completionMutation());
}
