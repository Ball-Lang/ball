String classify(List<Object?> items) {
  switch (items) {
    case [int _, String _, bool _]:
      return 'int,string,bool';
    case [_, _]:
      return 'other';
    default:
      return '';
  }
}

void main() {
  print(classify([1, 'a', true]));
  print(classify([1, 2]));
  print(classify([1, 2, 3, 4]));
}
