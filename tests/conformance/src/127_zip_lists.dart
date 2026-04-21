List<String> zip(List<String> a, List<int> b) {
  List<String> result = [];
  int len = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < len; i++) {
    result.add('(${a[i]}, ${b[i]})');
  }
  return result;
}

void main() {
  List<String> names = ['Alice', 'Bob', 'Charlie'];
  List<int> ages = [30, 25, 35];
  List<String> zipped = zip(names, ages);
  for (String pair in zipped) {
    print(pair);
  }

  List<String> more = ['X', 'Y', 'Z', 'W'];
  List<int> fewer = [1, 2];
  List<String> zipped2 = zip(more, fewer);
  for (String pair in zipped2) {
    print(pair);
  }
}
