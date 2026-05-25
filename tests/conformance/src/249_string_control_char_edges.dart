void main() {
  final nul = '\x00';
  final bell = '\x07';
  final cr = '\r';
  final lf = '\n';
  final mixed = 'a\x00b\x07c';

  print(nul.isEmpty);
  print(nul.length);
  print(bell.codeUnitAt(0));
  print('$cr|$lf|');
  print(mixed.length);
  print(mixed.replaceAll('\x00', '_'));
}
