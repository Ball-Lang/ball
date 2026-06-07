void main() {
  try {
    int.parse('not a number');
  } on FormatException catch (e) {
    print('caught-format');
  }
  try {
    throw 'boom';
  } catch (e) {
    print(e);
  }
  print('after');
}
