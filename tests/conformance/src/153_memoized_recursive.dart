Map<String, int> memo = {};

int binomial(int n, int k) {
  if (k == 0 || k == n) return 1;
  String key = '$n,$k';
  if (memo.containsKey(key)) return memo[key]!;
  int result = binomial(n - 1, k - 1) + binomial(n - 1, k);
  memo[key] = result;
  return result;
}

int catalan(int n) {
  return binomial(2 * n, n) ~/ (n + 1);
}

void main() {
  print(binomial(5, 2));
  print(binomial(10, 3));
  print(binomial(10, 5));
  print(binomial(20, 10));

  for (int i = 0; i < 10; i++) {
    print('C($i) = ${catalan(i)}');
  }
}
