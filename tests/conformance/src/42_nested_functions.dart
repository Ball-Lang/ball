int add(int a, int b) {
  return a + b;
}

int multiply(int a, int b) {
  return a * b;
}

void main() {
  print(add(3, 4).toString());
  print(multiply(5, 6).toString());
  print(add(multiply(2, 3), multiply(4, 5)).toString());
}
