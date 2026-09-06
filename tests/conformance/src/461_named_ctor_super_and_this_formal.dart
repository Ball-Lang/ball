class Base {
  Base(int a);
}

class Foo extends Base {
  int x;
  Foo.named(this.x) : super(1);
}

void main() {
  print(Foo.named(7).x);
}
