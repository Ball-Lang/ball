void main() {
  final original = [1, 2, 3];
  final alias = original;
  alias[1] = 99;
  alias.add(4);
  print(original[1]);
  print(alias[1]);
  print(original.length);
  print(alias.length);
  print(original[3]);
}
