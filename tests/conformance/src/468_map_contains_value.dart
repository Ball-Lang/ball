// `Map.containsValue` — the encoder routes it to
// `std_collections.map_contains_value` through `collectionRoutes`, but no
// fixture had ever executed it: the completeness gate's "emittable" scan only
// saw base-function names written as STRING LITERALS at an emit site, and this
// one lives in a map VALUE (issue #488). The Dart compiler had no case for it
// at all, so `collection/lib/src/wrappers.dart` compiled back to
// `return /* unsupported: std_collections.map_contains_value */;`.

void main() {
  final scores = <String, int>{'ada': 10, 'bob': 20, 'cy': 30};

  print(scores.containsValue(20));
  print(scores.containsValue(99));

  // A value that is present under more than one key.
  final repeats = <String, int>{'a': 1, 'b': 1};
  print(repeats.containsValue(1));

  // An empty map contains nothing.
  final empty = <String, int>{};
  print(empty.containsValue(1));

  // String values, so the comparison is not integer-only.
  final names = <String, String>{'one': 'uno', 'two': 'dos'};
  print(names.containsValue('dos'));
  print(names.containsValue('tres'));

  // The answer drives real control flow, so a wrong result is observable.
  if (scores.containsValue(30)) {
    print('30 is present');
  } else {
    print('30 is absent');
  }
}
