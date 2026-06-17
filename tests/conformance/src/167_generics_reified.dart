class Box<T> {
  late T value;

  Box(this.value);
}

void main() {
  var intBox = Box<int>(42);
  print(intBox.value.toString());

  var strBox = Box<String>('hello');

  var isIntBox = intBox is Box<int>;
  print(isIntBox);

  var isStrBox = intBox is Box<String>;
  print(isStrBox);
}
