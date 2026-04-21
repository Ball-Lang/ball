int gcd(int a, int b) {
  while (b != 0) {
    int t = b;
    b = a % b;
    a = t;
  }
  return a;
}

int lcm(int a, int b) {
  return (a * b) ~/ gcd(a, b);
}

int lcmOfList(List<int> nums) {
  int result = nums[0];
  for (int i = 1; i < nums.length; i++) {
    result = lcm(result, nums[i]);
  }
  return result;
}

void main() {
  print(lcm(4, 6));
  print(lcm(12, 18));
  print(lcm(7, 5));
  print(lcm(1, 100));
  print(lcmOfList([2, 3, 4, 5, 6]));
  print(lcmOfList([12, 15, 20]));
}
