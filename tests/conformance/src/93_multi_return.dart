Map<String, int> minMax(List<int> arr) {
  int mn = arr[0];
  int mx = arr[0];
  for (int i = 1; i < arr.length; i++) {
    if (arr[i] < mn) mn = arr[i];
    if (arr[i] > mx) mx = arr[i];
  }
  return {'min': mn, 'max': mx};
}

void main() {
  Map<String, int> result = minMax([3, 1, 4, 1, 5, 9, 2, 6]);
  print(result['min']);
  print(result['max']);
  Map<String, int> result2 = minMax([42]);
  print(result2['min']);
  print(result2['max']);
}
