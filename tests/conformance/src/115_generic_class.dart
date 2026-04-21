class Pair<A, B> {
  A first;
  B second;

  Pair(this.first, this.second);

  String toString() {
    return '($first, $second)';
  }
}

class Stack<T> {
  List<T> _items = [];

  void push(T item) {
    _items.add(item);
  }

  T pop() {
    return _items.removeLast();
  }

  T get peek => _items.last;

  bool get isEmpty => _items.isEmpty;

  int get size => _items.length;
}

void main() {
  Pair<int, String> p = Pair(1, 'hello');
  print(p);
  Pair<String, bool> p2 = Pair('test', true);
  print(p2);

  Stack<int> s = Stack<int>();
  s.push(10);
  s.push(20);
  s.push(30);
  print(s.peek);
  print(s.pop());
  print(s.size);
  print(s.isEmpty);
}
