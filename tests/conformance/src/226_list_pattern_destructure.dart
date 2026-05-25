String describe(List<int> xs) {
  switch (xs) {
    case []:
      return 'empty';
    case [var x]:
      return 'single:$x';
    case [var a, var b]:
      return 'pair:$a,$b';
    default:
      return 'many:${xs.length}';
  }
}

void main() {
  print(describe([]));
  print(describe([7]));
  print(describe([1, 2]));
  print(describe([1, 2, 3, 4]));
}
