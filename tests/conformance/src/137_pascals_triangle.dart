void main() {
  int rows = 8;
  List<List<int>> triangle = [];
  for (int i = 0; i < rows; i++) {
    List<int> row = List.generate(i + 1, (j) => 1);
    for (int j = 1; j < i; j++) {
      row[j] = triangle[i - 1][j - 1] + triangle[i - 1][j];
    }
    triangle.add(row);
  }
  for (List<int> row in triangle) {
    print(row);
  }
}
