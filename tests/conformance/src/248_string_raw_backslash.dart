void main() {
  final raw = r'path\to\file';
  final normal = 'path\\to\\file';
  final dollar = r'$not-interpolated ${still literal}';

  print(raw);
  print(normal);
  print(dollar);
  print(r'\n'.length);
  print(r'\n' == '\\n');
  print('\\'.length);
}
