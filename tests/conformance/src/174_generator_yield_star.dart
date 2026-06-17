Iterable<int> inner() sync* {
  yield 1;
  yield 2;
  yield 3;
}

Iterable<int> outer() sync* {
  yield* inner();
}

void main() {
  for (var v in outer()) {
    print(v);
  }
}
