List<List<int>> transpose(List<List<int>> matrix) {
  int rows = matrix.length;
  int cols = matrix[0].length;
  List<List<int>> result = List.generate(cols, (i) => List.generate(rows, (j) => 0));
  for (int i = 0; i < rows; i++) {
    for (int j = 0; j < cols; j++) {
      result[j][i] = matrix[i][j];
    }
  }
  return result;
}

void printMatrix(List<List<int>> m) {
  for (List<int> row in m) {
    print(row);
  }
}

void main() {
  List<List<int>> m = [
    [1, 2, 3],
    [4, 5, 6],
  ];
  print('Original:');
  printMatrix(m);
  print('Transposed:');
  printMatrix(transpose(m));
}
