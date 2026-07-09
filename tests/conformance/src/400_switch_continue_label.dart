// #321: `continue <label>` targeting a labelled switch case is a goto — Dart
// transfers control to that labelled case's body with NO subject re-check, then
// falls onward per normal switch rules. The tree-walking engine previously let
// the `continue <label>` FlowSignal escape the switch (empty / garbage output).
// Encoded via the DartEncoder's case-label preservation (#320) and executed on
// every self-hosted engine.

String walk(int start) {
  final buf = <String>[];
  switch (start) {
    case 0:
      buf.add('zero');
      continue one;
    one:
    case 1:
      buf.add('one');
      continue two;
    two:
    case 2:
      buf.add('two');
      break;
    default:
      buf.add('other');
  }
  return buf.join(',');
}

void main() {
  print(walk(0)); // zero,one,two — goto one, goto two
  print(walk(1)); // one,two       — enter at label one, goto two
  print(walk(2)); // two           — enter at case 2, break
  print(walk(9)); // other         — no case, default
}
