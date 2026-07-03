// num.roundToDouble() / floorToDouble() / ceilToDouble() / truncateToDouble()
// (issue #100). The syntactic encoder previously left these unrouted, so a
// program crashed at runtime with `Function "main.roundToDouble" not found`.
// They now route to std base functions and return a double (renders `N.0`).
// Half-to-even/away edge values (`x.5`) are intentionally avoided: JS
// `Math.round` rounds half toward +infinity while Dart/C++ round half away
// from zero, so `2.5` would diverge across self-hosts (a separate concern).
void main() {
  // roundToDouble
  print(3.7.roundToDouble());
  print(3.2.roundToDouble());
  print((-3.7).roundToDouble());
  print((-3.2).roundToDouble());

  // floorToDouble
  print(3.7.floorToDouble());
  print((-3.2).floorToDouble());
  print(3.0.floorToDouble());

  // ceilToDouble
  print(3.2.ceilToDouble());
  print((-3.7).ceilToDouble());
  print(3.0.ceilToDouble());

  // truncateToDouble
  print(3.7.truncateToDouble());
  print((-3.7).truncateToDouble());

  // zero
  print(0.0.roundToDouble());

  // int receiver (num method is valid on int too)
  int n = 5;
  print(n.roundToDouble());
  print(n.floorToDouble());

  // chained with arithmetic
  double avg = (10 + 3) / 2; // 6.5
  print(avg.floorToDouble());
  print(avg.ceilToDouble());
}
