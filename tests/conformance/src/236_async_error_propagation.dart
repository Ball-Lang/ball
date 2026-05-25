Future<int> fail() async {
  throw 'async-failure';
}

Future<int> ok() async {
  return 7;
}

Future<void> main() async {
  try {
    await ok();
    print('ok-before-fail');
    await fail();
    print('unreachable');
  } catch (e) {
    print('caught:$e');
  }
  print(await ok());
}
