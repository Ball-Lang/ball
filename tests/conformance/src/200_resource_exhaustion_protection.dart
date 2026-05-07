List<int> build(int depth) {
  if (depth == 0) {
    return List.generate(64, (i) => i);
  }

  final items = build(depth - 1);
  items.add(depth);
  return items;
}

int total(List<int> values) {
  var sum = 0;
  for (final value in values) {
    sum += value;
  }
  return sum;
}

void main() {
  final items = build(200);
  print(items.length);
  print(total(items));
}
