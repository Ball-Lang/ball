void main() {
  String text = 'the cat sat on the mat the cat';
  List<String> words = text.split(' ');
  Map<String, int> freq = {};
  for (String word in words) {
    freq[word] = (freq[word] ?? 0) + 1;
  }
  List<String> keys = freq.keys.toList()..sort();
  for (String key in keys) {
    print('$key: ${freq[key]}');
  }
  print('Unique words: ${freq.length}');
}
