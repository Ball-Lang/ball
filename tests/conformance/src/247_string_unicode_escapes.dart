void main() {
  final smile = '\u{1F600}';
  final acute = 'e\u0301';
  final quote = 'say \"hi\"';
  final backslash = 'one\\two';
  final newline = 'a\nb';
  final tab = 'a\tb';

  print(smile);
  print(acute.length);
  print(acute == '\u00e9');
  print(quote);
  print(backslash);
  print(newline);
  print(tab);
}
