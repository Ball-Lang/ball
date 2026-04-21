class Point {
  double x;
  double y;

  Point(this.x, this.y);

  Point.origin()
      : x = 0.0,
        y = 0.0;

  Point.fromList(List<double> coords)
      : x = coords[0],
        y = coords[1];

  String toString() {
    return '($x, $y)';
  }
}

void main() {
  Point p1 = Point(3.0, 4.0);
  print(p1);
  Point p2 = Point.origin();
  print(p2);
  Point p3 = Point.fromList([1.5, 2.5]);
  print(p3);
}
