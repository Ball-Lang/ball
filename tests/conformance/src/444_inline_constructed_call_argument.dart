// #523 - a freshly-constructed user-class instance written INLINE at a call
// site must be emitted as one positional argument, never destructured into the
// callee's parameter slots.
//
// `compile_call_arguments` treated a MessageCreation input as the call's
// argument BAG and matched the callee's declared parameter names against that
// message's own fields. An instance creation carries the CLASS's fields, not
// call arguments, so `readBox(Box())` matched nothing and came out as
// `readBox()` - g++: "too few arguments to function". TS fixed the same bug
// class under #213 by checking `typeName` first; C++ never got that guard.
//
// Every existing corpus fixture binds the instance to a local before passing it
// (`final b = Box(); readBox(b);`), which is exactly why nothing caught this.
//
// NOT covered here: the variant where the callee's parameter NAME collides with
// a field name of the class constructed inline (`int firstOfPair(Pair a)` with
// `Pair(this.a, this.b)`). That shape hits the same missing typeName guard in
// the reference Dart ENGINE's parameter binding, which is a separate defect in
// a separate component — see issue #555.

class Box {
  int v = 7;
}

class Pair {
  int a;
  int b;
  Pair(this.a, this.b);
}

class Tag {
  String name;
  Tag(this.name);
}

int readBox(Box b) {
  return b.v;
}

int sumPair(Pair p) {
  return p.a + p.b;
}

String labelOf(Tag t) {
  return 'tag=${t.name}';
}

int addTo(Box b, int extra) {
  return b.v + extra;
}

void main() {
  // The exact shape of #523: the sole argument, constructed inline.
  print(readBox(Box()));

  // A constructor that takes real arguments is still ONE positional value.
  print(sumPair(Pair(3, 4)));

  // A string-carrying class, so the dropped argument is not int-shaped.
  print(labelOf(Tag('alpha')));

  // Control: an inline construction alongside a second argument goes through a
  // real argument bag (empty typeName) and must keep working unchanged.
  print(addTo(Box(), 5));

  // Nested: an inline construction whose own argument is another inline call.
  print(sumPair(Pair(readBox(Box()), 1)));
}
