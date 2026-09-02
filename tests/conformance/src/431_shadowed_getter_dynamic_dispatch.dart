// #501, dispatch rule: a subclass plain field shadowing an inherited getter is
// resolved by the receiver's RUNTIME type, never by its static/declared type.
//
// 406_subclass_field_over_getter only ever reads through a receiver whose
// static and runtime types are the same, so it cannot tell a correct fix from
// the unsound shortcut the issue body literally suggests ("resolve via the
// receiver's static class"). `readX` and `describe` are declared on A, so the
// receiver they read `x` through is statically an A every time; calling them on
// a B must still answer with B's shadowing field. A static-type resolution
// prints A's getter value here and is silently wrong; C++ virtual dispatch (or
// any other runtime mechanism) prints Dart's answer.
class A {
  int get x => 1;

  int readX() {
    return x;
  }

  String describe() {
    return 'x=$x';
  }
}

class B extends A {
  @override
  int x = 5;
}

void main() {
  A a = A();
  print(a.x);
  print(a.readX());
  print(a.describe());

  B b = B();
  print(b.x);
  print(b.readX());
  print(b.describe());

  // A write to the shadowing field is visible to the base-declared reader too.
  b.x = 7;
  print(b.x);
  print(b.readX());
  print(b.describe());

  // A base-typed binding initialized with a subclass instance.
  A viaBase = B();
  print(viaBase.x);
  print(viaBase.readX());
}
