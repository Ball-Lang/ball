void main() {
  var counter = 0;
  var increment = () {
    counter++;
    return counter;
  };
  print(increment().toString());
  print(increment().toString());
  print(increment().toString());
}
