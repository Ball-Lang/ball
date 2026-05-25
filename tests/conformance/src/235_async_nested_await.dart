Future<int> inner(int x) async {
  return x + 1;
}

Future<int> outer(int x) async {
  final y = await inner(x);
  final z = await inner(y);
  return z;
}

Future<void> main() async {
  print(await outer(10));
  print(await outer(await inner(0)));
}
