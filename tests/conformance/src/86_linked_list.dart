int sumRange(int start, int end) {
  int sum = 0;
  for (int i = start; i <= end; i++) {
    sum += i;
  }
  return sum;
}

void main() {
  print(sumRange(1, 10));
  print(sumRange(1, 100));
  print(sumRange(5, 15));
  print(sumRange(0, 0));
}
