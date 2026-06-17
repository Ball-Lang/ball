class Base {
  String name() {
    return 'Base';
  }
}

class Derived extends Base {
  String name() {
    return '${super.name()}-Derived';
  }
}

void main() {
  Base b = Base();
  print(b.name());
  Derived d = Derived();
  print(d.name());
  Base poly = Derived();
  print(poly.name());
}
