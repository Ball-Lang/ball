Iterable<int> evenSquares(int limit) sync* {
  for (int i = 0; i < limit; i = i + 1) {
    if (i % 2 == 0) {
      yield i * i;
    }
  }
}

void main() {
  var result = <int>[];
  for (var v in evenSquares(8)) {
    result.add(v);
  }
  print(result.join(' '));
  print('count=' + result.length.toString());
}
