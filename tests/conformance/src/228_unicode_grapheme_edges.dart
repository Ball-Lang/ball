void main() {
  final emoji = '👨‍👩‍👧';
  print(emoji.length);

  final combining = 'e\u0301';
  print(combining.length);
  print(combining == '\u00e9');

  final empty = '';
  print(empty.isEmpty);
  print(empty.length);

  final rtl = '\u202eabc';
  print(rtl.length);
  print(rtl.substring(1, 2));
}
