void main() {
  List<int> nums = [5, 2, 8, 1, 9, 3];
  nums.sort((a, b) => a.compareTo(b));
  print('Ascending: $nums');

  nums.sort((a, b) => b.compareTo(a));
  print('Descending: $nums');

  List<String> words = ['banana', 'apple', 'cherry', 'date'];
  words.sort((a, b) => a.length.compareTo(b.length));
  print('By length: $words');

  words.sort((a, b) => a.compareTo(b));
  print('Alphabetical: $words');
}
