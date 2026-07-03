// Regression for issue #178: a Ball Set must NOT match a MapPattern in a
// `switch`. The portable Set value is `{'__ball_set__': [...]}` — a real
// one-key map — so a naive map type-gate (ball_is_map_dyn / _stdAsMap) wrongly
// accepts it. Dart forbids the empty map pattern `case {}:`, and a normal key
// can never collide with a Set's single marker key, so the reachable
// manifestation is a pattern keyed on the marker. Real Dart never matches a map
// pattern against a Set (a Set is not a Map), so it falls through to the next
// case / default.
String classify(Object x) {
  switch (x) {
    case {'__ball_set__': final items}:
      // Reachable ONLY if the engine/compiler wrongly treats a Set as a map.
      return 'as-map:$items';
    case {'k': final v}:
      return 'map-k:$v';
    default:
      return 'other';
  }
}

void main() {
  final Object aSet = {10, 20, 30};
  final Object aMap = {'k': 7};
  final Object otherMap = {'z': 1};
  print(classify(aSet)); // a Set matches no map pattern
  print(classify(aMap)); // a real map matches
  print(classify(otherMap));
}
