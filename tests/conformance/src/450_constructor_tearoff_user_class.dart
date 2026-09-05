// #531 - Dart's constructor tear-off `ClassName.new(args)` must construct an
// instance, exactly like `ClassName(args)`.
//
// The encoder emits a tear-off as a GENERIC method call carrying its receiver:
// `{function: "new", input: {self: Reference("Box"), arg0: 7}}`. That shape is
// neither the `mod:Box.new` Call the compiler special-cases nor the
// MessageCreation the direct-construction path uses, so the C++ compiler's
// "user static-method dispatch takes priority" branch emitted
// `Box::new_(...)` - `sanitize_name("new")` appends `_` because `new` is a C++
// reserved word - and g++ rejected it with "'new_' is not a member of 'Box'".
//
// No corpus fixture had ever used `.new(` (a grep over tests/conformance/src
// returned zero hits), and the encoder branch that produces this shape never
// calls `_usedBaseFunctions.add(...)`, so the encoder-completeness gate applied
// no pressure to add one either: an entire CALL SHAPE round-tripped untested.

class Box {
  final int v;
  Box(this.v);
}

class Pair {
  final int a;
  final String b;
  Pair(this.a, this.b);
}

class Counter {
  int n = 0;
  Counter();
  int bump() {
    n = n + 1;
    return n;
  }
}

void main() {
  // The exact shape of #531: a tear-off with one positional argument.
  final b = Box.new(7);
  print(b.v);

  // Two arguments of different types, so a dropped/reordered argument shows.
  final p = Pair.new(3, 'three');
  print(p.a);
  print(p.b);

  // A zero-argument tear-off, and a method call on the result.
  final c = Counter.new();
  print(c.bump());
  print(c.bump());

  // Control: the SAME class still constructs through the ordinary path.
  final direct = Box(11);
  print(direct.v);
}
