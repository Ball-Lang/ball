void main() {
  final max64 = 9223372036854775807;
  final belowMax = 9223372036854775806;
  final belowMax2 = 9223372036854775805;
  final overflow = 1e308 * 1e308;

  print(max64);
  print(belowMax);
  print(belowMax2);
  print(overflow);
}
