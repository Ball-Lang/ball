(int, int) addAndMultiply(int a, int b) {
  return (a + b, a * b);
}

({String name, int age}) person(String name, int age) {
  return (name: name, age: age);
}

int tupleFirst((int, int) pair) => pair.$1;

void main() {
  final result = addAndMultiply(3, 4);
  print(result.$1);
  print(result.$2);

  final (sum, product) = addAndMultiply(2, 5);
  print(sum);
  print(product);

  final p = person('Alice', 30);
  print(p.name);
  print(p.age);

  print(tupleFirst((10, 20)));
}
