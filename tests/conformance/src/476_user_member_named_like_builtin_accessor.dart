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
//
// The `this.` / `super.` halves are the follow-up: those two receivers are the
// ones whose type is TRIVIALLY provable - the enclosing declaration, and its
// `extends` clause - yet the first cut of the seam consulted neither, so
// `this.isEmpty` inside the very class that declares `isEmpty` still encoded as
// `std.string_is_empty(self)`. The inherited-field reads below are the same
// family reached from the C++ COMPILER's side: its by-name shortcut proves an
// inherited GETTER (its getter table is flattened over the chain) but had no
// chain walk for an inherited plain data FIELD, so `child.isNaN` compiled to
// `ball_isNaN(child)` - "is this OBJECT a NaN double", always false - instead
// of reading the member.
//
// The inherited reads below use the NUMERIC family deliberately. The COLLECTION
// family (`isEmpty` / `isNotEmpty` / `length`) has a THIRD, separate defect when
// inherited - it reads back `null` on the `C++ Compiled` row while every other
// engine row answers correctly, and while the emitted access correctly names the
// member - so those lines would pin a known-red behaviour rather than a fixed
// one. They are tracked by issue #800, whose body carries the exact removed
// lines and the measured diff; restoring them here and regenerating is the whole
// reproduction. The by-NAME encoder routing that this fixture exists for is
// covered for all ten names, `isEmpty` included, through the OWN-field `this.`
// reads above and by the per-name matrix in
// `dart/encoder/test/builtin_accessor_user_member_test.dart`.

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

// `this.<accessor>` reads the enclosing declaration's own member; `super.` reads
// the superclass this unit also declares. Both are plain data fields here, so
// neither a getter table nor a shadowed-field table can stand in for the proof.
class Counted {
  int isEmpty;
  bool isNaN;

  Counted(this.isEmpty, this.isNaN);

  int readIsEmptyViaThis() => this.isEmpty;

  bool readIsNaNViaThis() => this.isNaN;
}

class CountedChild extends Counted {
  CountedChild(int e, bool n) : super(e, n);

  bool readIsNaNViaSuper() => super.isNaN;

  // The inherited member through the implicit receiver: `this` names this
  // class, and the declaration is one link up the chain.
  bool readIsNaNViaThisInherited() => this.isNaN;
}

void main() {
  // Direct instance-creation receiver.
  print(
    BuiltinNames(44, 'user', 1.5, true, false, true, 'abc', true, false, <int>[
      1,
      2,
    ]).isEmpty,
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

  // `this.` and `super.` receivers, and the same member reached through a
  // SUBCLASS instance — the shape the C++ compiler's own by-name shortcut
  // could not prove, because an inherited plain field is in neither its
  // own-field table nor its (chain-flattened) getter table.
  var counted = Counted(3, true);
  print(counted.readIsEmptyViaThis());
  print(counted.readIsNaNViaThis());
  var child = CountedChild(5, false);
  print(child.readIsNaNViaSuper());
  print(child.readIsNaNViaThisInherited());
  CountedChild inherited = CountedChild(6, true);
  print(inherited.isNaN);

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
