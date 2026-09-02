// #470: a switch EXPRESSION arm whose whole body is the bare `null` literal is
// a real arm carrying the value null — never a body-less fall-through label.
// Ball encodes `null` as a value-less Literal, which is exactly the shape the
// compilers' `isEmptySwitchBody` heuristic reads as "empty"; applied in
// expression mode (where nothing falls through) it DELETES the arm and leaks
// its condition, so a non-final `=> null` arm silently answers with a later
// arm's value. The Rust and Python compilers both did this; Go gates the
// heuristic on statement mode (go/compiler/base_call.go).
//
// `valueFor(2)` is the load-bearing case: a bare-`null` arm in a NON-last
// position with a default whose value (`'other'`) is distinguishable from null.

String describe(int? n) => switch (n) {
  null => 'was-null',
  0 => 'zero',
  _ => 'other',
};

String? valueFor(int n) => switch (n) {
  1 => 'one',
  2 => null,
  _ => 'other',
};

// A null arm in LAST position before the default: nothing follows it to absorb
// a leaked condition, so a dropped arm falls straight to the default instead.
String? tailNull(int n) => switch (n) {
  1 => 'one',
  2 => 'two',
  3 => null,
  _ => 'other',
};

void main() {
  print(describe(null));
  print(describe(0));
  print(describe(7));
  print(valueFor(1));
  print(valueFor(2) ?? '<null>');
  print(valueFor(9));
  print(tailNull(2));
  print(tailNull(3) ?? '<null>');
  print(tailNull(9));
}
