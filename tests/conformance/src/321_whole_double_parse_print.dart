// Whole-number doubles must keep their double-ness end to end (#67): JS
// numbers erase the int/double distinction, so the TS self-host engine
// printed `-7` for `double.parse('-7.0')` (std string_to_double returned a
// bare JS number instead of the engine's double wrapper). Native Dart, the
// Dart engine, and the C++ targets all print `-7.0`.
void main() {
  print(double.parse('-7.0'));
  print(double.parse('7.0'));
  print(double.parse('0.5'));
  print(double.parse('100.0') / 4);
  print(double.parse('3.0') + double.parse('4.0'));

  double d = -7.0;
  print(d);
  print(d.toString());
}
