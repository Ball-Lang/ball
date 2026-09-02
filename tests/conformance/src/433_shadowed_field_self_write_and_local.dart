// #501, the two shapes one step to the LEFT of 406/431/432 - both found by
// review of the first draft of the fix, and neither reachable from the corpus
// as it stood.
//
// 406/431/432 all touch the shadowing field through an explicit receiver
// (`b.x`, `viaBase.x`). The C++ emitter turns a shadowing field into a private
// backing member plus a public virtual accessor pair, so the bare NAME `x`
// inside the shadowing class stops naming a data member and starts naming a
// member FUNCTION. That makes two unqualified shapes go wrong, and they fail
// in opposite ways:
//
//   1. An unqualified WRITE (`x = 7`, `x += 3`). The read path compiles a bare
//      `x` to the accessor call `x()`, so the assign handler emitted
//      `ball_assign(x(), 7)` - g++: "cannot bind non-const lvalue reference of
//      type 'BallDyn&' to an rvalue". A loud build failure.
//   2. A method-LOCAL named `x`. It must read the local, but the accessor
//      branch fired on the name alone and emitted `x()` on it. `BallDyn` has
//      `operator()`, so that BUILDS and silently yields an empty BallDyn -
//      `null` instead of 99. A silent wrong answer, which is strictly worse.
//
// Shape 2 also exists for a plain getter with no shadowing anywhere (see
// `A.localOverGetter` below): the pre-existing `current_class_methods_` getter
// branch never consulted `declared_locals_` either.
class A {
  int get x => 1;

  // A local shadowing a getter declared by this very class. Independent of any
  // subclass field - this is the pre-existing sibling of shape 2.
  int localOverGetter() {
    int x = 99;
    return x;
  }
}

class B extends A {
  @override
  int x = 5;

  // Shape 1: unqualified write to the field that shadows A's getter.
  void bump() {
    x = 7;
  }

  // Shape 1, compound form - the same rvalue-accessor problem via `+=`.
  void addTo() {
    x += 3;
  }

  // The unqualified READ, which must go through the accessor.
  int readOwn() {
    return x;
  }

  // Shape 2: a method-local shadowing the shadowed field's name.
  int shadowLocal() {
    int x = 99;
    return x;
  }
}

void main() {
  // Shape 2 on a plain, unshadowed getter.
  print(A().localOverGetter());

  B b = B();
  print(b.readOwn());

  // Shape 1: unqualified write, then read it back both ways.
  b.bump();
  print(b.x);
  print(b.readOwn());

  // Shape 1, compound.
  b.addTo();
  print(b.x);
  print(b.readOwn());

  // Shape 2: the local must win, and must not disturb the field.
  print(b.shadowLocal());
  print(b.x);

  // Still the field, through a base-typed binding (runtime dispatch).
  A viaBase = b;
  print(viaBase.x);

  // A's own getter is untouched by any of B's writes.
  print(A().x);
}
