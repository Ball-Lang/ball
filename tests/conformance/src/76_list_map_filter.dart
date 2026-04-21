void main() {
  List<int> nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
  List<int> evens = [];
  for (int n in nums) {
    if (n % 2 == 0) evens.add(n);
  }
  List<int> doubled = [];
  for (int n in evens) {
    doubled.add(n * 2);
  }
  int sum = 0;
  for (int n in doubled) {
    sum += n;
  }
  print(sum);
  print(evens.length);
  print(doubled.length);
}
