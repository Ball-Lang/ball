// Simulates coroutine-style interleaved execution using lists of steps
List<String> log = [];

List<String> task(String name, List<String> steps) {
  List<String> output = [];
  for (String step in steps) {
    output.add('$name: $step');
  }
  return output;
}

List<String> interleave(List<List<String>> tasks) {
  List<String> result = [];
  int maxLen = 0;
  for (List<String> t in tasks) {
    if (t.length > maxLen) maxLen = t.length;
  }
  for (int i = 0; i < maxLen; i++) {
    for (List<String> t in tasks) {
      if (i < t.length) {
        result.add(t[i]);
      }
    }
  }
  return result;
}

void main() {
  List<String> t1 = task('A', ['start', 'work', 'done']);
  List<String> t2 = task('B', ['init', 'process', 'save', 'close']);
  List<String> t3 = task('C', ['begin', 'end']);

  List<String> output = interleave([t1, t2, t3]);
  for (String line in output) {
    print(line);
  }
}
