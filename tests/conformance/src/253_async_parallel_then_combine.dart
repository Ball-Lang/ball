Future<int> delay(int ms, int value) async {
  return value;
}

Future<void> main() async {
  final first = delay(0, 1);
  final second = delay(0, 2);
  print(await first);
  print(await second);
  print(await delay(0, await first + await second));
}
