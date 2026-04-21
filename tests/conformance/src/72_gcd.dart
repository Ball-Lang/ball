int gcd(int a, int b) {
  while (b != 0) {
    var t = b;
    b = a % b;
    a = t;
  }
  return a;
}

void main() {
  print(gcd(12, 8).toString());
  print(gcd(100, 75).toString());
  print(gcd(17, 13).toString());
}
