// #513 - a member read THROUGH a class-typed field must not emit a
// concrete-struct member access.
//
// `emit_struct` maps every non-primitive descriptor field to a `BallDyn`
// member, so `holder.leaf` is a BallDyn at the C++ level. The field-access path
// still answered "plain struct field" for the OUTER read, purely because SOME
// user class in the program declares a field of that name, and emitted
// `holder.leaf.label` on that BallDyn receiver - g++: "'class BallDyn' has no
// member named 'label'".
//
// Fixtures 435-437 hit the SELF-REFERENTIAL (linked list / tree) shape. This
// one pins the plain, non-self-referential shape, covers a NON-nullable
// class-typed field (erased the same way, so nullability was never the real
// discriminator), and proves in the same program that a GETTER whose declared
// return type is a concrete class still keeps the typed member path.

class Leaf {
  int weight;
  String label;
  Leaf(this.weight, this.label);
}

class Holder {
  Leaf? leaf;
  Holder(this.leaf);
}

class Wrapper {
  Leaf inner;
  Wrapper(this.inner);
}

class Origin {
  int seed;
  Origin(this.seed);

  Leaf get made => Leaf(seed, 'made');
}

void main() {
  // A nullable class-typed field, read through at both levels.
  final h = Holder(Leaf(7, 'seven'));
  print(h.leaf!.weight);
  print(h.leaf!.label);

  final empty = Holder(null);
  print(empty.leaf == null);

  // A NON-nullable class-typed field is erased to BallDyn just the same.
  final w = Wrapper(Leaf(9, 'nine'));
  print(w.inner.weight);
  print(w.inner.label);

  // A getter that RETURNS a concrete class resolves on the struct, so the fix
  // must not widen this into bracket access.
  final o = Origin(4);
  print(o.made.weight);
  print(o.made.label);

  // Writing the nullable field and reading the new object back.
  h.leaf = Leaf(11, 'eleven');
  print(h.leaf!.weight);
  print(h.leaf!.label);
}
