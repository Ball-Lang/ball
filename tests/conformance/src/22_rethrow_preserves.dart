void main() {
  try {
    try {
      throw 'boom';
    } catch (e) {
      rethrow;
    }
  } catch (e) {
    print('$e');
  }
}
