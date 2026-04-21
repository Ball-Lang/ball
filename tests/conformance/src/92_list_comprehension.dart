List<int> range(int start, int end) {
  List<int> result = [];
  for (int i = start; i < end; i++) {
    result.add(i);
  }
  return result;
}

void main() {
  List<int> nums = range(0, 10);
  List<int> squares = [];
  for (int n in nums) {
    squares.add(n * n);
  }
  for (int s in squares) {
    print(s);
  }
}
