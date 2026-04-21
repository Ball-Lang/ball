int countChar(String s, String c) {
  int count = 0;
  for (int i = 0; i < s.length; i++) {
    if (s[i] == c) count++;
  }
  return count;
}

void main() {
  print(countChar('hello world', 'l'));
  print(countChar('banana', 'a'));
  print(countChar('mississippi', 's'));
  print(countChar('abc', 'z'));
}
