List<int> flatten(List<List<int>> nested) {
  List<int> result = [];
  for (List<int> inner in nested) {
    for (int x in inner) {
      result.add(x);
    }
  }
  return result;
}

void main() {
  List<List<int>> nested = [
    [1, 2, 3],
    [4, 5],
    [6, 7, 8, 9],
    [10],
  ];
  List<int> flat = flatten(nested);
  print(flat);

  List<List<int>> empty = [[], [1], []];
  print(flatten(empty));
}
