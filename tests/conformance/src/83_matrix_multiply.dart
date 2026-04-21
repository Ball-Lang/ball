void main() {
  List<List<int>> a = [[1, 2], [3, 4]];
  List<List<int>> b = [[5, 6], [7, 8]];
  List<List<int>> result = [[0, 0], [0, 0]];
  for (int i = 0; i < 2; i++) {
    for (int j = 0; j < 2; j++) {
      for (int k = 0; k < 2; k++) {
        result[i][j] += a[i][k] * b[k][j];
      }
    }
  }
  for (List<int> row in result) {
    print('${row[0]} ${row[1]}');
  }
}
