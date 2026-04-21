void main() {
  try {
    try {
      throw 'inner';
    } catch (e) {
      print('caught inner: $e');
      throw 'rethrown';
    }
  } catch (e) {
    print('caught outer: $e');
  } finally {
    print('finally');
  }
  print('after');
}
