void main() {
  int count = 0;
  outer:
  for (int i = 0; i < 5; i++) {
    for (int j = 0; j < 5; j++) {
      if (i + j > 5) continue outer;
      if (i * j > 8) break outer;
      count++;
    }
  }
  print('Count: $count');

  List<List<int>> matrix = [
    [1, 2, 3],
    [4, 5, 6],
    [7, 8, 9],
  ];
  int target = 5;
  bool found = false;
  search:
  for (int i = 0; i < matrix.length; i++) {
    for (int j = 0; j < matrix[i].length; j++) {
      if (matrix[i][j] == target) {
        print('Found $target at ($i, $j)');
        found = true;
        break search;
      }
    }
  }
  print('Found: $found');
}
