void main() {
  final fns = <int Function()>[];
  for (var i = 0; i < 3; i++) {
    fns.add(() => i + 10);
  }
  for (var j = 0; j < fns.length; j++) {
    print(fns[j]());
  }
}
