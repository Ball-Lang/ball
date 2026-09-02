// #494 (Bug A) / the arity subset of #488: the Dart encoder dispatched a
// method call on the method NAME alone, so a user-defined method whose name
// collides with a std/String/collection base function was rerouted into that
// base function even when the call could not possibly satisfy its operands.
//
// The worst shape is a ZERO-argument call: `splitter.split()` (real file,
// dart-lang/async lib/src/stream_splitter.dart) became
// `std.string_split(value: <target>)` with no `separator` at all, and the Dart
// compiler's `_methodCall2` then emitted the literal placeholder
// `/* invalid split() */` into an expression position — Dart that does not
// parse.
//
// No fixture in the corpus declared a class with a method whose name matches a
// route at a DIFFERENT arity, and `check_encoder_completeness.dart` is
// name-granular (an ordinary `"a,b".split(",")` already marks `string_split`
// covered), so nothing caught it. This fixture pins both halves: the
// user-defined collisions must reach the user's methods, and the genuine
// String/List/num calls must keep their std routes.
class Bag {
  final List<int> items;

  Bag(this.items);

  // Zero-arg methods colliding with routes that require at least one argument.
  List<int> split() => items;

  int indexOf() => items.length;

  bool startsWith() => items.isNotEmpty;

  String substring() => 'whole';

  // Too FEW arguments for a two-argument route.
  int clamp(int only) => only * 10;

  int putIfAbsent(String key) => key.length;

  // Too MANY arguments for a zero-argument route.
  int toInt(int a, int b) => a + b;

  List<int> toList(int a, int b) => [a, b];
}

void main() {
  final bag = Bag([4, 5, 6]);

  // User-defined methods: must reach Bag, not a std base function.
  print(bag.split());
  print(bag.indexOf());
  print(bag.startsWith());
  print(bag.substring());
  print(bag.clamp(7));
  print(bag.putIfAbsent('abcd'));
  print(bag.toInt(2, 3));
  print(bag.toList(8, 9));

  // The genuine std routes must be unaffected.
  print('a,b,c'.split(','));
  print([10, 20, 30].indexOf(20));
  print('abc'.startsWith('a'));
  print('abcdef'.substring(1, 3));
  print(5.clamp(1, 3));
  print(2.7.toInt());
  print([1, 2].toList());
}
