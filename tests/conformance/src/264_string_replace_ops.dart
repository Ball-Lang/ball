void main() {
  // replaceFirst (encoder → string_replace)
  print('hello world hello'.replaceFirst('hello', 'hi'));

  // replaceAll (encoder → string_replace_all)
  print('banana'.replaceAll('a', 'o'));

  // lastIndexOf (encoder → string_last_index_of)
  print('abcabc'.lastIndexOf('a'));

  // padLeft / padRight
  print('42'.padLeft(5, '0'));
  print('hi'.padRight(5, '.'));

  // substring
  print('hello world'.substring(6));
  print('hello world'.substring(0, 5));

  // split
  var parts = 'a,b,c'.split(',');
  print(parts.length);
  print(parts[0]);
  print(parts[2]);
}
