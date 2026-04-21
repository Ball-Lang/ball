class Vehicle {
  String type;
  Vehicle(this.type);

  String describe() {
    return type;
  }
}

class MotorVehicle extends Vehicle {
  int horsepower;
  MotorVehicle(String type, this.horsepower) : super(type);

  String describe() {
    return '${super.describe()} ($horsepower hp)';
  }
}

class Car extends MotorVehicle {
  int doors;
  Car(int horsepower, this.doors) : super('Car', horsepower);

  String describe() {
    return '${super.describe()} $doors doors';
  }
}

class Truck extends MotorVehicle {
  double payload;
  Truck(int horsepower, this.payload) : super('Truck', horsepower);

  String describe() {
    return '${super.describe()} ${payload}t payload';
  }
}

void main() {
  Vehicle v = Vehicle('Bicycle');
  print(v.describe());
  MotorVehicle m = MotorVehicle('Motorcycle', 150);
  print(m.describe());
  Car c = Car(200, 4);
  print(c.describe());
  Truck t = Truck(400, 10.5);
  print(t.describe());
}
