void printLen(List<Object> items) {
  print(items.length);
  print(items.first);
}

List<T> wrap<T>(T value) => [value];

void main() {
  final nums = <int>[1, 2, 3];
  printLen(nums);
  print(wrap<Object>(42).first);
  print(wrap<String>('x').first);
  print(wrap<num>(3.5).first is num);
}
