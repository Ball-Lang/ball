// #489 - the universal `std.type_of` base function.
//
// `ts/encoder` has always emitted `std.type_of` for JavaScript's `typeof`, but
// no compiler or engine in ANY target implemented it: compiling that call threw
// "std.type_of is not implemented". The corpus could never have caught it,
// because conformance fixtures are generated from DART, and Dart has no
// `typeof` - the nearest idiom, `<expr>.runtimeType.toString()`, was wired to
// nothing. This fixture closes that loop: the Dart encoder now maps that exact
// chain to `std.type_of`, so a fixture for it can exist at all.
//
// SEMANTICS. `type_of` returns the same discrimination `std.is` already
// performs, as a string: the canonical BASE type name, with generic type
// arguments dropped and any module prefix stripped. It deliberately does NOT
// promise generic fidelity, and it normalises Dart's private collection
// implementation classes:
//
//     [1, 2]          native Dart: List<int>            type_of: List
//     {'a': 1}        native Dart: _Map<String, int>    type_of: Map
//     {1, 2}          native Dart: _Set<int>            type_of: Set
//
// `baseName` below performs exactly that normalisation, so this fixture's
// golden - which, like every other fixture's, is the real `dart run` output -
// is a value every one of the seven targets can reproduce without needing real
// generic tracking. Scalars, `null` and user classes need no normalisation at
// all and are printed raw, pinning the vocabulary exactly.

class Widget {
  int size = 1;
}

/// Drops a generic type-argument suffix and Dart's leading `_` on a private
/// implementation class, turning `List<int>` / `_Map<String, int>` into the
/// `List` / `Map` vocabulary `std.type_of` is specified to return.
String baseName(String typeName) {
  String name = typeName;
  int angle = name.indexOf('<');
  if (angle >= 0) {
    name = name.substring(0, angle);
  }
  if (name.startsWith('_')) {
    name = name.substring(1);
  }
  return name;
}

void main() {
  // Scalars - printed raw, no normalisation needed.
  print(5.runtimeType.toString());
  print(3.5.runtimeType.toString());
  print('hi'.runtimeType.toString());
  print(true.runtimeType.toString());

  // Null, both as a literal-typed local and through a nullable binding.
  final Object? nothing = null;
  print(nothing.runtimeType.toString());

  // Collections - normalised, because native Dart reports generic/private
  // implementation names that no target can reproduce.
  final numbers = [1, 2, 3];
  print(baseName(numbers.runtimeType.toString()));

  final lookup = {'a': 1};
  print(baseName(lookup.runtimeType.toString()));

  final unique = {1, 2};
  print(baseName(unique.runtimeType.toString()));

  // A user class reports its own short name.
  final widget = Widget();
  print(widget.runtimeType.toString());

  // The chain composes like any other expression.
  final label = 'kind=' + 7.runtimeType.toString();
  print(label);

  // Same value, two different static contexts - the answer is the runtime
  // type, never the declared one.
  final Object boxed = 'text';
  print(boxed.runtimeType.toString());
}
