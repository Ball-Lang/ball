// #787 — a user member named `first` / `last` / `runtimeType` / `entries` /
// `keys` / `values` wins over the C++ compiler's map/iterable emulation of the
// same name.
//
// This is the third and last slice of the family #664 opened (`length`,
// `isEmpty`, `isNotEmpty`) and #697 continued (`isNaN`, `isFinite`,
// `isInfinite`, `isNegative`): `cpp/compiler/src/compiler.cpp`'s
// `compile_field_access` carries a by-name shortcut for each of these six too,
// and those six still fired UNCONDITIONALLY — on a provable user class exactly
// as on a real Map. So a class declaring `List<int> entries` read back
// `ball_map_entries(...)` (the instance's key/value pairs), one declaring
// `String keys` read back its key list, and `.first` / `.last` compiled to
// `obj.front()` / `obj.back()` — member functions no emitted struct declares,
// so the whole program failed to BUILD rather than answering wrong.
//
// It is a `C++ Compiled` defect and NOTHING else, which is what makes this a
// fixture rather than a Dart-side change. None of the six is in the Dart
// encoder's accessor-routing tables (`_directGetterRoutes` /
// `builtinAccessorGetters` in `dart/encoder/lib/encoder.dart` — that is #697's
// family), so all six encode as plain `fieldAccess` nodes, and every ENGINE row
// resolves those own-key-first (`engine_eval.dart` answers the instance's own
// field, then its `__super__` chain, then its getters, and only then the
// virtual map properties). That asymmetry is the whole reason #681's
// `475_instance_field_named_length` could not simply carry these names: its
// first draft did (`int keys; int values; int entries;`) and failed the
// `C++ Compiled` row while every engine row passed, but that same draft also
// carried `length`, so the run could not attribute the failure to these names.
// This fixture isolates them.
//
// Both declaration shapes are here, because the compiler's fall-through
// resolves them differently: a plain DATA member takes the struct-member path,
// a GETTER takes the accessor-call path. `values` is the one asymmetric name —
// its shortcut emits a CALL (`obj.values()`), which already serves a user
// getter of that name correctly, so only the plain-field shape was ever
// mis-served. `Computed.values` below is the control that pins the getter half
// against a guard that over-reaches.
//
// `runtimeType` appears here as a GETTER only (`Computed.runtimeType`, typed
// `Type` because it OVERRIDES `Object.runtimeType` and Dart rejects a narrowing
// override outright). Its FIELD shape is carved out — see #863 below. The value
// it answers is itself a `.runtimeType` read, the very shortcut the tail of this
// fixture pins as still working for a non-user receiver.
//
// The tail is the control in the other direction: every one of the six must
// still answer for a REAL list / map / string / int, exactly as before. A fix
// that simply deleted the shortcuts would pass every read above and fail there.
//
// ── Two carve-outs, each a DIFFERENT target's defect of this same family ──
//
// **#860** — a class declaring a field named `entries` that ALSO carries a
// method takes EVERY self-hosted engine down. `engine_invocation.dart` binds an
// instance's fields into a method's scope with
// `for (final entry in selfMap.entries)`, and on a self-hosted target that
// `.entries` is resolved by NAME, own-key-first — so it reads the user's
// `List<int>` and takes `.key` off the integer `7`. The Dart reference engine is
// immune (there `selfMap` is a real `Map<String, Object?>`). So `Collected`
// declares the names and carries NO methods, while `Counted` carries the
// `this.`-readers for the names that are safe.
//
// **#863** — a class declaring a field named `runtimeType` throws on the TS
// engine at CONSTRUCTION, before a line runs: `ts/compiler/src/preamble.ts`
// installs `Object.prototype.runtimeType` as a getter with no setter (unlike
// its `defDartGetter` siblings `entries`/`keys`/`values`/`length`), so an
// engine-internal lookup table keyed by field name cannot take that key in
// strict mode. Only the FIELD shape is affected; the getter above is untouched.
//
// Both issue bodies carry the removed lines verbatim; restoring them here and
// regenerating is the whole reproduction in each case. Do not re-add them until
// those issues land.

class Collected {
  final int first;
  final String last;
  final List<int> entries;
  final String keys;
  final int values;

  Collected(this.first, this.last, this.entries, this.keys, this.values);
}

// The same members read from INSIDE the class, through `this.` — a separate
// dispatch site from the external `c.first`, and the one whose receiver is
// trivially provable. No `entries` field here: see #860 above.
//
// `Counted` and `Collected` are also the two halves of the `this.`-vs-external
// split; neither declares `runtimeType` (#863).
class Counted {
  final int first;
  final String last;
  final String keys;
  final int values;

  Counted(this.first, this.last, this.keys, this.values);

  int readFirstViaThis() => this.first;

  String readLastViaThis() => this.last;

  String readKeysViaThis() => this.keys;

  int readValuesViaThis() => this.values;
}

class Computed {
  final int stored;

  Computed(this.stored);

  int get first => stored * 2;

  int get last => stored + 1;

  @override
  Type get runtimeType => stored.runtimeType;

  List<int> get entries => <int>[stored, -stored];

  String get keys => 'k$stored';

  // The control for the narrow half of the guard: `.values` lowers to a CALL,
  // so a getter of that name was already correct and must stay correct.
  int get values => stored * 3;
}

void main() {
  // Plain data members, read through a local with an explicit type annotation.
  Collected c = Collected(11, 'tail', <int>[7, 8], 'K', 99);
  print(c.first);
  print(c.last);
  print(c.entries);
  print(c.keys);
  print(c.values);

  Counted n = Counted(31, 'inner', 'Z', 12);
  print(n.readFirstViaThis());
  print(n.readLastViaThis());
  print(n.readKeysViaThis());
  print(n.readValuesViaThis());

  // The instance-creation receiver, which needs no local at all.
  print(Collected(1, 'z', <int>[0], 'A', 2).keys);

  // User GETTERS of the same six names.
  var g = Computed(21);
  print(g.first);
  print(g.last);
  print(g.runtimeType);
  print(g.entries);
  print(g.keys);
  print(g.values);

  // Controls: the emulation must survive for every receiver that is NOT a
  // user class declaring the name.
  List<int> xs = <int>[5, 6, 7];
  print(xs.first);
  print(xs.last);

  Map<String, int> m = {'a': 1, 'b': 2};
  print(m.keys.toList());
  print(m.values.toList());
  print(m.values.first);
  print(m.values.last);
  print(m.entries.length);

  print('abc'.runtimeType);
  print(7.runtimeType);
  print(2.5.runtimeType);
}
