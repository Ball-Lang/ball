/// Regenerate the auto-generated Ball fixtures from Dart source files.
///
/// Reads every `tests/fixtures/dart/*.dart` file, runs it through
/// [DartEncoder], and writes the resulting `.ball.json` (plus a
/// `.expected_output.txt` captured from `dart run`) into
/// `tests/fixtures/dart/_generated/`.
///
/// Normally this happens as a byproduct of the cross-language test,
/// but that test takes minutes. When you're iterating on a single
/// fixture you want a sub-second regen:
///
///     dart run ball_encoder:regen_fixtures [fixture_name]
///
/// With no argument, regenerates every fixture. With a name (with or
/// without the `.dart` extension) regenerates only that one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_encoder/encoder.dart';

Future<void> main(List<String> args) async {
  // Resolve the fixtures dir relative to the current working directory,
  // then walk up to find `tests/fixtures/dart`. Supports running from
  // the package root, the monorepo root, or anywhere in between.
  final fixturesDir = _findFixturesDir();
  if (fixturesDir == null) {
    stderr.writeln(
      'error: could not find tests/fixtures/dart from ${Directory.current.path}',
    );
    exit(1);
  }
  final outDir = Directory('${fixturesDir.path}/_generated');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  final filter = args.isNotEmpty
      ? args.first.replaceAll('.dart', '')
      : null;

  final targets = fixturesDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) {
        if (filter == null) return true;
        final name = f.uri.pathSegments.last.replaceAll('.dart', '');
        return name == filter;
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (targets.isEmpty) {
    stderr.writeln('error: no matching fixtures found');
    exit(1);
  }

  var failed = 0;
  final sw = Stopwatch()..start();
  for (final fixture in targets) {
    final name = fixture.uri.pathSegments.last.replaceAll('.dart', '');
    try {
      final source = fixture.readAsStringSync();
      final program = DartEncoder().encode(source);

      File('${outDir.path}/$name.ball.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(program.toProto3Json()),
      );

      final r = Process.runSync(
        Platform.resolvedExecutable,
        ['run', fixture.absolute.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (r.exitCode != 0) {
        stderr.writeln('$name: dart run failed rc=${r.exitCode}');
        stderr.writeln(r.stderr);
        failed++;
        continue;
      }
      final expected = (r.stdout as String)
          .replaceAll('\r\n', '\n')
          .trimRight();
      File('${outDir.path}/$name.expected_output.txt')
          .writeAsStringSync('$expected\n');

      stdout.writeln('  $name');
    } catch (e) {
      stderr.writeln('$name: $e');
      failed++;
    }
  }
  sw.stop();

  stdout.writeln(
    '\nRegenerated ${targets.length - failed}/${targets.length} '
    'fixtures in ${sw.elapsed.inMilliseconds}ms.',
  );
  if (failed > 0) exit(1);
}

Directory? _findFixturesDir() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    final candidate = Directory('${dir.path}/tests/fixtures/dart');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
