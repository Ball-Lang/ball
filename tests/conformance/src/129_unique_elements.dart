List<int> unique(List<int> items) {
  Set<int> seen = {};
  List<int> result = [];
  for (int item in items) {
    if (!seen.contains(item)) {
      seen.add(item);
      result.add(item);
    }
  }
  return result;
}

void main() {
  List<int> nums = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5];
  print(unique(nums));
  print(unique([1, 1, 1, 1]));
  print(unique([1, 2, 3, 4, 5]));
  print(unique([]));
}
