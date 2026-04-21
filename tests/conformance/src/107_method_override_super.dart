class Base {
  String greet() {
    return 'Hello from Base';
  }

  int compute(int x) {
    return x * 2;
  }
}

class Child extends Base {
  String greet() {
    return '${super.greet()} and Child';
  }

  int compute(int x) {
    return super.compute(x) + 10;
  }
}

class GrandChild extends Child {
  String greet() {
    return '${super.greet()} and GrandChild';
  }

  int compute(int x) {
    return super.compute(x) + 100;
  }
}

void main() {
  Base b = Base();
  print(b.greet());
  print(b.compute(5));
  Child c = Child();
  print(c.greet());
  print(c.compute(5));
  GrandChild g = GrandChild();
  print(g.greet());
  print(g.compute(5));
}
