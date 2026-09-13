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
// Three neighbouring shapes are deliberately NOT here. Each belongs to its own
// issue (#697), and each has a DIFFERENT measured failure set — two are broader
// than the two targets above, one is narrower:
//
//   * an instance field named `isEmpty` / `isNotEmpty` (#697 section A) is wrong
//     on EVERY target, the Dart reference engine included: the Dart encoder
//     rewrites any `.isEmpty` into a `std.string_is_empty` call without
//     consulting the receiver's type, so every engine faithfully runs the same
//     wrong program. An encoder bug, in #488's receiver-type family.
//   * `.length` on a MAP that carries a `'length'` KEY (#697 section B) is
//     likewise wrong on every engine — `engine_eval.dart` answers the key
//     instead of the entry count. That is THIS fixture's precedence rule read at
//     the opposite site and in the opposite direction: an instance's own field
//     must beat the emulation, a map's key must not.
//   * instance fields named `keys` / `values` / `entries` (#697 section C) read
//     back CORRECTLY on the Dart reference engine and on every self-hosted
//     engine row — they are wrong on the `C++ Compiled` leg SPECIFICALLY, which
//     is one of the two targets this fixture pins. Measured on this branch's
//     first Conformance Matrix run (34768683903), where an earlier draft of this
//     fixture still carried them: `C++ Compiled` alone reported
//     `Results: 351 passed, 1 failed, 352 total` while `Dart Engine` and the
//     Rust / C# / Go / Python rows all passed. `cpp/compiler/src/compiler.cpp`
//     still emits `.keys` / `.entries` / `.values` unconditionally at this head:
//     #681's fix teaches that block the receiver-scoped proof for `length` /
//     `isEmpty` / `isNotEmpty` only, the three names measured below. Extending
//     it needs its own fixture first, which is what #697's C-half asks for.

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
