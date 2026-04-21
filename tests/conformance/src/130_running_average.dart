List<double> runningAverage(List<int> nums) {
  List<double> result = [];
  int sum = 0;
  for (int i = 0; i < nums.length; i++) {
    sum += nums[i];
    result.add(sum / (i + 1));
  }
  return result;
}

void main() {
  List<int> nums = [10, 20, 30, 40, 50];
  List<double> avg = runningAverage(nums);
  for (double a in avg) {
    print(a);
  }

  List<double> avg2 = runningAverage([5, 15, 25]);
  for (double a in avg2) {
    print(a);
  }
}
