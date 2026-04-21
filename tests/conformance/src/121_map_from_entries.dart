void main() {
  List<String> words = ['apple', 'banana', 'cherry', 'date', 'elderberry'];
  Map<String, int> wordLengths = Map.fromEntries(
    words.map((w) => MapEntry(w, w.length)),
  );
  wordLengths.forEach((word, len) {
    print('$word: $len');
  });

  List<int> nums = [1, 2, 3, 4, 5];
  Map<int, int> squareMap = Map.fromEntries(
    nums.map((n) => MapEntry(n, n * n)),
  );
  squareMap.forEach((k, v) {
    print('$k -> $v');
  });
}
