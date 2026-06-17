class Living {
  String name;
  Living(this.name);

  String getName() {
    return name;
  }
}

class Animal extends Living {
  int age;
  Animal(String name, this.age) : super(name);

  int getAge() {
    return age;
  }
}

class Mammal extends Animal {
  int legs;
  Mammal(String name, int age, this.legs) : super(name, age);

  int getLegs() {
    return legs;
  }
}

class Dog extends Mammal {
  int speed;
  Dog(String name, int age, int legs, this.speed) : super(name, age, legs);

  int getSpeed() {
    return speed;
  }
}

void main() {
  Dog d = Dog('Timmy', 30, 5, 10);
  print(d.getName());
  print(d.getAge());
  print(d.getLegs());
  print(d.getSpeed());
}
