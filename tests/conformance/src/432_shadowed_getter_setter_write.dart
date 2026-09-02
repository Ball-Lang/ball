// #501, write path: the setter-side sibling of 406 and 431.
//
// The C++ compiler resolves an assignment target the same receiver-agnostic way
// it resolves a read - `has_setter` asks only "does ANY class in the program
// declare a setter named x", never "which class is this receiver". 406 never
// reaches that branch: no class in it declares `set x`, so `has_setter` stays
// false and the write falls through to the (equally receiver-blind, but there
// harmless) plain-field branch. Here the ancestor declares BOTH `get x` and
// `set x`, so the setter branch is genuinely taken. Dart's answer is that B's
// implicit field accessors override BOTH of A's: `b.x = 7` stores 7 verbatim
// instead of running A's scaling setter, while `a.x = 3` still scales.
class A {
  int _stored = 1;

  int get x => _stored;

  set x(int value) {
    // Deliberately not an identity setter: if a write on a B ever reached this
    // inherited setter, the read-back would print 70 instead of 7.
    _stored = value * 10;
  }

  int readX() {
    return x;
  }
}

class B extends A {
  @override
  int x = 5;
}

void main() {
  // A's own accessors: the setter scales, the getter reads the backing field.
  A a = A();
  print(a.x);
  a.x = 3;
  print(a.x);
  print(a.readX());

  // B's field shadows both inherited accessors, so the write stores verbatim
  // and the base-declared reader sees the same value.
  B b = B();
  print(b.x);
  b.x = 7;
  print(b.x);
  print(b.readX());

  // Same shape through a base-typed binding holding a subclass instance.
  A viaBase = B();
  viaBase.x = 9;
  print(viaBase.x);
  print(viaBase.readX());

  // A's instance was never touched by any of B's writes.
  print(a.x);
}
