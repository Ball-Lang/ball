int Function(int) Function(int) curryAdd() {
  return (int a) {
    return (int b) => a + b;
  };
}

int Function(int) partialApply(int Function(int, int) fn, int first) {
  return (int second) => fn(first, second);
}

int add2(int a, int b) => a + b;

void main() {
  final add10 = curryAdd()(10);
  print(add10(5));
  print(curryAdd()(3)(7));

  final add5 = partialApply(add2, 5);
  print(add5(12));
  print(partialApply(add2, 0)(0));
}
