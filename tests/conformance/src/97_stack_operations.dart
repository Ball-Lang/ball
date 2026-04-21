void main() {
  List<int> stack = [];
  stack.add(10);
  stack.add(20);
  stack.add(30);
  print(stack.last);
  stack.removeLast();
  print(stack.last);
  stack.add(40);
  print(stack.length);
  while (stack.isNotEmpty) {
    print(stack.removeLast());
  }
  print(stack.isEmpty);
}
