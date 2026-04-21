int josephus(int n, int k) {
  if (n == 1) return 0;
  return (josephus(n - 1, k) + k) % n;
}

void main() {
  print(josephus(7, 3));
  print(josephus(5, 2));
  print(josephus(10, 3));
  print(josephus(1, 5));
  print(josephus(6, 1));
  print(josephus(14, 2));
}
