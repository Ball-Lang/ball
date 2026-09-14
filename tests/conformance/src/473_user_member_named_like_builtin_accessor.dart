// #697 A - a member a USER class declares wins over the built-in accessor the
// encoder routes by name.
//
// Without type resolution the Dart encoder routed `.isEmpty` / `.isNotEmpty`
// (and the rest of its by-name getter table) straight onto a `std` base call:
// `b.isEmpty` encoded as `std.string_is_empty(b)` with no `fieldAccess` for the
// user's field anywhere in the program. So EVERY engine faithfully ran the
// wrong program and agreed on the wrong answer - a member of #488's
// receiver-type family, not of #681's precedence family.
//
// The seam is the receiver's PROVABLE type: an instance creation, or a local /
// parameter / field whose declared type is a class this unit declares that
// declares the member. Anything else keeps the routing it has always had, which
// is why the `String` / `List` / `int` / `double` halves below are here: a fix
// that simply dropped the route would break them, so they are pinned in the
// same fixture.

class BuiltinNames {
  int isEmpty;
  String isNotEmpty;
  double sign;
  bool isNaN;
  bool isFinite;
  bool isInfinite;
  String runes;
  bool isEven;
  bool isOdd;
  List<int> reversed;

  BuiltinNames(
    this.isEmpty,
    this.isNotEmpty,
    this.sign,
    this.isNaN,
    this.isFinite,
    this.isInfinite,
    this.runes,
    this.isEven,
    this.isOdd,
    this.reversed,
  );
}

class Computed {
  final int stored;

  Computed(this.stored);

  // A user GETTER named like a built-in accessor is the same shape: the
  // declaration wins, the routing does not.
  int get isEmpty => stored * 2;

  String get isNotEmpty => 'computed-$stored';
}

void main() {
  // Direct instance-creation receiver.
  print(
    BuiltinNames(
      44,
      'user',
      1.5,
      true,
      false,
      true,
      'abc',
      true,
      false,
      <int>[1, 2],
    ).isEmpty,
  );

  // Locally declared receiver with an explicit type annotation.
  BuiltinNames b = BuiltinNames(
    7,
    'kept',
    -2.5,
    true,
    false,
    true,
    'xyz',
    false,
    true,
    <int>[3, 4, 5],
  );
  print(b.isEmpty);
  print(b.isNotEmpty);
  print(b.sign);
  print(b.isNaN);
  print(b.isFinite);
  print(b.isInfinite);
  print(b.runes);
  print(b.isEven);
  print(b.isOdd);
  print(b.reversed);

  // A user getter, read through a `var` whose initializer names the class.
  var c = Computed(21);
  print(c.isEmpty);
  print(c.isNotEmpty);

  // The routing itself must survive: these receivers are NOT user classes.
  String s = '';
  String t = 'hi';
  print(s.isEmpty);
  print(t.isNotEmpty);
  List<int> xs = <int>[];
  List<int> ys = <int>[9, 8];
  print(xs.isEmpty);
  print(ys.isNotEmpty);
  print(ys.reversed.toList());
  int n = 4;
  print(n.isEven);
  print(n.isOdd);
  print(n.sign);
  double d = 2.5;
  print(d.isNaN);
  print(d.isFinite);
  print(d.isInfinite);
}
