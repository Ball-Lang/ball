void main() {
  var a = 10;
  var b = 20;
  var max = a > b ? a : b;
  print(max.toString());
  var min = a < b ? a : b;
  print(min.toString());
  var abs = a - b > 0 ? a - b : b - a;
  print(abs.toString());
}
