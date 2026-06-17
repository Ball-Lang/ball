Future<int> inner(int x) async {
  return x + 10;
}

Future<int> outer(int y) async {
  return await inner(y);
}

Future<void> main() async {
  final result = await outer(5);
  print(result);
}
