// Built-in primitive number getters (#106): int.isEven/isOdd and double
// isFinite/isInfinite/isNaN/sign/isNegative — on literals, variables, and
// negatives. These previously crashed (isEven/isOdd emitted as a raw
// fieldAccess; sign/isNegative threw on the engine's BallDouble wrapper) or
// returned silently-wrong values (3.14.isFinite -> false). No fixture
// exercised the built-in getters, so the whole class slipped past CI — the
// corpus only had USER functions named isEven/isOdd.
void main() {
  // int.isEven / int.isOdd — literals, variable, negatives
  print(4.isEven);
  print(5.isEven);
  print(4.isOdd);
  print(7.isOdd);
  int n = 10;
  print(n.isEven);
  print((-3).isOdd);
  print((-4).isEven);

  // double finiteness / NaN — literal (BallDouble-wrapped) and computed paths
  print(3.14.isFinite);
  print(3.14.isInfinite);
  print(3.14.isNaN);
  double d = 2.5;
  print(d.isFinite);
  print((1.0 / 0.0).isFinite);
  print((1.0 / 0.0).isInfinite);
  print((0.0 / 0.0).isNaN);

  // sign on int (double `.sign` returns a whole double like 1.0, which the TS
  // self-host still prints as `1` — tracked as #67, not this issue).
  print(4.sign);
  print((-4).sign);
  // isNegative on int and double
  print(3.14.isNegative);
  print((-2.5).isNegative);
  print(0.isNegative);
}
