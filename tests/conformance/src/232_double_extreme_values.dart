void main() {
  final overflow = 1e308 * 1e308;
  final tiny = 2.2250738585072014e-308;
  final big = 1.7976931348623157e+308;
  print(overflow > big);
  print(tiny > 0);
  print((1.0 / tiny) > 1e300);
  print(overflow == (1.0 / 0.0));
  print((-1e308 * 1e308) < 0);
  print((1.0 / 0.0) > big);
}
