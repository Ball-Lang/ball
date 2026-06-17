class Container<T> {
  late T value;

  Container(this.value);

  T get getValue => value;
}

String process<T>(Container<T> input) {
  var c = input;
  return c.getValue.toString();
}

void main() {
  var intContainer = Container<int>(100);
  print(process(intContainer));

  var strContainer = Container<String>('text');
  print(process(strContainer));
}
