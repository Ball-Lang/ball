String kind(Object? value) {
  switch (value) {
    case int n:
      return (n % 2 == 0) ? 'even-int:$n' : 'odd-int:$n';
    case String s:
      return s.isEmpty ? 'empty-str' : 'str:$s';
    case bool b:
      return 'bool:$b';
    default:
      return 'other';
  }
}

void main() {
  print(kind(4));
  print(kind(5));
  print(kind(''));
  print(kind('hi'));
  print(kind(true));
  print(kind(3.14));
}
