// num.toStringAsFixed(digits) — the encoder routes this to std
// `to_string_as_fixed` and the compilers emit it, and the engine dispatches it
// (the original #316 gap). This fixture covers positive, zero, integer,
// high-precision, AND negative receivers. Negatives were previously carved out
// because the TS self-host engine returned the integer part (issue #101); that
// value-truncation is resolved (the engine source formats through a
// double-preserving path). Negative zero (`-0.0`) is also exercised: the shared
// engine source re-adds the sign that JS `Number.toFixed` / C++ `printf` drop.
void main() {
  print(3.14159.toStringAsFixed(2));
  print(3.14159.toStringAsFixed(0));
  print(3.14159.toStringAsFixed(4));
  print(0.0.toStringAsFixed(2));
  print(123.456.toStringAsFixed(1));
  print(1000.0.toStringAsFixed(2));

  // int receiver (num.toStringAsFixed is valid on int too)
  int n = 42;
  print(n.toStringAsFixed(2));

  double pi = 3.14159265358979;
  print(pi.toStringAsFixed(5));

  // Negative receivers — the issue #101 regression surface.
  print((-2.71828).toStringAsFixed(3));
  print(double.parse('-2.71828').toStringAsFixed(3));
  print((-123.456).toStringAsFixed(1));
  print((-1000.0).toStringAsFixed(2));
  print((-2.5).toStringAsFixed(0));
  double negPi = -3.14159265358979;
  print(negPi.toStringAsFixed(5));
  int neg = -42;
  print(neg.toStringAsFixed(2));
  // Negative zero must keep its sign (Dart: -0.0, not 0.0).
  print((-0.0).toStringAsFixed(1));
}
