void main() {
  var s = 'Hello, World!';
  print(s.contains('World'));
  print(s.contains('xyz'));
  print(s.startsWith('Hello'));
  print(s.endsWith('!'));
  // The FALSE cases matter as much as the true ones. Every corpus use of
  // startsWith/endsWith asserted a true answer, so the TS engine's
  // registerExtraStdFunctions override could read the wrong field names
  // (`value`/`prefix` instead of the canonical BinaryInput `left`/`right`),
  // collapse to `''.startsWith('')` and answer TRUE for everything, unnoticed.
  print(s.startsWith('_'));
  print(s.endsWith('zzz'));
  print(s.startsWith(''));
  print(s.endsWith(''));
  print('aabaa'.replaceAll('a', 'x'));
  print('  hi  '.trimLeft());
  print('  hi  '.trimRight());
  print('foo' + 'bar');
  print('hello'.length);
}
