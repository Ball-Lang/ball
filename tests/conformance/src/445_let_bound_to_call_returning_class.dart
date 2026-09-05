// #524 - a `let` whose initialiser is a CALL returning a user class must be
// declared with that concrete class, not wrapped in BallDyn.
//
// The let compiler decided "user-class typed" from the let's own `type`
// metadata or from a MessageCreation initialiser. A Call initialiser matched
// neither branch, so the local fell into the generic `auto r = BallDyn(f());`
// path and every subsequent member read named a member of BallDyn - g++:
// "'class BallDyn' has no member named 'x'".
//
// The declared type has to be the concrete class the callee actually RETURNS
// (#516's widening), not the callee's declared output type: a C++ local has
// value semantics, so `A r = makeViaReturn();` would slice B's shadowing field
// away and print the ancestor getter's 1 instead of 10.
//
// Every existing corpus fixture initialises a user-class local from an instance
// creation or another local, which is why nothing caught this.

class A {
  int get x => 1;
  String describe() => 'A';
}

class B extends A {
  @override
  int x = 10;

  @override
  String describe() => 'B';
}

class Point {
  int px;
  int py;
  Point(this.px, this.py);

  int get sum => px + py;
}

// Declared base-typed, but the body always builds the subclass.
A makeViaReturn() {
  return B();
}

Point makePoint() {
  return Point(3, 4);
}

Point shiftedFrom(Point p) {
  return Point(p.px + 1, p.py + 1);
}

void main() {
  // The exact shape of #524.
  final r = makeViaReturn();
  print(r.x);
  print(r.describe());

  // A leaf class returned from a call, read through a field and a getter.
  final p = makePoint();
  print(p.px);
  print(p.py);
  print(p.sum);

  // The call's own argument is another call-bound local.
  final q = shiftedFrom(p);
  print(q.px);
  print(q.py);
  print(q.sum);

  // An explicitly annotated local takes the same path.
  final Point annotated = makePoint();
  print(annotated.sum);
}
