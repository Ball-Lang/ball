void main() {
  var a = -5;
  var b = -3;
  print((a + b).toString());   // -8
  print((a - b).toString());   // -2
  print((a * b).toString());   // 15
  print((a ~/ b).toString());  // 1 (truncation toward zero in Dart)
  print((-a).toString());      // 5
  print((-(a + b)).toString()); // 8
}
