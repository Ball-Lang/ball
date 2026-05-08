// Tests that closures created inside a for-loop capture each iteration's
// value of the loop variable correctly (each closure holds its own binding,
// not a shared cell that points at the final value).
void main() {
  final adders = <int Function(int)>[];
  for (var i = 0; i < 3; i++) {
    final captured = i;
    adders.add((int x) => x + captured);
  }
  print(adders[0](10));
  print(adders[1](10));
  print(adders[2](10));
}
