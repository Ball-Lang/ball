Future<int> asyncDouble(int n) async {
  return n * 2;
}

Future<int> asyncTriple(int n) async {
  return n * 3;
}

Future<void> main() async {
  final first = await asyncDouble(10);
  final second = await asyncTriple(5);
  final sum = first + second;
  print(sum);
}
