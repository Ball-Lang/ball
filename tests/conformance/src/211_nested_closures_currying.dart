Function adder(int input) {
  var a = input;
  return (int b) => (int c) => a + b + c;
}

void main() {
  final add10 = adder(10);
  final add10_20 = add10(20);
  print(add10_20(30).toString());
}
