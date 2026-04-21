void main() {
  try {
    print('try');
    throw 'error';
  } catch (e) {
    print('caught: $e');
  } finally {
    print('finally');
  }
}
