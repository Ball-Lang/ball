void inner() {
  throw 'inner-error';
}

void middle() {
  try {
    inner();
  } catch (e) {
    print('middle caught: $e');
    rethrow;
  }
}

void main() {
  try {
    middle();
  } catch (e) {
    print('outer caught: $e');
  }
}
