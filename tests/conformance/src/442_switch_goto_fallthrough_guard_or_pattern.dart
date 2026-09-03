// Coverage fixture for issue #63 (epic #59): the `continue <label>` switch is
// lowered by the C++ compiler through CppCompiler::compile_switch_goto_statement
// (cpp/compiler/src/compiler.cpp), a code path 400_switch_continue_label only
// enters along its simplest spine — one labelled case per arm, every case with a
// body, no guards, no or-patterns, no wildcard.
//
// This fixture drives the four residual arms of that lowering in one program:
//   * an EMPTY fall-through case (`case 1:` with no statements before
//     `case 2:`), whose pattern is carried forward into the next real arm's
//     match condition (the `pending_patterns` path);
//   * a `when` GUARD, which is AND-ed into the arm condition so a false guard
//     falls through to later arms instead of matching;
//   * an OR-PATTERN case (`case 4 || 5:`), collected into a disjunction;
//   * a WILDCARD case (`case _:`), which the lowering treats as the default arm.
//
// Every arm is also reachable by `continue <label>`, so the goto edges and the
// ordinary subject-match edges are both exercised. Behaviour is Dart's: a
// `continue <label>` jumps straight into that case's body with NO subject
// re-check (so the guard on `guarded:` is skipped when entered by goto), and
// then falls onward per normal switch rules.

String walk(int start) {
  final buf = <String>[];
  switch (start) {
    case 0:
      buf.add('zero');
      continue shared;
    case 1:
    shared:
    case 2:
      buf.add('shared');
      continue guarded;
    guarded:
    case 3 when start > 90:
      buf.add('guarded');
      continue ored;
    ored:
    case 4 || 5:
      buf.add('ored');
      break;
    case _:
      buf.add('wild');
  }
  return buf.join(',');
}

void main() {
  print(walk(0)); // zero,shared,guarded,ored — three goto hops
  print(walk(1)); // shared,guarded,ored — empty case 1 falls through
  print(walk(2)); // shared,guarded,ored — enters case 2 directly
  print(walk(3)); // wild — the `when` guard is false
  print(walk(4)); // ored — or-pattern, left alternative
  print(walk(5)); // ored — or-pattern, right alternative
  print(walk(9)); // wild — the wildcard case acts as default
}
