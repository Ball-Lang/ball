// Two private backing stores beside ONE computed-property setter (issue #768).
//
// `fahrenheit` has no `_fahrenheit` store, so an engine that mirrors a setter's
// RETURN value onto "the" backing field has to work out WHICH store the body
// actually wrote. Guessing a literal name — the Dart engine's pre-#768
// `_writeBackingField` fell back to `_celsius` whenever `_<property>` was
// absent — silently overwrites a field the setter never names: a wrong answer
// with no diagnostic. Here `_celsius` must survive every `fahrenheit` write.
class Reading {
  int _celsius;
  int _kelvin;

  Reading(this._celsius, this._kelvin);

  int get celsius => _celsius;
  int get kelvin => _kelvin;

  // Expression-bodied on purpose: it RETURNS the assigned value, which is what
  // the mirror writes back. A block body returns null and is never mirrored.
  set fahrenheit(int value) => _kelvin = value + 1;

  // The ordinary `_<property>` convention still has to mirror.
  set celsius(int value) => _celsius = value;
}

void main() {
  final r = Reading(10, 0);
  r.fahrenheit = 211;
  print(r.celsius);
  print(r.kelvin);

  r.fahrenheit = 31;
  print(r.celsius);
  print(r.kelvin);

  r.celsius = 40;
  print(r.celsius);
  print(r.kelvin);
}
