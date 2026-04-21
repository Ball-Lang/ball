int apply(int Function(int) f, int x) {
  return f(x);
}

void main() {
  var double_ = (int x) => x * 2;
  var square = (int x) => x * x;
  print(apply(double_, 5).toString());
  print(apply(square, 5).toString());
}
