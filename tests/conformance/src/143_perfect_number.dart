bool isPerfect(int n) {
  if (n <= 1) return false;
  int sum = 1;
  for (int i = 2; i * i <= n; i++) {
    if (n % i == 0) {
      sum += i;
      if (i != n ~/ i) {
        sum += n ~/ i;
      }
    }
  }
  return sum == n;
}

void main() {
  List<int> tests = [6, 28, 496, 12, 1, 33550336];
  for (int t in tests) {
    print('$t: ${isPerfect(t)}');
  }
}
