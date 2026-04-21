abstract class Shape {
  double area();
  String name();
}

class Circle extends Shape {
  double radius;
  Circle(this.radius);

  double area() {
    return 3.14159 * radius * radius;
  }

  String name() {
    return 'Circle';
  }
}

class Rectangle extends Shape {
  double width;
  double height;
  Rectangle(this.width, this.height);

  double area() {
    return width * height;
  }

  String name() {
    return 'Rectangle';
  }
}

void main() {
  List<Shape> shapes = [Circle(5.0), Rectangle(3.0, 4.0), Circle(1.0)];
  for (Shape s in shapes) {
    print('${s.name()}: ${s.area()}');
  }
}
