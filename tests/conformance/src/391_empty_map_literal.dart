// A declared `Map<K, V> m = {}` with EMPTY braces must be a Map on every
// engine — including the C++ direct-compile path, which has no runtime
// set->map coercion. Regression guard for issues #174 / #184: an empty `{}`
// was previously encoded unconditionally as `set_create`, so a directly
// compiled `Map<int,int> m = {}` was constructed as the portable set value
// `{'__ball_set__': []}` and every subsequent map operation was corrupted.
void main() {
  Map<int, int> m = {};
  m[1] = 10;
  m[2] = 20;
  m[1] = 11; // overwrite, not a second key
  print(m.length);
  print(m[1]);
  print(m.containsKey(2));
  print(m.containsKey(3));
  print(m is Map);
  print(m is Set);
  print(m);
}
