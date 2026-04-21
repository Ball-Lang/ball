bool isEven(int n) {
  if (n == 0) return true;
  return isOdd(n - 1);
}

bool isOdd(int n) {
  if (n == 0) return false;
  return isEven(n - 1);
}

void main() {
  print(isEven(4).toString());
  print(isOdd(4).toString());
  print(isEven(7).toString());
  print(isOdd(7).toString());
}
