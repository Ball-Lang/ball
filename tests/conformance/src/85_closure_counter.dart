typedef IntCallback = int Function();

List<IntCallback> makeCounters() {
  List<IntCallback> counters = [];
  for (int i = 0; i < 3; i++) {
    int count = i * 10;
    counters.add(() {
      count++;
      return count;
    });
  }
  return counters;
}

void main() {
  List<IntCallback> counters = makeCounters();
  print(counters[0]());
  print(counters[0]());
  print(counters[1]());
  print(counters[2]());
  print(counters[0]());
}
