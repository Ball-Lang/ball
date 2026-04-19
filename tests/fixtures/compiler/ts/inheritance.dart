abstract class Shape {
  String describe();

  String greet() => 'I am a ${describe()}';
}

class Circle extends Shape {
  final int radius;

  Circle(this.radius);

  @override
  String describe() => 'circle(r=$radius)';
}

class Square extends Shape {
  final int side;

  Square(this.side);

  @override
  String describe() => 'square(s=$side)';

  int area() => side * side;
}

void main() {
  final Shape c = Circle(5);
  final s = Square(4);
  print(c.describe());
  print(c.greet());
  print(s.describe());
  print(s.greet());
  print(s.area());
}
