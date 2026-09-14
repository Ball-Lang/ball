// #697 B - a MAP key named like a built-in accessor is just a key; the
// accessor still answers from the map itself.
//
// A Ball map and a Ball class instance share one runtime representation (a
// `Map<String, Object?>`), and the reference engine's `_evalFieldAccess`
// resolved BOTH by looking the field name up as a key first. That is the right
// precedence for an instance - its own field must beat the built-in emulation,
// which is exactly what #681 pins - and the wrong one for a map, where
// `Map.length` is the entry count and a `'length'` KEY is just a key.
//
// The discriminator is the `__type__` tag an instance carries and a plain map
// does not; this fixture pins both directions so a fix for one cannot silently
// undo the other.

class Tagged {
  int length;
  bool isEmpty;
  List<String> keys;

  Tagged(this.length, this.isEmpty, this.keys);
}

void main() {
  Map<String, int> m = <String, int>{'length': 99, 'a': 1};
  print(m.length); // the entry count, not 99
  print(m['length']); // the key's value
  print(m.isEmpty);
  print(m.isNotEmpty);

  Map<String, Object?> shadowed = <String, Object?>{
    'keys': 'k',
    'values': 'v',
    'entries': 'e',
    'isEmpty': 'ie',
    'isNotEmpty': 'ine',
    'length': 'l',
  };
  print(shadowed.length);
  print(shadowed.isEmpty);
  print(shadowed.isNotEmpty);
  print(shadowed.keys.toList());
  print(shadowed.values.toList());
  print(shadowed['keys']);
  print(shadowed['values']);
  print(shadowed['entries']);
  print(shadowed['isEmpty']);
  print(shadowed['isNotEmpty']);
  print(shadowed['length']);

  Map<String, int> empty = <String, int>{};
  print(empty.length);
  print(empty.isEmpty);
  print(empty.isNotEmpty);

  // The opposite direction: an INSTANCE field named like a built-in accessor
  // must still beat the emulation (the #681 precedence, kept green here).
  Tagged t = Tagged(3, true, <String>['x']);
  print(t.length);
  print(t.isEmpty);
  print(t.keys);
}
