Map<int, int> memo = {};

int fib(int n) {
  if (n <= 1) return n;
  if (memo.containsKey(n)) return memo[n]!;
  int result = fib(n - 1) + fib(n - 2);
  memo[n] = result;
  return result;
}

void main() {
  print(fib(10));
  print(fib(20));
  print(fib(30));
  print(fib(0));
  print(fib(1));
}
