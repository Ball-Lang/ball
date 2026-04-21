int Function(int) adder(int a) {
  return (int b) => a + b;
}

int Function(int) multiplier(int factor) {
  return (int x) => factor * x;
}

int Function(int) compose(int Function(int) f, int Function(int) g) {
  return (int x) => f(g(x));
}

void main() {
  var add5 = adder(5);
  print(add5(3));
  print(add5(10));

  var triple = multiplier(3);
  print(triple(4));
  print(triple(7));

  var tripleAndAdd5 = compose(add5, triple);
  print(tripleAndAdd5(2));
  print(tripleAndAdd5(4));

  var add5AndTriple = compose(triple, add5);
  print(add5AndTriple(2));
  print(add5AndTriple(4));
}
