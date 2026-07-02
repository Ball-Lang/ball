// Num instance methods must dispatch on a double-typed LOCAL (#115): the
// engine wraps double values in BallDouble, and methods with no dedicated
// std routing (e.g. `remainder`) fell through builtin-instance dispatch
// entirely ("Function main.remainder not found"). The routed methods
// (floor/ceil/round/abs/toInt/toString) are exercised on wrapped receivers
// too as regression guards.
void main() {
  double d = 2.5;
  print(d.remainder(2));
  print(d.floor());
  print(d.ceil());
  print(d.round());
  print(d.abs());
  print(d.toInt());
  print(d.toString());

  double neg = -3.75;
  print(neg.remainder(2));
  print(neg.abs());
  print(neg.truncate());

  int n = 7;
  print(n.remainder(3));
  print(n.toDouble());
}
