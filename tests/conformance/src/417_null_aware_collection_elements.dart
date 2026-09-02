// #494 (Bug B): Dart 3.8 null-aware collection elements. `[1, ?x]` / `{1, ?x}`
// parse to an `ast.NullAwareElement`, which `_encodeCollectionElement` had no
// branch for — it threw `UnsupportedError`, so any real file using them was
// unencodable. The map forms carry their `?` on the MapLiteralEntry itself
// (`keyQuestion` / `valueQuestion`); those were silently DROPPED, so
// `{?k: 20}` with a null key produced the entry `null: 20` instead of omitting
// it.
//
// Nothing caught either: `check_encoder_completeness.dart` gates base-function
// NAME coverage, and a construct that throws before producing any IR never
// becomes a name to check.
//
// The `probe` group is load-bearing: Dart evaluates a null-aware operand
// EXACTLY ONCE and short-circuits (a null key does not evaluate its value), so
// the desugaring may not simply repeat the operand in both the guard and the
// element.

List<int> listOf(int? x) => [1, 2, ?x];

Set<int> setOf(int? x) => {1, 2, ?x};

Map<int, int> mapKey(int? k) => {1: 10, ?k: 20};

Map<int, int> mapValue(int? v) => {1: 10, 2: ?v};

Map<int, int> mapBoth(int? k, int? v) => {1: 10, ?k: ?v};

List<int> nested(int? x) => [for (var i = 0; i < 2; i++) if (i == 1) ?x];

int? probe(String tag, int? v) {
  print('eval ' + tag);
  return v;
}

void main() {
  print(listOf(3));
  print(listOf(null));

  print(setOf(3));
  print(setOf(null));

  print(mapKey(2));
  print(mapKey(null));

  print(mapValue(20));
  print(mapValue(null));

  print(mapBoth(2, 20));
  print(mapBoth(null, 20));
  print(mapBoth(2, null));
  print(mapBoth(null, null));

  print(nested(7));
  print(nested(null));

  // Evaluated exactly once, left to right, short-circuiting on a null guard.
  print([1, ?probe('a', 2)]);
  print([1, ?probe('b', null)]);
  print({?probe('key1', null): probe('val1', 9)});
  print({?probe('key2', 5): probe('val2', 9)});
}
