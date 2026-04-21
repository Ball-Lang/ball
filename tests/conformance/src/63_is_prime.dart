bool isPrime(int n) {
  if (n < 2) return false;
  for (var i = 2; i * i <= n; i++) {
    if (n % i == 0) return false;
  }
  return true;
}

void main() {
  for (var i = 1; i <= 20; i++) {
    if (isPrime(i)) {
      print(i.toString());
    }
  }
}
