int power(int base, int exp) {
  int result = 1;
  for (int i = 0; i < exp; i++) {
    result *= base;
  }
  return result;
}

bool isArmstrong(int n) {
  int digits = n.toString().length;
  int sum = 0;
  int temp = n;
  while (temp > 0) {
    int d = temp % 10;
    sum += power(d, digits);
    temp ~/= 10;
  }
  return sum == n;
}

void main() {
  List<int> tests = [0, 1, 153, 370, 371, 407, 100, 9474];
  for (int t in tests) {
    print('$t: ${isArmstrong(t)}');
  }
}
