// The POSITIVE half of #539: the constructor field writes that must still
// happen once the engine stops writing a plain parameter into a same-named
// field. Kept in its own fixture from the negative shapes in 453 because these
// are the ones every COMPILER target already supports, so they gate the
// compiled legs too rather than only the engines.
//
// A `this.`-formal assigns. A plain parameter the BODY assigns reaches the
// field the ordinary way. A parameter that shares no field name is just a
// local. And an inline-constructed instance whose class's field names do NOT
// collide with the callee's parameter binds as the whole object — the control
// that 454's collisions are measured against.

class Baz {
  int v = 7;

  Baz(this.v);
}

class Sink {
  int v = 7;

  Sink(int n) {
    v = n * 2;
  }
}

class Pair {
  int a;
  int b;

  Pair(this.a, this.b);
}

int sumOfPair(Pair p) {
  return p.a + p.b;
}

void main() {
  print(Baz(3).v);
  print(Sink(3).v);
  print(sumOfPair(Pair(8, 9)));
}
