int abs(int x) {
  if (x < 0) {
    return -x;
  }
  return x;
}

int max(int a, int b) {
  if (a > b) {
    return a;
  }
  return b;
}

int min(int a, int b) {
  if (a < b) {
    return a;
  }
  return b;
}

void main() {
  print('${abs(-5)}');
  print('${abs(3)}');
  print('${max(10, 20)}');
  print('${min(10, 20)}');
}
