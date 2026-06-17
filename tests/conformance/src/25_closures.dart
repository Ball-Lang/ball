int Function(int) makeAdder(int n) {
  return (int x) => n + x;
}

void main() {
  var add5 = makeAdder(5);
  print('${add5(3)}');
  print('${add5(10)}');
}
