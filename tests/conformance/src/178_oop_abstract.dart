abstract class Shape {
  String color();
  double area();
}

class Circle extends Shape {
  double radius;
  Circle(this.radius);

  String color() {
    return 'red';
  }

  double area() {
    return 3.14;
  }
}

void main() {
  Shape s = Circle(1.0);
  print(s.color());
  print(s.area());
}
