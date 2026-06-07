void main() {
  // sign (getter → math_sign)
  print((-5).sign);
  print(0.sign);
  print(7.sign);

  // isEmpty / isNotEmpty (getter → string_is_empty / not(string_is_empty))
  print(''.isEmpty);
  print('abc'.isEmpty);
  print(''.isNotEmpty);
  print('abc'.isNotEmpty);
}
