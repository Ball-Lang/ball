List<int> countingSort(List<int> arr, int maxVal) {
  List<int> count = List.generate(maxVal + 1, (i) => 0);
  for (int x in arr) {
    count[x]++;
  }
  List<int> result = [];
  for (int i = 0; i <= maxVal; i++) {
    for (int j = 0; j < count[i]; j++) {
      result.add(i);
    }
  }
  return result;
}

void main() {
  List<int> arr = [4, 2, 2, 8, 3, 3, 1, 7, 5, 5];
  List<int> sorted = countingSort(arr, 8);
  for (int x in sorted) {
    print(x);
  }
}
