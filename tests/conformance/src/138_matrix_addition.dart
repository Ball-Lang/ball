List<List<int>> matAdd(List<List<int>> a, List<List<int>> b) {
  int rows = a.length;
  int cols = a[0].length;
  List<List<int>> result = List.generate(rows, (i) => List.generate(cols, (j) => 0));
  for (int i = 0; i < rows; i++) {
    for (int j = 0; j < cols; j++) {
      result[i][j] = a[i][j] + b[i][j];
    }
  }
  return result;
}

void main() {
  List<List<int>> a = [
    [1, 2, 3],
    [4, 5, 6],
  ];
  List<List<int>> b = [
    [7, 8, 9],
    [10, 11, 12],
  ];
  List<List<int>> c = matAdd(a, b);
  for (List<int> row in c) {
    print(row);
  }
}
