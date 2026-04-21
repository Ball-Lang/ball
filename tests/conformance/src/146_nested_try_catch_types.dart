void riskyOperation(int level) {
  if (level == 1) throw FormatException('bad format');
  if (level == 2) throw RangeError('out of range');
  if (level == 3) throw StateError('bad state');
}

void main() {
  for (int i = 1; i <= 4; i++) {
    try {
      try {
        riskyOperation(i);
        print('Level $i: success');
      } on FormatException catch (e) {
        print('Level $i: FormatException - ${e.message}');
      } on RangeError catch (e) {
        print('Level $i: RangeError - ${e.message}');
        rethrow;
      }
    } on RangeError {
      print('Level $i: caught rethrown RangeError');
    } on StateError catch (e) {
      print('Level $i: StateError - ${e.message}');
    } finally {
      print('Level $i: finally');
    }
  }
}
