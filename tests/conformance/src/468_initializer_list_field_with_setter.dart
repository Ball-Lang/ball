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
// some constructor BODY — so it emitted `late final int windowSize;`. A
// `late final` field is assignable after construction, so it contributes an
// implicit SETTER too, and that setter collides with the one declared here:
//
//   ERROR|COMPILE_TIME_ERROR|DUPLICATE_DEFINITION|...|The name 'windowSize' is
//   already defined.
//
// The initializer list is the IR evidence that the field is definitely assigned
// at construction, so no `late` is needed and no implicit setter is created.
// `dart-compiled` is the leg that sees this fixture's point: the compiled
// program has to be Dart the analyzer accepts before `dart run` can execute it
// at all, and `dart/compiler/test/field_finality_test.dart` compiles THIS file
// and runs a real `dart analyze` over the result on every PR.
//
// TWO deliberate departures from `ListSlice`, each dodging a SEPARATE tracked
// bug rather than this issue's mechanism (the collision itself is
// name-independent, so neither weakens what this fixture pins):
//
//  * the field is `windowSize`, not `length` — on the TS self-hosted engine an
//    instance field NAMED `length` reads back as the object's key count
//    instead of its own value (#681, open). #665 is a CI PR, not that bug;
//    the collision this fixture pins is name-independent either way;
//  * the setter is declared, never called — the ENGINE used to suppress the
//    write whenever the instance carried a field of that name, which is right
//    for a non-final shadowing field and wrong for a final one (#664, closed
//    by #680 after this fixture was written). Live setter dispatch over this
//    exact declaration pair is pinned by 470_setter_beside_final_field;
//    fixtures 104/341/432 cover the other setter shapes. Keeping the write
//    out of THIS fixture is deliberate: what it pins is the Dart COMPILER's
//    `late` decision and nothing else.
//
// A THIRD target gap this shape exposes is #695, and it is the one departure
// that could NOT be designed around: C++ has a single member namespace, so the
// emitted data member and the emitted setter collide and the program does not
// build. That is the Ball -> C++ COMPILER, not this fixture — every engine,
// including the C++ self-hosted one, runs this program correctly — so the
// compiled C++ leg carves it out loudly (`CPP_COMPILE_CARVEOUTS` in
// cpp/test/full_e2e.sh, plus cpp/test/e2e_fixture_list_known_gaps.txt) until
// #695 lands. Do not rename or reshape this class to dodge that: the field and
// its same-named setter ARE the point.
//
// The remaining four COMPILER targets do not handle this shape either, with at
// least three different mechanisms, and that is #706: Rust and Go build and RUN
// the program and then read `windowSize` back as `null` (the emitted setter
// shadows the field read — a silent wrong answer, strictly worse than C++'s
// build failure); Python rejects it loudly at compile time ("setter without
// matching getter"); C# fails too. All four legs are RATCHETED — they fail only
// on a DROP — so they are green with this fixture failing, and they will stay
// green when it is fixed. Read the per-fixture line, never the leg's colour.
//
// `elementAt` keeps the second, initializing-formal-assigned field live, so
// both "definitely assigned" shapes the compiler now recognises are exercised
// in one class.
class FixedSlice {
  final List<int> source;
  final int windowSize;

  FixedSlice(this.source, int end) : windowSize = end;

  set windowSize(int newSize) {
    throw UnsupportedError('Cannot resize a FixedSlice');
  }

  int elementAt(int index) {
    return source[index];
  }
}

void main() {
  final slice = FixedSlice([10, 20, 30], 3);
  print(slice.windowSize);
  print(slice.elementAt(1));
  print(slice.source.length);
}
