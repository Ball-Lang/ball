String typeName(Object? value) {
  switch (value) {
    case int _:
      return 'int';
    case String _:
      return 'string';
    case bool _:
      return 'bool';
    default:
      return 'other';
  }
}

void main() {
  print(typeName(42));
  print(typeName('hello'));
  print(typeName(true));
  print(typeName(3.14));
}
