// Exercises String.runes — the iterable of Unicode code points (regression
// guard for #108). The 'é' (U+00E9 = 233) verifies real code-point decoding,
// not just ASCII code units.
void main() {
  print('abc'.runes.length); // 3
  print('hello'.runes.toList()); // [104, 101, 108, 108, 111]
  print('abc'.runes.first); // 97
  print('xyz'.runes.last); // 122
  print('café'.runes.toList()); // [99, 97, 102, 233]
  print('café'.runes.length); // 4 (code points, not 5 UTF-8 bytes)
}
