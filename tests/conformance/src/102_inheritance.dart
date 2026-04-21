class Animal {
  String name;
  Animal(this.name);

  String speak() {
    return '$name makes a sound';
  }
}

class Dog extends Animal {
  Dog(String name) : super(name);

  String speak() {
    return '$name barks';
  }
}

class Cat extends Animal {
  Cat(String name) : super(name);

  String speak() {
    return '$name meows';
  }
}

void main() {
  Animal a = Animal('Animal');
  print(a.speak());
  Dog d = Dog('Rex');
  print(d.speak());
  Cat c = Cat('Whiskers');
  print(c.speak());
}
