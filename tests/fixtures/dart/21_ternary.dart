int abs(int x) => x < 0 ? -x : x;
String sign(int x) => x > 0 ? 'pos' : (x < 0 ? 'neg' : 'zero');
void main() {
  print(abs(-5).toString());
  print(abs(7).toString());
  print(sign(3));
  print(sign(-3));
  print(sign(0));
}
