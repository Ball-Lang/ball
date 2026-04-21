int maxOfThree(int a, int b, int c) {
  if (a >= b && a >= c) return a;
  if (b >= c) return b;
  return c;
}

void main() {
  print(maxOfThree(1, 2, 3).toString());
  print(maxOfThree(7, 5, 3).toString());
  print(maxOfThree(4, 9, 6).toString());
  print(maxOfThree(5, 5, 5).toString());
}
