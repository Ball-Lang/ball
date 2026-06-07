bool identity(bool b) => b;
void main() {
  var t = identity(true);
  var f = identity(false);
  print((t && t).toString());
  print((t && f).toString());
  print((t || f).toString());
  print((!f).toString());
}
