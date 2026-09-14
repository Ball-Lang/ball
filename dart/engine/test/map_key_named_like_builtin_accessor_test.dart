/// A MAP key named like a built-in accessor is just a key; the accessor still
/// answers from the map itself (issue #697 B).
///
/// A Ball map and a Ball class instance share ONE runtime representation
/// (`Map<String, Object?>`), and `_evalFieldAccess` resolved both by looking the
/// field name up as a KEY first. That is the right precedence for an instance —
/// its own field must beat the built-in emulation, which is exactly what #681
/// pins — and the wrong one for a map, where `Map.length` is the entry count and
/// a `'length'` key is reachable only through `m['length']`.
///
/// The two are told apart by the tags the engine stamps on an object
/// (`__type__` / `__methods__` / `__super__`), so both directions are asserted
/// here: a fix for one must not silently undo the other. Every expectation is
/// what native `dart run` prints — the same oracle
/// `tests/conformance/474_map_key_named_like_builtin_accessor` uses.
@TestOn('vm')
library;

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

Future<List<String>> runSource(String source) async {
  final program = DartEncoder().encode(source, name: 'main');
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add);
  await engine.run();
  return lines;
}

void main() {
  group('engine: a map key named like a built-in accessor (#697)', () {
    test('`.length` is the entry count, `[\'length\']` is the key', () async {
      expect(
        await runSource('''
void main() {
  Map<String, int> m = <String, int>{'length': 99, 'a': 1};
  print(m.length);
  print(m['length']);
}
'''),
        ['2', '99'],
      );
    });

    test('every Map accessor beats a key of the same name', () async {
      expect(
        await runSource('''
void main() {
  Map<String, Object?> m = <String, Object?>{
    'keys': 'k',
    'values': 'v',
    'entries': 'e',
    'isEmpty': 'ie',
    'isNotEmpty': 'ine',
    'length': 'l',
  };
  print(m.length);
  print(m.isEmpty);
  print(m.isNotEmpty);
  print(m.keys.toList());
  print(m.values.toList());
}
'''),
        [
          '6',
          'false',
          'true',
          '[keys, values, entries, isEmpty, isNotEmpty, length]',
          '[k, v, e, ie, ine, l]',
        ],
      );
    });

    test('an empty map still answers its own accessors', () async {
      expect(
        await runSource('''
void main() {
  Map<String, int> m = <String, int>{};
  print(m.length);
  print(m.isEmpty);
  print(m.isNotEmpty);
  print(m.keys.toList());
}
'''),
        ['0', 'true', 'false', '[]'],
      );
    });

    test('an INSTANCE field of that name still beats the emulation', () async {
      // The opposite direction (#681's precedence). A `Tagged` instance carries
      // `__type__`, so the key lookup must keep winning there.
      expect(
        await runSource('''
class Tagged {
  int length;
  List<String> keys;
  Tagged(this.length, this.keys);
}

void main() {
  Tagged t = Tagged(3, <String>['x']);
  print(t.length);
  print(t.keys);
}
'''),
        ['3', '[x]'],
      );
    });

    test('a SUBCLASS instance field of that name beats the emulation', () async {
      // An inherited field is reached through `__super__`, the third instance
      // tag — an object whose OWN map carries only `__super__` must still count
      // as an instance.
      expect(
        await runSource('''
class Base {
  int length;
  Base(this.length);
}

class Derived extends Base {
  Derived(int v) : super(v);
}

void main() {
  Derived d = Derived(7);
  print(d.length);
}
'''),
        ['7'],
      );
    });
  });
}
