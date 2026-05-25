String describe(List<int> xs) {
  switch (xs) {
    case []:
      return 'empty';
    case [var only]:
      return 'single:$only';
    case [var first, ...var rest]:
      return 'head:$first,tail:${rest.length}';
    default:
      return 'fallback';
  }
}

void main() {
  print(describe([]));
  print(describe([1]));
  print(describe([1, 2, 3, 4]));
}
