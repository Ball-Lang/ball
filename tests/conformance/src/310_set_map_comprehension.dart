// Set and map comprehensions + spreads. Regression for issue #55: these
// returned empty ({}), and map comprehensions were misclassified as sets.
void main() {
  final xs = [1, 2, 3];
  final s = {for (var x in xs) x * x};
  print(s.toList());
  final m = {for (var x in xs) x: x * x};
  print(m);
  print({0, ...s}.toList());
  final m2 = {0: 0, ...m};
  print(m2);
  final mc = {for (var i = 1; i <= 3; i++) i: i * i};
  print(mc);
}
