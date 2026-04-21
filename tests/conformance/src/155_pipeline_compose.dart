List<int> pipeline(List<int> data, List<List<int> Function(List<int>)> transforms) {
  List<int> result = data;
  for (var transform in transforms) {
    result = transform(result);
  }
  return result;
}

List<int> filterEven(List<int> items) {
  List<int> result = [];
  for (int x in items) {
    if (x % 2 == 0) result.add(x);
  }
  return result;
}

List<int> doubleAll(List<int> items) {
  List<int> result = [];
  for (int x in items) {
    result.add(x * 2);
  }
  return result;
}

List<int> sortAsc(List<int> items) {
  List<int> copy = List.of(items);
  copy.sort();
  return copy;
}

List<int> takeFirst(List<int> items) {
  return items.length > 3 ? items.sublist(0, 3) : items;
}

void main() {
  List<int> data = [9, 2, 7, 4, 1, 8, 3, 6, 5, 10];

  List<int> result = pipeline(data, [filterEven, doubleAll, sortAsc]);
  print(result);

  List<int> result2 = pipeline(data, [sortAsc, takeFirst, doubleAll]);
  print(result2);

  List<int> result3 = pipeline(data, [doubleAll, filterEven, sortAsc, takeFirst]);
  print(result3);
}
