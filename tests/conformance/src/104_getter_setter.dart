class Temperature {
  double _celsius;

  Temperature(this._celsius);

  double get celsius => _celsius;
  set celsius(double value) {
    _celsius = value;
  }

  double get fahrenheit => _celsius * 9.0 / 5.0 + 32.0;
  set fahrenheit(double value) {
    _celsius = (value - 32.0) * 5.0 / 9.0;
  }
}

void main() {
  Temperature t = Temperature(0.0);
  print(t.celsius);
  print(t.fahrenheit);
  t.celsius = 100.0;
  print(t.celsius);
  print(t.fahrenheit);
  t.fahrenheit = 32.0;
  print(t.celsius);
  print(t.fahrenheit);
}
