Future<int> innerFail(int n) async {
  throw 'inner-boom';
}

Future<int> middle(int n) async {
  try {
    return await innerFail(0);
  } catch (e) {
    print('middle saw: $e');
    rethrow;
  }
}

Future<void> main() async {
  try {
    await middle(0);
  } catch (err) {
    print('outer caught: $err');
  }
}
