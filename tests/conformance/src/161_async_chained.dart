Future<int> step1(int x) async {
  return x * 2;
}

Future<int> step2(int x) async {
  return x * 3;
}

Future<void> main() async {
  final result = await step2(await step1(5));
  print(result);
}
