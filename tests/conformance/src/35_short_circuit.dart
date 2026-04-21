void main() {
  var x = 0;
  var result = false && ((){x = 1; return true;}());
  print(result.toString());
  print(x.toString());
  var result2 = true || ((){x = 2; return false;}());
  print(result2.toString());
  print(x.toString());
}
