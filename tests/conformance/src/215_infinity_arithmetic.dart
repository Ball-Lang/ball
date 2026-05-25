void main() {
  final inf = 1.0 / 0.0;
  final negInf = -1.0 / 0.0;
  print(inf.isInfinite);
  print(negInf.isInfinite);
  print((inf + inf).isInfinite);
  print((inf * 0.0).isNaN);
  print((1.0 / 0.0).isInfinite);
  print((-1.0 / 0.0).isInfinite);
  print(inf.isFinite);
  print(negInf.isFinite);
}
