String safeDivide(int a, int b) {
  if (b == 0) throw 'DivisionByZero';
  return (a ~/ b).toString();
}

void main() {
  try {
    print(safeDivide(10, 2));
    print(safeDivide(7, 0));
  } catch (e) {
    print('Caught: $e');
  }
  try {
    print(safeDivide(100, 3));
  } catch (e) {
    print('Should not catch');
  }
  print('done');
}
