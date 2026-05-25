void main() {
  try {
    try {
      print('try-body');
      throw 'boom';
    } catch (e) {
      print('catch:$e');
    } finally {
      print('finally-1');
    }
  } finally {
    print('outer-finally');
  }

  var x = 0;
  try {
    x = 1;
    throw 'inner';
  } catch (e) {
    x = 2;
    print('recovered:$e');
  } finally {
    print('x-after:$x');
  }
}
