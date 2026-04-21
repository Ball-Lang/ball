class Point {
  int x;
  int y;

  Point(this.x, this.y);

  int distanceSquared() {
    return x * x + y * y;
  }

  String describe() {
    return '($x, $y)';
  }
}

void main() {
  Point p1 = Point(3, 4);
  print(p1.describe());
  print(p1.distanceSquared());
  Point p2 = Point(0, 0);
  print(p2.describe());
  print(p2.distanceSquared());
  p2.x = 5;
  p2.y = 12;
  print(p2.describe());
  print(p2.distanceSquared());
}
