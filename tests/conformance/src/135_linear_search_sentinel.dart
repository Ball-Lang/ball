int sentinelSearch(List<int> arr, int target) {
  int n = arr.length;
  if (n == 0) return -1;
  int last = arr[n - 1];
  arr[n - 1] = target;
  int i = 0;
  while (arr[i] != target) {
    i++;
  }
  arr[n - 1] = last;
  if (i < n - 1 || arr[n - 1] == target) {
    return i;
  }
  return -1;
}

void main() {
  List<int> arr = [10, 20, 30, 40, 50, 60, 70];
  print(sentinelSearch(arr, 30));
  print(sentinelSearch(arr, 70));
  print(sentinelSearch(arr, 10));
  print(sentinelSearch(arr, 99));
  print(sentinelSearch(arr, 50));
}
