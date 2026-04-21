void main() {
  var x = 10;
  {
    var x = 20;
    print(x.toString());
  }
  print(x.toString());
  {
    x = 30;
  }
  print(x.toString());
}
