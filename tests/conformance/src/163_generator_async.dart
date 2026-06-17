Stream<int> asyncRange(int max) async* {
  for (int i = 1; i <= max; i = i + 1) {
    yield i;
  }
}

Future<void> main() async {
  var all = await asyncRange(5).toList();
  print(all.length);
  print(all.first);
}
