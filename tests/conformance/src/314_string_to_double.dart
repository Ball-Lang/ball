// `double.parse` exercises the std `string_to_double` base function (was
// emittable but never covered — surfaced by the encoder-completeness gate).
// Values are exact, non-whole doubles so they format identically on every
// engine (whole-number doubles like -7.0 print as `-7` on the JS-backed TS
// engine — a separate, pre-existing double-formatting gap, not string_to_double).
void main() {
  print(double.parse('3.5'));
  print(double.parse('2.5') + 1.25);
  print(double.parse('-7.5'));
}
