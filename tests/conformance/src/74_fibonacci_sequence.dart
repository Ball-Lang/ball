void main() {
  var a = 0;
  var b = 1;
  for (var i = 0; i < 10; i++) {
    print(a.toString());
    var temp = a + b;
    a = b;
    b = temp;
  }
}
