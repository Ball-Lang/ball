class Fraction {
  int numerator;
  int denominator;

  Fraction(this.numerator, this.denominator);

  Fraction simplify() {
    // Explicit `this.` so the (type-blind) encoder routes the private
    // instance-method call through the instance-method path (with a `self`
    // receiver) rather than a top-level call the engine cannot resolve.
    int g = this._gcd(numerator.abs(), denominator.abs());
    return Fraction(numerator ~/ g, denominator ~/ g);
  }

  int _gcd(int a, int b) {
    while (b != 0) {
      int t = b;
      b = a % b;
      a = t;
    }
    return a;
  }

  String toString() {
    return '$numerator/$denominator';
  }
}

void main() {
  Fraction f1 = Fraction(3, 4);
  print(f1);
  Fraction f2 = Fraction(6, 8);
  print(f2);
  print(f2.simplify());
  Fraction f3 = Fraction(12, 4);
  print(f3.simplify());
}
