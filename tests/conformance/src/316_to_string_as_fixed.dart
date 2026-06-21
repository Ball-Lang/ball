// num.toStringAsFixed(digits) — the encoder routes this to std
// `to_string_as_fixed` and the compilers emit it, but the engine had no
// handler (it threw "Unknown std function"). No fixture exercised it, so the
// encoder-completeness gate (forward-complete over fixtures) never caught it.
void main() {
  print(3.14159.toStringAsFixed(2));
  print(3.14159.toStringAsFixed(0));
  print(3.14159.toStringAsFixed(4));
  print(0.0.toStringAsFixed(2));
  // NOTE: negative values are intentionally NOT exercised here — the TS
  // self-host engine mis-evaluates `to_string_as_fixed` on a negative double
  // (returns the integer part), a separate tracked bug. The Dart engine +
  // compiler handle negatives correctly.
  print(123.456.toStringAsFixed(1));
  print(1000.0.toStringAsFixed(2));

  // int receiver (num.toStringAsFixed is valid on int too)
  int n = 42;
  print(n.toStringAsFixed(2));

  double pi = 3.14159265358979;
  print(pi.toStringAsFixed(5));
}
