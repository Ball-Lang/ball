// #555: an INLINE-constructed user-class argument must be bound to the
// parameter as a whole, never destructured into a same-named parameter slot.
//
// `_callFunction` binds a single parameter by NAME first
// (`inputMap.containsKey(params[0])`), and a constructed instance IS a map
// whose keys are the CLASS's field names. So `firstOfPair(Pair(8, 9))`, where
// the callee's parameter is named `a` and `Pair` also has a field `a`, bound
// `a` to the FIELD value `8` instead of to the `Pair` — then threw
// `Cannot access field "a" on int`. `_callObjectConstructor` extracts its
// parameters the same way, so a named constructor taking the inline instance
// was corrupted identically.
//
// An instance is distinguishable from a call's argument bag: it carries
// `__type__` naming a class that has a TypeDefinition. An argument bag either
// has no `__type__` at all, or (for a call the encoder emitted as a
// `messageCreation`) carries a FUNCTION name, which never has one.
//
// 444_inline_constructed_call_argument deliberately EXCLUDES this shape and
// points here; every other fixture binds the instance to a local first
// (`final p = Pair(8, 9); firstOfPair(p);`), which produces a plain reference
// the binder cannot destructure.

class Pair {
  int a;
  int b;

  Pair(this.a, this.b);
}

// Parameter named `a` — collides with Pair's field `a`.
int firstOfPair(Pair a) {
  return a.a;
}

// Parameter named `b` — collides with Pair's other field, and the collision is
// silent rather than loud: `b.b` on the int 9 would throw, but a callee that
// only ever returned `9` would have looked correct by accident.
int secondOfPair(Pair b) {
  return b.b;
}

// The non-colliding control: the same call shape with a parameter name that
// matches no field must keep working.
int sumOfPair(Pair p) {
  return p.a + p.b;
}

// The constructor twin of the same binding path: a named constructor with a
// body, whose parameter name collides with a field of the class it receives.
class Wrapper {
  int got = 0;

  Wrapper.around(Pair a) {
    got = a.b;
  }
}

// And the unnamed-constructor (messageCreation) shape of the same collision.
class Holder {
  int seen = 0;

  Holder(Pair b) {
    seen = b.a;
  }
}

void main() {
  print(firstOfPair(Pair(8, 9)));
  print(secondOfPair(Pair(8, 9)));
  print(sumOfPair(Pair(8, 9)));

  // The already-working shape, kept as a control: bound to a local first.
  final p = Pair(8, 9);
  print(firstOfPair(p));
  print(secondOfPair(p));

  print(Wrapper.around(Pair(8, 9)).got);
  print(Holder(Pair(8, 9)).seen);
}
