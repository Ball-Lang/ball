int factorial(int n) {
  if (n <= 1) return 1;
  return n * factorial(n - 1);
}
int fibonacci(int n) {
  if (n < 2) return n;
  return fibonacci(n - 1) + fibonacci(n - 2);
}
void main() {
  print(factorial(5).toString());
  print(fibonacci(10).toString());
}
