int abs(int x) {
  if (x < 0) return -x;
  return x;
}

int max(int a, int b) {
  if (a > b) return a;
  return b;
}

int min(int a, int b) {
  if (a < b) return a;
  return b;
}

void main() {
  print(abs(-5).toString());
  print(abs(3).toString());
  print(max(10, 20).toString());
  print(min(10, 20).toString());
}
