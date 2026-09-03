// #515: a field that shadows an inherited getter must only change how THAT
// class's field is reached - never how an unrelated class's same-named plain
// field is reached.
//
// #501/#509 taught the C++ emitter to re-expose a shadowing field as a virtual
// accessor pair, and four dispatch sites learned to route reads/writes of such
// a field through the accessor. All four consulted a PROGRAM-WIDE set of
// shadowed field NAMES, so the moment any class anywhere shadowed a getter
// called `x`, every other class's own plain `int x` was routed through an
// accessor `x()` that does not exist on it.
//
// 406/431/432/433 all have exactly ONE class family using a given shadowed
// name, so a program-wide name set and a correctly per-class scoped one emit
// byte-identical C++ for every one of them. This fixture is the first with a
// SECOND, unrelated class reusing the name, which is the only shape that can
// tell the two apart.
//
// It exercises all four sites - the unqualified read inside the class, the
// unqualified compound-assignment write, the external `obj.field = value`
// write, and the external `obj.field` read - through all three receiver
// shapes: an implicit `this`, a local variable, and a fresh instance
// expression.
class A {
  int get x => 1;
}

class B extends A {
  @override
  int x = 10;
}

// No relation to A or B. Its `x` is an ordinary data member: reading it must
// never compile to an accessor call.
class C {
  int x = 3;

  // Site 1: unqualified read, receiver is the implicit `this`.
  int readOwn() {
    return x;
  }

  // Site 2: unqualified compound-assignment write.
  void bump() {
    x += 1;
  }
}

void main() {
  // The genuine shadow still dispatches on the runtime type.
  B b = B();
  print(b.x);
  A viaBase = b;
  print(viaBase.x);
  print(A().x);

  C c = C();
  // Site 1 and site 4, local-variable receiver.
  print(c.readOwn());
  print(c.x);

  c.bump();
  print(c.readOwn());
  print(c.x);

  // Site 3: external plain-field write, then read back both ways.
  c.x = 9;
  print(c.x);
  print(c.readOwn());

  // Site 4 and site 1 again, fresh-instance-expression receiver.
  print(C().x);
  print(C().readOwn());
}
