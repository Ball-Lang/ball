void main() {
  try {
    try {
      throw 'inner-boom';
    } catch (e) {
      print('inner caught: $e');
      rethrow;
    }
  } catch (e) {
    print('outer caught: $e');
  }
  print('after');
}
