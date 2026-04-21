int abs(int x) {
  if (x < 0) return -x;
  return x;
}

void main() {
  print(abs(5).toString());
  print(abs(-5).toString());
  print(abs(0).toString());
  print(abs(-100).toString());
}
