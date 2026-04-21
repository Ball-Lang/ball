int square(int x) {
  return x * x;
}

int cube(int x) {
  return x * x * x;
}

int add(int a, int b) {
  return a + b;
}

void main() {
  print(square(4).toString());
  print(cube(3).toString());
  print(add(square(2), cube(2)).toString());
}
