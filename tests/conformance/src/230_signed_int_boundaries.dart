void main() {
  final minInt = -9223372036854775807 - 1;
  final maxInt = 9223372036854775807;
  print(minInt);
  print(maxInt);
  print(minInt + 1);
  print(maxInt - 1);
  print(-1);
  print(0);
  print(1);
  print(minInt.abs());
  print((maxInt - minInt).toString().length > 1);
}
