// #202: `.values` on a real Map must return the values list (so `.toList()`
// gives [1, 2]); `.values` on a non-Map must FAIL LOUD (throw). The C++ direct
// compiler's BallDyn::values() overload returned null for a real Map (wrong
// answer on valid input) and silently null for a non-Map (missing fail-loud).
String tryValues(dynamic x) {
  try {
    return 'ok:${x.values.toList()}';
  } catch (e) {
    return 'threw';
  }
}

void main() {
  final Map<String, int> m = {'a': 1, 'b': 2};
  print(m.values.toList()); // real Map → [1, 2]
  print(tryValues(42)); // int is not a Map → threw
  print(tryValues('hi')); // String is not a Map → threw
}
