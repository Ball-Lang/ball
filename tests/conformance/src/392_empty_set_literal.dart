// A declared `Set<T> s = {}` with EMPTY braces must be a Set on every engine.
// This is the ONLY empty-braces form the encoder still routes to `set_create`
// (via the syntactically visible `Set<..>` declaration type) after the issues
// #174 / #184 fix defaulted bare empty `{}` to `map_create`. It must dedup on
// add, iterate in insertion order, answer `is Set`, and print Dart-style
// `{a, b, c}` (not `[a, b, c]`) on the compiled-C++ path.
void main() {
  Set<int> s = {};
  s.add(1);
  s.add(2);
  s.add(1); // duplicate — no-op
  print(s.length);
  print(s.contains(2));
  print(s.contains(9));
  print(s is Set);
  print(s is Map);
  print(s);
  for (final x in s) {
    print(x);
  }
}
