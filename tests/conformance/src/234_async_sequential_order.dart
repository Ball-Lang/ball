Future<int> step(int n) async {
  return n;
}

Future<void> main() async {
  final a = await step(1);
  final b = await step(2);
  final c = await step(3);
  print('$a$b$c');
  print(await step(a + b + c));
}
