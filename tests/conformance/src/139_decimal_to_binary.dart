String toBinary(int n) {
  if (n == 0) return '0';
  String result = '';
  int val = n;
  while (val > 0) {
    result = '${val % 2}$result';
    val ~/= 2;
  }
  return result;
}

void main() {
  print(toBinary(0));
  print(toBinary(1));
  print(toBinary(10));
  print(toBinary(42));
  print(toBinary(255));
  print(toBinary(1024));
}
