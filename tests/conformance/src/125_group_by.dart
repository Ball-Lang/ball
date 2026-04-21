Map<String, List<int>> groupBy(List<int> nums, String Function(int) classifier) {
  Map<String, List<int>> groups = {};
  for (int n in nums) {
    String key = classifier(n);
    if (!groups.containsKey(key)) {
      groups[key] = [];
    }
    groups[key]!.add(n);
  }
  return groups;
}

void main() {
  List<int> nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
  Map<String, List<int>> byParity = groupBy(nums, (n) => n % 2 == 0 ? 'even' : 'odd');
  List<String> keys = byParity.keys.toList()..sort();
  for (String key in keys) {
    print('$key: ${byParity[key]}');
  }

  Map<String, List<int>> bySize = groupBy(nums, (n) => n <= 5 ? 'small' : 'large');
  List<String> sizeKeys = bySize.keys.toList()..sort();
  for (String key in sizeKeys) {
    print('$key: ${bySize[key]}');
  }
}
