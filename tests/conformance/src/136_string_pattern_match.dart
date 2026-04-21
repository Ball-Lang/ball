List<int> bruteForceSearch(String text, String pattern) {
  List<int> positions = [];
  int n = text.length;
  int m = pattern.length;
  for (int i = 0; i <= n - m; i++) {
    bool match = true;
    for (int j = 0; j < m; j++) {
      if (text[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      positions.add(i);
    }
  }
  return positions;
}

void main() {
  print(bruteForceSearch('AABAACAADAABAABA', 'AABA'));
  print(bruteForceSearch('hello world hello', 'hello'));
  print(bruteForceSearch('abcdef', 'xyz'));
  print(bruteForceSearch('aaaaaa', 'aa'));
}
