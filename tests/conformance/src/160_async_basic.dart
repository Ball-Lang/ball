Future<int> delayedAdd(int n) async {
  return n + 10;
}

Future<void> main() async {
  final value = 5;
  print(await delayedAdd(value));
}
