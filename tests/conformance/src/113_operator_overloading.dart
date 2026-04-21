class Vec2 {
  int x;
  int y;

  Vec2(this.x, this.y);

  Vec2 operator +(Vec2 other) {
    return Vec2(x + other.x, y + other.y);
  }

  Vec2 operator -(Vec2 other) {
    return Vec2(x - other.x, y - other.y);
  }

  Vec2 operator *(int scalar) {
    return Vec2(x * scalar, y * scalar);
  }

  bool operator ==(Object other) {
    if (other is Vec2) {
      return x == other.x && y == other.y;
    }
    return false;
  }

  int get hashCode => x.hashCode ^ y.hashCode;

  String toString() {
    return '($x, $y)';
  }
}

void main() {
  Vec2 a = Vec2(1, 2);
  Vec2 b = Vec2(3, 4);
  print(a + b);
  print(a - b);
  print(a * 3);
  print(a == Vec2(1, 2));
  print(a == b);
}
