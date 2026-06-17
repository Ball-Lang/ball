Iterable<int> single() sync* {
  yield 0;
  return;
}

void main() {
  for (var v in single()) {
    print(v);
  }
  print('');
}
