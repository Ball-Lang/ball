// #651: a non-nullable `final` field that ONLY the constructor's own
// initializer list assigns, declared next to a user-written setter of the same
// name. This is the shape `collection`'s `ListSlice` uses (`final int length;`
// + `ListSlice(...) : length = end - start` + `set length(...) => throw`), and
// it is legal Dart exactly because a plain `final` field contributes a getter
// and NOTHING else.
//
// It is a compiler-lowering fixture, not a new language construct: every engine
// already runs it, and the Dart COMPILER is the leg it pins. The compiler used
// to decide "`late` is needed" from the field declaration alone — a
// non-nullable field with no inline initializer was assumed to be written in
// some constructor BODY — so it emitted `late final int length;`. A `late final`
// field is assignable after construction, so it contributes an implicit SETTER
// too, and that setter collides with the one declared here:
//
//   ERROR|COMPILE_TIME_ERROR|DUPLICATE_DEFINITION|...|The name 'length' is
//   already defined.
//
// The initializer list is the IR evidence that the field is definitely assigned
// at construction, so no `late` is needed and no implicit setter is created.
// `dart-compiled` is therefore the leg that sees this fixture's point: the
// compiled program has to be Dart the analyzer accepts before `dart run` can
// execute it at all.
//
// The setter is declared, never called: writing through it is a SEPARATE,
// tracked engine-dispatch gap (#664 — the engine suppresses setter dispatch
// whenever the instance carries a field of that name, which is right for a
// non-final shadowing field and wrong for a final one). Conformance fixtures
// 104/341/432 already exercise live setter dispatch; this one exists for the
// declaration shape.
//
// `elementAt` keeps the second, initializing-formal-assigned field live, so
// both "definitely assigned" shapes the compiler now recognises are exercised
// in one class.
class FixedSlice {
  final List<int> source;
  final int length;

  FixedSlice(this.source, int end) : length = end;

  set length(int newLength) {
    throw UnsupportedError('Cannot resize a FixedSlice');
  }

  int elementAt(int index) {
    return source[index];
  }
}

void main() {
  final slice = FixedSlice([10, 20, 30], 3);
  print(slice.length);
  print(slice.elementAt(1));
  print(slice.source.length);
}
