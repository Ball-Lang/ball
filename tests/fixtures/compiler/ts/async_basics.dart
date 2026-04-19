Future<int> compute(int x) async {
  return x * 2;
}

Future<int> chain(int x) async {
  final doubled = await compute(x);
  final quadrupled = await compute(doubled);
  return quadrupled;
}

Future<void> main() async {
  final a = await compute(3);
  final b = await chain(5);
  print(a);
  print(b);
}
