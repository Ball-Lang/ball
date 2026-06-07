int fib(int n) {
  if (n <= 1) return n;
  return fib(n - 1) + fib(n - 2);
}

void main() {
  for (int i = 0; i < 8; i++) {
    print(fib(i).toString());
  }
}
