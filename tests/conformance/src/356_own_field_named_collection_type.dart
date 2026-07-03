// Fixture for issue #167: a class's OWN field named exactly `List`, `Map`, or
// `Set` must shadow the builtin collection type when referenced unqualified
// inside an instance method — matching real Dart's own-scope-wins resolution —
// instead of always resolving to the engine's builtin-class sentinel.
//
// The bare type must still dispatch statically (List.generate) where no field
// shadows it. Contrast fixture 345, which covers the INHERITED-only case where
// the type is (correctly) NOT shadowed.

class Holder {
  Object List;
  Object Map;
  Object Set;

  Holder(this.List, this.Map, this.Set);

  void show() {
    // Unqualified reads resolve to the OWN fields, not the builtin types.
    print(List);
    print(Map);
    print(Set);
  }
}

void main() {
  Holder([1, 2, 3], 'a-map', 'a-set').show();

  // Bare `List` still dispatches statically when nothing shadows it.
  print(List.generate(3, (i) => i * 2));
}
