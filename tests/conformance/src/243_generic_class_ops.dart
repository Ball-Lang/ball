class Box<T> {
  T value;
  Box(this.value);
  T unwrap() => value;
}

Box<T> cloneBox<T>(Box<T> box) => Box(box.unwrap());

void main() {
  final intBox = Box(99);
  final strBox = Box('data');
  print(intBox.unwrap());
  print(strBox.unwrap());
  print(cloneBox(intBox).unwrap());
  print(cloneBox(strBox).unwrap());
}
