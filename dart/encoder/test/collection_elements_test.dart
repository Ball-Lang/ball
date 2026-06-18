/// Regression tests for the collection-element bug family (issue #55):
/// collection-`for` (C-style + for-each), collection-`if`, and spread elements
/// inside list / set / map literals must round-trip Dart -> Ball -> engine with
/// the SAME result as native Dart.
///
/// Expected values below are the verified native-Dart outputs (the oracle).
/// These run on the AUTHORED Dart engine; the same constructs are locked across
/// the TS and C++ engines by the generated conformance fixtures
/// (tests/conformance/src/30[789]_*.dart, 310_*.dart).
library;

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Encode [src] (a full Dart program with a `main`) to Ball and run it on the
/// engine, returning the captured stdout joined by newlines.
Future<String> _run(String src) async {
  final program = DartEncoder().encode(src);
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add, stderr: lines.add);
  await engine.run();
  return lines.join('\n');
}

void main() {
  group('list comprehension elements', () {
    test('C-style collection-for (issue #55 minimal repro)', () async {
      expect(
        await _run(
          'void main() { print([for (var i = 0; i < 3; i++) i * i]); }',
        ),
        '[0, 1, 4]',
      );
    });

    test('for-each collection-for', () async {
      expect(
        await _run(
          'void main() { final a = [1, 2]; print([for (var x in a) x * x]); }',
        ),
        '[1, 4]',
      );
    });

    test('collection-if', () async {
      expect(
        await _run(
          'void main() { print([for (var i = 0; i < 5; i++) if (i % 2 == 0) i]); }',
        ),
        '[0, 2, 4]',
      );
    });

    test('nested collection-for', () async {
      expect(
        await _run(
          'void main() { print([for (var i = 0; i < 3; i++) for (var j = 0; j < 2; j++) i * 10 + j]); }',
        ),
        '[0, 1, 10, 11, 20, 21]',
      );
    });

    test('spread splices (not nests)', () async {
      expect(
        await _run('void main() { final a = [1, 2]; print([0, ...a, 3]); }'),
        '[0, 1, 2, 3]',
      );
    });

    test('null-aware spread skips null and splices non-null', () async {
      expect(
        await _run(
          'void main() { List<int>? n = null; final a = [1, 2]; print([0, ...?n, 3]); print([0, ...?a, 3]); }',
        ),
        '[0, 3]\n[0, 1, 2, 3]',
      );
    });
  });

  group('set comprehension elements', () {
    test('set comprehension', () async {
      expect(
        await _run(
          'void main() { print({for (var i = 0; i < 3; i++) i * i}.toList()); }',
        ),
        '[0, 1, 4]',
      );
    });

    test('set spread', () async {
      expect(
        await _run('void main() { final a = [1, 2]; print({0, ...a}); }'),
        '{0, 1, 2}',
      );
    });
  });

  group('map comprehension elements', () {
    test('map comprehension (misclassified as set today)', () async {
      expect(
        await _run(
          'void main() { print({for (var i = 1; i <= 2; i++) i: i * i}); }',
        ),
        '{1: 1, 2: 4}',
      );
    });

    test('map spread', () async {
      expect(
        await _run('void main() { final m = {1: 2}; print({0: 0, ...m}); }'),
        '{0: 0, 1: 2}',
      );
    });
  });
}
