Future<int> failAsync(int n) async {
  throw 'AsyncError';
}

Future<void> main() async {
  try {
    await failAsync(0);
  } catch (e) {
    print('error-caught');
  }
}
