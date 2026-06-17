Iterable<int> countTo(int n) sync* {
  for (int i = 1; i <= n; i = i + 1) {
    yield i;
  }
}

void main() {
  var gen = countTo(3);
  for (var v in gen) {
    print(v);
  }
  print(gen.length);
}
