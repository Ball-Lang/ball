// An UNTYPED `var x = {}` is a `Map<dynamic, dynamic>` in Dart — an empty
// braces literal with no declared Set type defaults to Map. The encoder must
// match the `dart run` oracle here (issues #174 / #184): before the fix it
// emitted `set_create`, so `var x = {}` behaved as a set on the compiled-C++
// path. It must now support map insertion, key lookup, and Dart-style map
// printing.
void main() {
  var x = {};
  x['a'] = 1;
  x['b'] = 2;
  print(x.length);
  print(x['a']);
  print(x.containsKey('b'));
  print(x is Map);
  print(x is Set);
  print(x);
}
