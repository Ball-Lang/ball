void main() {
  final posZero = 0.0;
  final negZero = -0.0;
  print(1.0 / posZero);
  print(1.0 / negZero);
  print(negZero.toString());
  print((1.0 / negZero) > 0);
  print((1.0 / posZero) > 0);
  print((1.0 / negZero) == (1.0 / posZero));
}
