void failWith(String message) {
  throw message;
}

void main() {
  try {
    try {
      failWith('recoverable');
    } catch (e) {
      print('inner saw: $e');
      if (e == 'recoverable') {
        print('inner handled');
      } else {
        rethrow;
      }
    }
  } catch (e) {
    print('outer should not run: $e');
  }

  try {
    try {
      failWith('propagate-me');
    } catch (e) {
      print('filter saw: $e');
      if (e == 'recoverable') {
        print('wrong branch');
      } else {
        rethrow;
      }
    }
  } catch (e) {
    print('outer caught: $e');
  }
}
