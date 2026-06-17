void show(int input) {
  print(input.toString());
}

void main() {
  show(17 ~/ 5);
  show(-17 ~/ 5);
  show(-17 % 5);
  show(17 % -5);
  show(12 & 10);
  show(12 | 10);
  show(12 ^ 10);
  show(1 << 10);
  show(1024 >> 3);
  show(-42);
}
