class Base {
  int n = 5;
}

class Sub extends Base {
  int m;
  Sub.named(this.m);
}

void main() {
  final s = Sub.named(1);
  print(s.n);
  print(s.m);
}
