void main() {
  int a = 42;
  double b = a.toDouble();
  print(b);
  double c = 3.14;
  int d = c.toInt();
  print(d);
  String s = '123';
  int e = int.parse(s);
  print(e);
  int f = e + a;
  print(f);
  String g = f.toString();
  print(g);
  print(g.length);
}
