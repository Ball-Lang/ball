// #197: `.keys` on a non-Map must FAIL LOUD (throw a catchable error), not
// silently yield []. In the tree-walking engines the getter path already
// throws; the C++ direct compiler lowered `.keys` to `ball_map_keys`, which
// silently returned [] for a non-Map — the silent-degradation class of bug that
// hid issue #55. A correct result throws on any non-Map receiver and returns
// the real keys for a Map. (The `.values` / BallDyn::values() compiler path is
// a separate, tracked defect — see issue #202 — so this fixture exercises only
// the `.keys` path, which is consistent across every engine.)
String tryKeys(dynamic x) {
  try {
    return 'ok:${x.keys.toList()}';
  } catch (e) {
    return 'threw';
  }
}

void main() {
  print(tryKeys(42)); // int is not a Map
  print(tryKeys('hi')); // String is not a Map
  print(tryKeys([1, 2, 3])); // List is not a Map
  print(tryKeys({'a': 1, 'b': 2})); // a real Map
}
