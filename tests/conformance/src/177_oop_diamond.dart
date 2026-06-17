class A {
  String tag() {
    return 'A';
  }
}

class B extends A {
  String tag() {
    return '${super.tag()}+B';
  }
}

class C extends A {
  String tag() {
    return '${super.tag()}+C';
  }
}

void main() {
  A a = A();
  print(a.tag());
  B b = B();
  print(b.tag());
  C c = C();
  print(c.tag());
}
