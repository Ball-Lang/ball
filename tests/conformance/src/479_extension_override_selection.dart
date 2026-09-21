// Extension-override syntax — `Ext(receiver).member` (issue #670).
//
// Both extensions apply to the SAME type and declare the SAME members, so the
// override is the ONLY thing that selects which one runs: erasing it to the
// plain `xs.tag()` is ambiguous in Dart and, where a compiler resolves it by
// name anyway, silently picks the wrong member.
//
// The Ball program therefore NAMES the extension's own function
// (`<module>:<Ext>.<member>`) and carries the receiver in `self`. Every engine
// dispatches that qualified name, and every compiler must reach the member it
// names rather than asking the receiver.

extension AlphaTag on List<int> {
  String tag() => 'alpha(${this.length})';

  String get label => 'A';

  String scale(int by) => 'alpha*${by}';
}

extension BetaTag on List<int> {
  String tag() => 'beta(${this.length})';

  String get label => 'B';

  String scale(int by) => 'beta*${by}';
}

void main() {
  final xs = <int>[1, 2, 3];

  // Zero-argument method.
  print(AlphaTag(xs).tag());
  print(BetaTag(xs).tag());

  // Getter (no `()` on the way back out).
  print(AlphaTag(xs).label);
  print(BetaTag(xs).label);

  // Method with an argument — the receiver must still travel in `self`.
  print(AlphaTag(xs).scale(2));
  print(BetaTag(xs).scale(2));
}
