void main() {
  final surrogate = '\uD800\uDC00';
  final astral = '\u{1F30E}';
  final zwjSeq = 'A\u200dB';

  print(surrogate.length);
  print(astral);
  print(astral.length);
  print(zwjSeq.length);
  print(surrogate.codeUnitAt(0));
  print(surrogate.codeUnitAt(1));
  print(astral.codeUnitAt(0));
}
