Iterable<int> upTo(int limit) sync* {
  for (int i = 1; i <= 10; i = i + 1) {
    if (i > limit) {
      return;
    }
    yield i;
  }
}

void main() {
  for (var v in upTo(2)) {
    print(v);
  }
}
