List<String> tokenize(String s) {
  List<String> tokens = [];
  String current = '';
  for (int i = 0; i < s.length; i++) {
    if (s[i] == ' ') {
      if (current.isNotEmpty) {
        tokens.add(current);
        current = '';
      }
    } else {
      current += s[i];
    }
  }
  if (current.isNotEmpty) tokens.add(current);
  return tokens;
}

void main() {
  List<String> t = tokenize('hello   world  foo bar');
  print(t.length);
  for (String s in t) {
    print(s);
  }
}
