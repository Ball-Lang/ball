void main() {
  final nan = 0.0 / 0.0;
  final alsoNan = nan * 0.0;
  print(nan.isNaN);
  print(alsoNan.isNaN);
  print(nan == nan);
  print(nan.toString());
  print((nan + 1.0).isNaN);
  print((nan * 0.0).isNaN);
}
