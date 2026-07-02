// Setters whose parameter is NOT named `value` (#95): the engine's setter
// dispatch passes the assigned value under the fixed key 'value', so the
// declared parameter must bind regardless of its name ('d', 'f', or the
// compiler's `input` rename on round-trip).
class Celsius {
  double _degrees;

  Celsius(this._degrees);

  double get degrees => _degrees;
  set degrees(double d) {
    _degrees = d;
  }

  double get fahrenheit => _degrees * 9.0 / 5.0 + 32.0;
  set fahrenheit(double f) {
    _degrees = (f - 32.0) * 5.0 / 9.0;
  }
}

void main() {
  final c = Celsius(0.0);
  print(c.degrees);
  c.degrees = 25.0;
  print(c.degrees);
  c.fahrenheit = 212.0;
  print(c.degrees);
  print(c.fahrenheit);
}
