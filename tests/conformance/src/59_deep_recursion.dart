int sum(int n) {
  if (n == 0) return 0;
  return n + sum(n - 1);
}

void main() {
  print(sum(100).toString());
  print(sum(50).toString());
}
