// #539: only a `this.`-formal may write a constructor parameter into the
// field of the same name. A PLAIN parameter that merely happens to share a
// field's name is an ordinary local — it must never clobber that field's
// initializer.
//
// Two independent engine sites carried the byte-identical defect:
//   * `_evalMessageCreation` (engine_eval.dart) — the UNNAMED-constructor call,
//     which the encoder emits as a `messageCreation` expression;
//   * `_callObjectConstructor` (engine_invocation.dart) — a NAMED constructor
//     WITH a body, which the encoder emits as a method call on the class
//     reference (see the note in 438_ctor_initializer_list_with_body.dart).
// Both wrote the argument into `instanceFields[param]` whenever
// `allFieldNames.contains(param)`, with no `is_this` check at all.
//
// Both also carried a second, broader defect behind the same `if`: an
// `else if (params.length == 1 && allFieldNames.length == 1)` fallback that
// wrote the sole argument into the sole field of ANY single-field class,
// whether or not the names collided. That branch masks the first one for the
// single-field shape, so removing only the name check is a no-op there — the
// `Box`/`Crate` cases below are the only ones that can see it.
//
// Existing fixtures (106, 112, 435-438) all use non-colliding parameter names,
// so nothing pointed the native-Dart-golden oracle at this shape.

// Shape 1 — MULTI-FIELD class, unnamed constructor, colliding plain param.
// Two fields mean the single-field fallback cannot mask the result, so this
// isolates the `allFieldNames.contains(param)` disjunct in _evalMessageCreation.
class Foo {
  int x = 5;
  int y = 7;

  Foo(int x) {
    print(x);
  }
}

// Shape 2 — the same collision through a NAMED constructor with a body, which
// takes the _callObjectConstructor path instead.
class Bar {
  int x = 5;
  int y = 7;

  Bar.named(int x) {
    print(x);
  }
}

// Shape 3 — SINGLE-FIELD class, one plain param whose name does NOT collide.
// The only shape that isolates the `params.length == 1 && allFieldNames.length
// == 1` fallback: nothing here even looks like an assignment to `v`.
class Box {
  int v = 7;

  Box(int n) {
    print(n);
  }
}

// Shape 3b — the same, through the named-constructor path.
class Crate {
  int v = 7;

  Crate.of(int n) {
    print(n);
  }
}

// Shape 4 — the issue's own repro: a single-field class whose sole plain param
// collides. Both defects fire at once here, which is why the fix needs both
// halves.
class Solo {
  int x = 5;

  Solo(int x) {
    print(x);
  }
}

// Shape 5 — POSITIVE CONTROL. A real `this.`-formal must still assign, through
// the unnamed constructor, a named constructor with a body, and a named
// constructor without one. The fix must not over-correct into dropping
// legitimate writes.
class Baz {
  int v = 7;
  int w = 11;

  Baz(this.v);

  Baz.tagged(this.v) {
    w = 12;
  }

  Baz.bare(this.w);
}

// Shape 6 — POSITIVE CONTROL. A plain parameter that the BODY explicitly
// assigns still reaches the field; removing the permissive write-through must
// not disturb the ordinary path.
class Sink {
  int v = 7;

  Sink(int n) {
    v = n * 2;
  }
}

// Shape 7 — POSITIVE CONTROL. A plain parameter consumed by an INITIALIZER
// LIST still reaches the field. The initializer's value must be a bare
// parameter reference: an initializer holding an EXPRESSION (`v = n + 1`) is
// stored by the encoder as its SOURCE TEXT and the engine has no evaluator for
// it, which is a separate, pre-existing gap this fixture deliberately avoids.
class Init {
  int v = 7;
  int w = 11;

  Init.viaList(int n) : v = n;
}

void main() {
  final foo = Foo(9);
  print(foo.x);
  print(foo.y);

  final bar = Bar.named(9);
  print(bar.x);
  print(bar.y);

  final box = Box(3);
  print(box.v);

  final crate = Crate.of(3);
  print(crate.v);

  final solo = Solo(9);
  print(solo.x);

  final baz = Baz(3);
  print(baz.v);
  print(baz.w);

  final tagged = Baz.tagged(4);
  print(tagged.v);
  print(tagged.w);

  final bare = Baz.bare(5);
  print(bare.v);
  print(bare.w);

  final sink = Sink(3);
  print(sink.v);

  final init = Init.viaList(3);
  print(init.v);
  print(init.w);
}
