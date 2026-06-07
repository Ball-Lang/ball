int Function(int) compose(int Function(int) f, int Function(int) g) {
  return (int x) => f(g(x));
}

void main() {
  final inc = (int x) => x + 1;
  final dbl = (int x) => x * 2;
  final incThenDouble = compose(dbl, inc);
  final doubleThenInc = compose(inc, dbl);
  print(incThenDouble(3).toString()); // (3+1)*2 = 8
  print(doubleThenInc(3).toString()); // 3*2+1 = 7
}
