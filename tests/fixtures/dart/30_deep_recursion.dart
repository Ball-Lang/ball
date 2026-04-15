int sumTo(int n) {
  if (n <= 0) return 0;
  return n + sumTo(n - 1);
}

int power(int base, int exp) {
  if (exp == 0) return 1;
  return base * power(base, exp - 1);
}

void main() {
  print(sumTo(10).toString());     // 55
  print(sumTo(100).toString());    // 5050
  print(power(2, 10).toString());  // 1024
  print(power(3, 4).toString());   // 81
}
