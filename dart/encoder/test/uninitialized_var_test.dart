/// Regression test: an uninitialized variable declaration (`int? n;`,
/// `late String s;`, `var x;`) must round-trip Dart -> Ball -> engine and read
/// back as `null`, matching native Dart. The encoder emits a `__no_init__`
/// sentinel reference as the value; the engine must bind `null` rather than
/// throwing "Undefined variable: __no_init__".
///
/// Found while testing null-aware spread (`[0, ...?n, 3]`) for issue #55.
library;

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

Future<String> _run(String src) async {
  final program = DartEncoder().encode(src);
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add, stderr: lines.add);
  await engine.run();
  return lines.join('\n');
}

void main() {
  test('uninitialized nullable variable reads as null', () async {
    expect(await _run('void main() { int? n; print(n); }'), 'null');
  });

  test('uninitialized variable can be assigned then read', () async {
    expect(await _run('void main() { int n; n = 5; print(n); }'), '5');
  });

  test(
    'uninitialized nullable in a null-aware spread contributes nothing',
    () async {
      expect(
        await _run('void main() { List<int>? xs; print([0, ...?xs, 9]); }'),
        '[0, 9]',
      );
    },
  );
}
