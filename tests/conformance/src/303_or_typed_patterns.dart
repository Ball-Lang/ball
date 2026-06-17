String classify(Object? v) {
  switch (v) {
    case int _ || String _:
      return 'intOrStr';
    case bool _ || double _:
      return 'boolOrDouble';
    default:
      return 'other';
  }
}

void main() {
  print(classify(42));
  print(classify('hi'));
  print(classify(true));
  print(classify(3.14));
  print(classify([1, 2]));
}
