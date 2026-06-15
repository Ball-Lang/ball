class Animal {
  String name;
  Animal(this.name);

  String describe() {
    return name;
  }
}

class Dog extends Animal {
  Dog(String name) : super(name);

  String describe() {
    return '${super.describe()} barks';
  }
}

void main() {
  Animal a = Animal('Rex');
  print(a.describe());
  Dog d = Dog('Rex');
  print(d.describe());
}
