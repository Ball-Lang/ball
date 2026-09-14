// `.isNotEmpty` is its OWN base function (`std.string_is_not_empty`), never the
// negation of `.isEmpty` — issue #674. This fixture is the cross-target proof
// that every engine and compiler answers it for the same receiver kinds
// `string_is_empty` accepts, so the encoder never has to fall back to the
// rewrite that lost member identity.
void main() {
  // String receivers.
  print(''.isNotEmpty);
  print('abc'.isNotEmpty);

  // List receivers.
  print(<int>[].isNotEmpty);
  print(<int>[1, 2].isNotEmpty);

  // Map receivers.
  print(<String, int>{}.isNotEmpty);
  print(<String, int>{'a': 1}.isNotEmpty);

  // Set receivers.
  print(<int>{}.isNotEmpty);
  print(<int>{7}.isNotEmpty);

  // Through a plain identifier, which the analyzer parses as a
  // PrefixedIdentifier rather than a PropertyAccess — a separate encoder route.
  final empty = '';
  final items = <int>[3];
  print(empty.isNotEmpty);
  print(items.isNotEmpty);

  // Both members side by side, so a target that answered one with the other
  // would disagree with the golden.
  print(items.isEmpty);
  print(items.isNotEmpty);
}
