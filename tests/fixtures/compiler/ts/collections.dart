// Only exercises List operations — all supported via Array.prototype
// polyfills in the runtime preamble.
//
// Map with bracket assignment (`m['k'] = v`) is a documented known gap:
// JS Maps don't support `[] =`, and polyfilling that via Proxy carries
// performance cost. Ball programs that need map writes must use
// explicit `.put(k, v)` via a future encoder mapping (Phase 2.4b TBD).
void main() {
  final list = <int>[];
  list.add(1);
  list.add(2);
  list.add(3);
  print(list.length);
  print(list.first);
  print(list.last);
  print(list.isEmpty);
  print(list.isNotEmpty);

  final removed = list.removeLast();
  print(removed);
  print(list.length);

  final big = <int>[1, 2, 3, 4, 5];
  final evens = big.where((n) => n % 2 == 0).toList();
  print(evens.length);
  print(evens[0]);
  print(evens[1]);

  // containsKey-like via contains (Array.prototype.indexOf)
  print(big.contains(3));
  print(big.contains(99));
}
