class Point {
  final int x;
  final int y;

  Point(this.x, this.y);

  int distanceSquared(Point other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return dx * dx + dy * dy;
  }

  @override
  String toString() => 'Point($x, $y)';
}

void main() {
  final p = Point(3, 4);
  final q = Point(0, 0);
  print(p.distanceSquared(q));
  print(p);
}
