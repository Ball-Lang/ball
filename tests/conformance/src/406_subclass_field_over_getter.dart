class A {
  int get x => 1;
}

class B extends A {
  @override
  int x = 5;
}

void main() {
  A a = A();
  print(a.x);
  B b = B();
  print(b.x);
  b.x = 7;
  print(b.x);
}
