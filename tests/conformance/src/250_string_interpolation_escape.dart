void main() {
  final name = 'world';
  final escaped = 'line1\nline2\t$name';
  final hex = '0x10';
  final unicode = 'u=\u{2764}';

  print(escaped);
  print(hex);
  print(unicode);
  print('$name\\backslash');
  print('${'nested'}');
}
