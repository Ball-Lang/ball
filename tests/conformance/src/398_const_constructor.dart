class Point {
  final int x;
  final int y;

  const Point(this.x, this.y);

  int sum() {
    return x + y;
  }
}

void main() {
  const Point p1 = Point(3, 4);
  print(p1.sum());
  Point p2 = const Point(10, 20);
  print(p2.sum());
}
