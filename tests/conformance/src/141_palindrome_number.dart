bool isPalindrome(int n) {
  if (n < 0) return false;
  int original = n;
  int reversed = 0;
  int num = n;
  while (num > 0) {
    reversed = reversed * 10 + num % 10;
    num ~/= 10;
  }
  return original == reversed;
}

void main() {
  List<int> tests = [121, 12321, 123, 0, 1, 1001, 1234321, 100];
  for (int t in tests) {
    print('$t: ${isPalindrome(t)}');
  }
}
