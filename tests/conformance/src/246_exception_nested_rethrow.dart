void throwA() {
  throw 'A';
}

void throwB() {
  try {
    throwA();
  } catch (e) {
    print('B-caught:$e');
    throw 'B-wrapped';
  }
}

void main() {
  try {
    try {
      throwB();
    } catch (e) {
      print('outer-1:$e');
      rethrow;
    }
  } catch (e) {
    print('outer-2:$e');
  }
}
