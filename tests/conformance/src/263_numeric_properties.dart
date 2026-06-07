void main() {
  // isNaN
  double nan = 0.0 / 0.0;
  print(nan.isNaN);
  print(42.0.isNaN);

  // isInfinite
  double inf = 1.0 / 0.0;
  print(inf.isInfinite);
  print(42.0.isInfinite);

  // gcd
  print(12.gcd(8));
  print(100.gcd(75));
  print(17.gcd(13));
}
