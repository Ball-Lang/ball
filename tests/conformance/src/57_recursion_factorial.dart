int factorial(int n) {
  if (n <= 1) return 1;
  return n * factorial(n - 1);
}

void main() {
  print(factorial(1).toString());
  print(factorial(5).toString());
  print(factorial(10).toString());
}
