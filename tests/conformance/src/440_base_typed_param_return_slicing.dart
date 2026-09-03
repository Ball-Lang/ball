// #516: a subclass instance handed across a function boundary declared with a
// BASE class type must keep its runtime type.
//
// #509 taught the C++ emitter that `A viaBase = b;` must declare the local with
// b's CONCRETE class, because a C++ struct local has value semantics and
// copying a B into an A-typed slot slices the derived part (vtable included)
// away. That fix is scoped, on purpose, to a `let` whose initialiser is a bare
// reference - it never touched the two other places a value crosses a
// statically-base-typed slot: a function PARAMETER and a function RETURN type.
//
// Both slice. Neither is visible to a build-only check (g++ compiles the sliced
// code happily) and neither is visible to any engine leg (every other target's
// engine is an interpreter with reference semantics, so nothing ever slices
// there). Only a compiled-and-RUN C++ fixture asserting on stdout can see it:
// before the fix the compiled binary prints A's getter value 1 twice instead of
// B's shadowing field value 10.
//
// AUTHORING NOTE - two adjacent, separately-filed C++ compiler bugs constrain
// how this must be phrased, or it fails for the wrong reason:
//   * the parameter argument goes through a BOUND LOCAL (`final b = B();`),
//     not inline (`readViaParam(B())`) - see issue #523.
//   * the returned value's field access is chained DIRECTLY
//     (`makeViaReturn().x`), not through an intermediate local - see issue
//     #524.
class A {
  int get x => 1;
}

class B extends A {
  @override
  int x = 10;
}

// The parameter is declared with the BASE type but is handed a subclass.
int readViaParam(A a) {
  return a.x;
}

// The return type is declared with the BASE type but a subclass is returned.
A makeViaReturn() {
  return B();
}

void main() {
  final b = B();
  print(readViaParam(b));
  print(makeViaReturn().x);
}
