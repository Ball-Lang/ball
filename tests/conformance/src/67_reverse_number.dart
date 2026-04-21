int reverseNum(int n) {
  var result = 0;
  while (n > 0) {
    result = result * 10 + n % 10;
    n = n ~/ 10;
  }
  return result;
}

void main() {
  print(reverseNum(123).toString());
  print(reverseNum(4567).toString());
  print(reverseNum(1000).toString());
  print(reverseNum(9).toString());
}
