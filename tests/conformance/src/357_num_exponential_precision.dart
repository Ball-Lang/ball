// num.toStringAsExponential([fractionDigits]) and num.toStringAsPrecision(p)
// (issue #100). The encoder routes these to std `to_string_as_exponential` /
// `to_string_as_precision`; every engine must produce Dart-identical bytes.
//
// Previously carved out of the C++ self-host corpus because C++'s
// `std::scientific`/`std::setprecision` diverge from Dart's minimal exponent
// (`1.23e+2`, not `1.23e+02`), trailing-zero padding (`1.00`, which
// `std::defaultfloat` drops), and round-half-AWAY-from-zero on an exact tie
// (`2.5.toStringAsExponential(0)` → `3e+0`, not IEEE ties-to-even's `2e+0`).
// The C++ emission now reproduces all three via exact-decimal-digit extraction
// (ball_emit_runtime.h), so this fixture runs on Dart, TS, and C++ alike.
//
// Negative-zero receivers are intentionally NOT exercised here: JS
// `Number.toExponential` drops the `-0` sign, so it stays covered by the Dart
// engine unit tests rather than the cross-language corpus.
void main() {
  // ── toStringAsExponential(fractionDigits) ──
  print(123.456.toStringAsExponential(2)); // 1.23e+2
  print(123.456.toStringAsExponential(0)); // 1e+2
  print(0.0.toStringAsExponential(2)); // 0.00e+0
  print(0.0.toStringAsExponential(0)); // 0e+0
  print(1.0.toStringAsExponential(3)); // 1.000e+0  (trailing-zero padding)
  print(100000.0.toStringAsExponential(2)); // 1.00e+5
  print(0.0001234.toStringAsExponential(2)); // 1.23e-4  (negative exponent)
  print(1234567.0.toStringAsExponential(3)); // 1.235e+6
  print(9.999.toStringAsExponential(2)); // 1.00e+1   (rounding carry)
  print(2.5.toStringAsExponential(0)); // 3e+0      (exact-tie, away from zero)
  print(1.5.toStringAsExponential(0)); // 2e+0      (exact-tie, away from zero)
  print(0.05.toStringAsExponential(1)); // 5.0e-2
  print((-123.456).toStringAsExponential(2)); // -1.23e+2

  // ── toStringAsExponential()  (no arg → shortest round-trip mantissa) ──
  print(123.456.toStringAsExponential()); // 1.23456e+2
  print(100000.0.toStringAsExponential()); // 1e+5
  print(0.0001234.toStringAsExponential()); // 1.234e-4
  print(1.0.toStringAsExponential()); // 1e+0

  // ── toStringAsPrecision(precision) ──
  print(123.456.toStringAsPrecision(5)); // 123.46   (fixed form)
  print(123.456.toStringAsPrecision(2)); // 1.2e+2   (exponential form)
  print(1.0.toStringAsPrecision(3)); // 1.00     (trailing-zero padding)
  print(0.0001234.toStringAsPrecision(2)); // 0.00012  (small-magnitude fixed)
  print(1234567.0.toStringAsPrecision(3)); // 1.23e+6
  print(9.999.toStringAsPrecision(2)); // 10       (rounding carry)
  print(55.0.toStringAsPrecision(1)); // 6e+1     (exact-tie, away from zero)
  print(100.0.toStringAsPrecision(5)); // 100.00
  print(0.0.toStringAsPrecision(3)); // 0.00
  print((-123.456).toStringAsPrecision(4)); // -123.5
}
