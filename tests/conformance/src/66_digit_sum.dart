int digitSum(int n) {
  if (n < 0) n = -n;
  var sum = 0;
  while (n > 0) {
    sum += n % 10;
    n = n ~/ 10;
  }
  return sum;
}

void main() {
  print(digitSum(123).toString());
  print(digitSum(9999).toString());
  print(digitSum(0).toString());
  print(digitSum(100).toString());
}
