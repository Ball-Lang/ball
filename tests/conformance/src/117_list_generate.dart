void main() {
  List<int> squares = List.generate(10, (i) => i * i);
  for (int s in squares) {
    print(s);
  }

  List<String> labels = List.generate(5, (i) => 'Item ${i + 1}');
  for (String l in labels) {
    print(l);
  }

  List<bool> evens = List.generate(8, (i) => i % 2 == 0);
  for (bool e in evens) {
    print(e);
  }
}
