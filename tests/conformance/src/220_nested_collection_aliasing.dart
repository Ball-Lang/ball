void main() {
  final shared = [1, 2];
  final outer = [shared, shared];
  shared[0] = 99;
  shared.add(3);
  print(outer[0][0]);
  print(outer[1][0]);
  print(outer[0].length);
  print(outer[1].length);
  print(outer[0] == outer[1]);
}
