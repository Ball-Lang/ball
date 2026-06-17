String describe(List<int> xs) {
  switch (xs) {
    case []:
      return 'empty';
    case [_]:
      return 'single';
    case [_, _]:
      return 'two';
    case [_, _, _]:
      return 'three';
    default:
      return 'many';
  }
}

void main() {
  print(describe([]));
  print(describe([1]));
  print(describe([1, 2]));
  print(describe([1, 2, 3]));
  print(describe([1, 2, 3, 4]));
}
