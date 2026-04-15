bool isEven(int n) {
  if (n == 0) return true;
  return isOdd(n - 1);
}

bool isOdd(int n) {
  if (n == 0) return false;
  return isEven(n - 1);
}

void main() {
  print(isEven(0).toString());
  print(isOdd(7).toString());
  print(isEven(10).toString());
  print(isOdd(10).toString());
}
