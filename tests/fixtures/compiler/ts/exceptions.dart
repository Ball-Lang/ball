class DomainError implements Exception {
  final String reason;
  DomainError(this.reason);

  @override
  String toString() => 'DomainError: $reason';
}

int safeDivide(int a, int b) {
  if (b == 0) throw DomainError('divide by zero');
  return a ~/ b;
}

void main() {
  print(safeDivide(10, 2));

  try {
    safeDivide(10, 0);
  } on DomainError catch (e) {
    print('caught: ${e.reason}');
  }

  try {
    throw 'bare string';
  } catch (e) {
    print('untyped caught: $e');
  }

  // Rethrow through a nested catch.
  try {
    try {
      safeDivide(1, 0);
    } on DomainError {
      print('inner');
      rethrow;
    }
  } catch (e) {
    print('outer caught');
  }
}
