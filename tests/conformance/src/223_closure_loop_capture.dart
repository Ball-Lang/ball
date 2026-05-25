int Function() makeAdder(int base) {
  return () => base + 1;
}

void main() {
  final adders = <int Function()>[];
  for (var i = 0; i < 3; i++) {
    adders.add(makeAdder(i));
  }
  for (var i = 0; i < adders.length; i++) {
    print(adders[i]());
  }
}
