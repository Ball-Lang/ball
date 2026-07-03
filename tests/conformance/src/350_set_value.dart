// Ordered-set value (issue #68). A set literal must render Dart-exactly as
// `{a, b, c}` — not `[a, b, c]` — and support membership, insertion (add),
// insertion-ordered iteration, size, the algebraic set operations, and the
// runtime `is Set` type test, on every self-host. The engine represents a set
// portably (a one-key `{'__ball_set__': [...]}` map on the Dart/C++ engines,
// native `Set` on the TS self-host) so `print({set})` renders `{...}` instead
// of collapsing to a list.
void main() {
  // Literal print + insertion order + de-duplication.
  print({1, 2, 3});
  print({3, 1, 2, 1, 3});
  print({'alice', 'bob', 'alice'});

  // Membership.
  final s = {1, 2, 3};
  print(s.contains(2));
  print(s.contains(9));

  // Add (returns the mutated set, still a set).
  final g = {1, 2, 3};
  g.add(4);
  g.add(2); // duplicate — no-op
  print(g);
  print(g.length);

  // Size / emptiness.
  print({10, 20, 30}.length);
  print(<int>{}.isEmpty);
  print({1}.isNotEmpty);
  print(<int>{});

  // Algebraic operations (print via sorted list to keep the assertion stable).
  final a = {1, 2, 3, 4, 5};
  final b = {4, 5, 6, 7};
  print(a.union(b));
  print(a.intersection(b));
  print(a.difference(b));

  // Insertion-ordered iteration.
  for (final x in {100, 200, 300}) {
    print(x);
  }

  // Runtime type test — a set is a Set, not a List or Map.
  print(a is Set);
  print(a is List);
  print(a is Map);

  // toList preserves insertion order.
  print({7, 8, 9}.toList());

  // Sets nested inside a list and a map render recursively.
  print([
    {1, 2},
    {3, 4},
  ]);
  print({
    'evens': {2, 4},
    'odds': {1, 3},
  });
}
