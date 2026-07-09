/// Wave-6 tail-coverage for `package_encoder.dart` (issue #61):
/// `_hasMainFunction`'s untyped `Future main()` regex arm — the third of
/// three patterns tried in order (`void main`, `Future<void> main`, bare
/// `Future main`), only reached when a candidate `bin/*.dart` file's `main`
/// uses the untyped-Future return shape.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

void _write(Directory root, String rel, String content) {
  final f = File('${root.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ball_pkg_wave6_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort temp-dir cleanup only — a failure here (e.g. a file
      // still open on Windows) must not fail the test itself. Mirrors
      // package_encoder_test.dart's tearDown.
    }
  });

  test(
    'auto-detects a bin entry whose main() returns a bare (untyped) Future',
    () {
      _write(tmp, 'pubspec.yaml', 'name: app\nversion: 0.1.0\n');
      _write(tmp, 'bin/worker.dart', '''
Future main() async {
  print('worker');
}
''');
      final program = PackageEncoder(tmp).encode();
      expect(program.entryModule, equals('bin.worker'));
    },
  );
}
