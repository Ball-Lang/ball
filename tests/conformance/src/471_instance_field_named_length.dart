// #681: an instance field NAMED like a Dart built-in accessor must read back as
// that field's own value — never as the collection emulation of the same name.
//
// A Ball instance and a Ball map are both plain objects at runtime on several
// targets, so every engine has to answer `obj.length` from the instance's own
// field before it falls back to the Map/Object `length` emulation. The TS
// self-hosted engine did not: `Holder(3).length` came back as the instance's
// KEY COUNT (`1`), silently, while the very same object's `toString` printed
// `{length: 3}`.
//
// 439_unrelated_field_name_collision is the closest relative — it proves a user
// field must not be answered by another class's accessor — but its field is
// `x`, so it never meets a BUILT-IN name. `length` is the one that was wrong;
// `keys`, `values` and `entries` sit behind the same emulated-accessor family
// and are pinned beside it as the controls that were already right.
//
// The second half is the other control: the emulation must still answer for
// REAL collections — a list, a string and a map.
//
// Two neighbouring shapes are deliberately NOT here because they are broken on
// every target, not just TS, so they belong to their own issue (#697): an
// instance field named `isEmpty` (the encoder routes any `.isEmpty` to
// `std.string_is_empty` without consulting the receiver's type), and `.length`
// on a map that carries a `'length'` KEY (every engine returns the key's value
// instead of the entry count).

class Holder {
  int length;

  Holder(this.length);

  // The unqualified read inside the class is a separate dispatch site from the
  // external `h.length`, so it is measured too.
  int viaThis() {
    return length;
  }
}

class BuiltinNames {
  int keys;
  int values;
  int entries;

  BuiltinNames(this.keys, this.values, this.entries);
}

void main() {
  Holder h = Holder(3);
  print(h.length);
  print(h.viaThis());

  h.length = 5;
  print(h.length);
  print(h.viaThis());

  BuiltinNames b = BuiltinNames(11, 22, 33);
  print(b.keys);
  print(b.values);
  print(b.entries);

  // Controls: the emulated accessors still answer for real collections.
  List<int> list = [10, 20, 30];
  print(list.length);
  print(list.isEmpty);

  String s = 'abcd';
  print(s.length);

  Map<String, int> m = {'a': 1, 'b': 2};
  print(m.length);
  print(m.keys.length);
  print(m.isEmpty);
}
