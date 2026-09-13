// `Map.putIfAbsent` — routed to `std_collections.map_put_if_absent` by the
// encoder's `collectionRoutes` table, and, like `map_contains_value`, never
// executed by any fixture because the completeness gate could not see a
// base-function name that lives in a map VALUE rather than a string literal at
// the emit site (issue #488).
//
// The contract has two halves that a wrong implementation can each break: the
// RETURNED value (the existing one when the key is present, the new one when
// it is not) and the SIDE EFFECT on the map.

void main() {
  final counts = <String, int>{'ada': 1};

  // Key present: returns the existing value, map unchanged.
  print(counts.putIfAbsent('ada', () => 99));
  print(counts['ada']);
  print(counts.length);

  // Key absent: returns the new value and inserts it.
  print(counts.putIfAbsent('bob', () => 7));
  print(counts['bob']);
  print(counts.length);

  // Inserting into an empty map.
  final fresh = <String, String>{};
  print(fresh.putIfAbsent('k', () => 'v'));
  print(fresh['k']);

  // A second call on the now-present key returns the FIRST value.
  print(fresh.putIfAbsent('k', () => 'other'));
}
