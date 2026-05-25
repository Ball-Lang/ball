void level3() {
  throw 'deep-error';
}

void level2() {
  try {
    level3();
  } catch (e) {
    print('L2:$e');
    rethrow;
  }
}

void level1() {
  try {
    level2();
  } catch (e) {
    print('L1:$e');
    rethrow;
  }
}

void main() {
  try {
    level1();
  } catch (e) {
    print('L0:$e');
  }
}
