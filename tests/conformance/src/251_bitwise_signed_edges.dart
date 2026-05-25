void main() {
  final a = -9223372036854775807 - 1;
  final b = 9223372036854775807;
  print(a >> 1);
  print(b >> 1);
  print(a & 1);
  print(b & 1);
  print(~0);
  print((-1) ^ (-2));
  print(0xFF << 56);
}
