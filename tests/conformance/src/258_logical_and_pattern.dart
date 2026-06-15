String describe(Object? value) {
  return switch (value) {
    int n && > 0 => 'pos-int:$n',
    int n && < 0 => 'neg-int:$n',
    String s => 'str:$s',
    _ => 'other',
  };
}

void main() {
  print(describe(42));
  print(describe(-7));
  print(describe('hello'));
  print(describe(3.14));
}
