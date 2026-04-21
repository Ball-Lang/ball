int binarySearch(List<int> arr, int target) {
  int low = 0;
  int high = arr.length - 1;
  while (low <= high) {
    int mid = (low + high) ~/ 2;
    if (arr[mid] == target) return mid;
    if (arr[mid] < target) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return -1;
}

void main() {
  List<int> sorted = [2, 5, 8, 12, 16, 23, 38, 56, 72, 91];
  print(binarySearch(sorted, 23));
  print(binarySearch(sorted, 72));
  print(binarySearch(sorted, 1));
  print(binarySearch(sorted, 100));
}
