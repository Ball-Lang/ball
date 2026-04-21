void main() {
  List<int> arr = [29, 10, 14, 37, 13];
  int n = arr.length;
  for (int i = 0; i < n - 1; i++) {
    int minIdx = i;
    for (int j = i + 1; j < n; j++) {
      if (arr[j] < arr[minIdx]) minIdx = j;
    }
    int temp = arr[i];
    arr[i] = arr[minIdx];
    arr[minIdx] = temp;
  }
  for (int x in arr) {
    print(x);
  }
}
