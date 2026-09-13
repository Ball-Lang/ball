// #681: an instance field NAMED `length` must read back as that field's own
// value — never as the collection emulation of the same name.
//
// A Ball instance and a Ball map are both plain objects at runtime on several
// targets, so a target has to answer `obj.length` from the instance's own field
// before it falls back to the Map/Object `length` emulation. Two did not:
//
//   * the TS self-hosted engine answered `Holder(3).length` with the instance's
//     KEY COUNT (`1`), silently, while the very same object's `toString`
//     printed `{length: 3}`;
//   * the C++ compiler emitted the unconditional shortcut `ball_length(
//     BallDyn(h))`, which is that same field count.
//
// Both were READ-side only: the write `h.length = 5` already resolved as an
// ordinary field write on every target, so this fixture reads the field before
// AND after a write to pin the two halves against each other. It also reads the
// field unqualified from inside the class, a separate dispatch site from the
// external `h.length`.
//
// 439_unrelated_field_name_collision is the closest relative — it proves a user
// field must not be answered by another class's accessor — but its field is
// `x`, so it never meets a BUILT-IN name.
//
// The tail is the control: `.length` must still answer for REAL collections — a
// list, a string and a map.
//
// Deliberately NOT here, because they are wrong on EVERY target rather than on
// these two, and so belong to their own issue (#697): an instance field named
// `isEmpty` (the Dart encoder rewrites any `.isEmpty` to `std.string_is_empty`
// without consulting the receiver's type), instance fields named `keys` /
// `values` / `entries`, and `.length` on a map that carries a `'length'` KEY
// (every engine returns the key's value instead of the entry count).

class Holder {
  int length;

  Holder(this.length);

  int viaThis() {
    return length;
  }
}

void main() {
  Holder h = Holder(3);
  print(h.length);
  print(h.viaThis());

  h.length = 5;
  print(h.length);
  print(h.viaThis());

  List<int> list = [10, 20, 30];
  print(list.length);

  String s = 'abcd';
  print(s.length);

  Map<String, int> m = {'a': 1, 'b': 2};
  print(m.length);
  print(m.keys.length);
}
