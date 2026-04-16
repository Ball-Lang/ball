/// Co19 conformance test suite validation harness.
///
/// Clones dart-lang/co19 (shallow), finds standalone Dart test files,
/// and measures what percentage Ball can encode, execute, and match.
///
/// Run from dart/:
///
///   dart run ball_encoder:co19_validate [--limit N] [--filter pattern]
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';

// ─── Result tracking ────────────────────────────────────────────

class _Result {
  final String path;
  final bool skipped;
  final String? skipReason;
  final bool encodeSuccess;
  final String? encodeError;
  final bool engineSuccess;
  final String? engineError;
  final bool outputMatch;
  final String? dartOutput;
  final String? engineOutput;
  final Duration encodeTime;
  final Duration engineTime;

  _Result({
    required this.path,
    this.skipped = false,
    this.skipReason,
    this.encodeSuccess = false,
    this.encodeError,
    this.engineSuccess = false,
    this.engineError,
    this.outputMatch = false,
    this.dartOutput,
    this.engineOutput,
    this.encodeTime = Duration.zero,
    this.engineTime = Duration.zero,
  });
}

// ─── Skip markers ───────────────────────────────────────────────

/// Lines/patterns in test files that indicate a negative or special test
/// which should be skipped.
const _skipMarkers = [
  '// SharedOptions=--compile-error',
  '// SharedOptions=--enable-experiment',
  '@compile-error',
  '/// [compile-error]',
  '//# 0', // multitest marker format
  'checkCompileError',
  '//#',
];

/// File path segments that indicate non-standalone tests.
const _skipPathSegments = [
  'Utils/',
  'utils/',
  'co19_test_config',
  '_test_config',
];

// ─── Helpers ────────────────────────────────────────────────────

String _norm(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

bool _shouldSkipFile(File file) {
  final path = file.path.replaceAll('\\', '/');

  // Skip utility/helper files.
  for (final seg in _skipPathSegments) {
    if (path.contains(seg)) return true;
  }

  // Skip non-test files (e.g. helper libraries).
  final name = file.uri.pathSegments.last;
  if (!name.endsWith('_t01.dart') &&
      !name.endsWith('_t02.dart') &&
      !name.endsWith('_t03.dart') &&
      !name.endsWith('_t04.dart') &&
      !name.endsWith('_t05.dart') &&
      !name.endsWith('_test.dart') &&
      !name.contains('_A0') &&
      !name.endsWith('.dart')) {
    return true;
  }

  return false;
}

bool _shouldSkipContent(String source) {
  for (final marker in _skipMarkers) {
    if (source.contains(marker)) return true;
  }
  // Skip files that import non-core libraries (co19's Expect, etc.)
  // which Ball can't resolve.
  if (source.contains("import '") || source.contains('import "')) {
    // Allow dart: imports but skip relative/package imports.
    final importPattern = RegExp(r'''import\s+['"](?!dart:)''');
    if (importPattern.hasMatch(source)) return true;
  }
  return false;
}

String? _runDartNative(File dartFile) {
  try {
    final r = Process.runSync(
      Platform.resolvedExecutable,
      ['run', dartFile.absolute.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) return null;
    return _norm(r.stdout as String);
  } catch (_) {
    return null;
  }
}

// ─── Main ───────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  // Parse args.
  int? limit;
  String? filter;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--limit' && i + 1 < args.length) {
      limit = int.tryParse(args[i + 1]);
      i++;
    } else if (args[i] == '--filter' && i + 1 < args.length) {
      filter = args[i + 1];
      i++;
    }
  }

  // Clone co19 to a temp directory.
  final tmpDir = await Directory.systemTemp.createTemp('co19_');
  final co19Dir = tmpDir.path;

  stdout.writeln('Ball co19 Conformance Validation');
  stdout.writeln('=' * 60);
  stdout.writeln('Cloning dart-lang/co19 (shallow) to $co19Dir ...');

  final cloneResult = Process.runSync(
    'git',
    ['clone', '--depth', '1', 'https://github.com/dart-lang/co19.git', '.'],
    workingDirectory: co19Dir,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (cloneResult.exitCode != 0) {
    stderr.writeln('Failed to clone co19: ${cloneResult.stderr}');
    exit(1);
  }
  stdout.writeln('Clone complete.');
  stdout.writeln();

  // Collect test files from Language/ and LanguageFeatures/.
  final testDirs = [
    Directory('$co19Dir/Language'),
    Directory('$co19Dir/LanguageFeatures'),
  ];

  final testFiles = <File>[];
  for (final dir in testDirs) {
    if (!dir.existsSync()) {
      stdout.writeln('Warning: ${dir.path} does not exist, skipping.');
      continue;
    }
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        testFiles.add(entity);
      }
    }
  }

  // Sort for deterministic ordering.
  testFiles.sort((a, b) => a.path.compareTo(b.path));

  // Apply filter.
  var filtered = testFiles;
  if (filter != null) {
    filtered = testFiles
        .where((f) => f.path.replaceAll('\\', '/').contains(filter!))
        .toList();
  }

  stdout.writeln('Found ${testFiles.length} .dart files total.');
  if (filter != null) {
    stdout.writeln('After filter "$filter": ${filtered.length} files.');
  }
  if (limit != null && limit < filtered.length) {
    filtered = filtered.sublist(0, limit);
    stdout.writeln('Limited to $limit files.');
  }
  stdout.writeln();

  // Run tests.
  final results = <_Result>[];
  final total = filtered.length;
  var processed = 0;

  for (final file in filtered) {
    processed++;
    final relPath = file.path
        .replaceAll('\\', '/')
        .replaceFirst('$co19Dir/'.replaceAll('\\', '/'), '');

    // Progress indicator.
    if (processed % 50 == 0 || processed == total) {
      stdout.writeln('  [$processed/$total] ...');
    }

    // Read source.
    final source = await file.readAsString();

    // Check skip conditions.
    if (_shouldSkipFile(file) || _shouldSkipContent(source)) {
      results.add(_Result(
        path: relPath,
        skipped: true,
        skipReason: 'negative test or has imports',
      ));
      continue;
    }

    // Step 1: Try encoding.
    Program? program;
    Duration encodeTime = Duration.zero;
    String? encodeError;
    try {
      final sw = Stopwatch()..start();
      program = DartEncoder().encode(source, name: relPath);
      sw.stop();
      encodeTime = sw.elapsed;
    } catch (e) {
      encodeError = e.toString().split('\n').first;
      results.add(_Result(
        path: relPath,
        encodeSuccess: false,
        encodeError: encodeError,
        encodeTime: encodeTime,
      ));
      continue;
    }

    // Step 2: Run dart natively to get baseline output.
    final dartOutput = _runDartNative(file);
    if (dartOutput == null) {
      // If dart itself can't run it, skip (runtime error test, etc.)
      results.add(_Result(
        path: relPath,
        skipped: true,
        skipReason: 'dart run failed (runtime error test?)',
      ));
      continue;
    }

    // Step 3: Try running through BallEngine.
    String? engineOutput;
    String? engineError;
    Duration engineTime = Duration.zero;
    try {
      final lines = <String>[];
      final sw = Stopwatch()..start();
      final engine = BallEngine(
        program,
        stdout: lines.add,
        stderr: (_) {}, // suppress engine stderr
      );
      engine.run();
      sw.stop();
      engineTime = sw.elapsed;
      engineOutput = _norm(lines.join('\n'));
    } catch (e) {
      engineError = e.toString().split('\n').first;
    }

    final engineSuccess = engineOutput != null;
    final outputMatch = engineSuccess && engineOutput == dartOutput;

    results.add(_Result(
      path: relPath,
      encodeSuccess: true,
      encodeTime: encodeTime,
      engineSuccess: engineSuccess,
      engineError: engineError,
      engineTime: engineTime,
      outputMatch: outputMatch,
      dartOutput: dartOutput,
      engineOutput: engineOutput,
    ));
  }

  // ─── Summary ────────────────────────────────────────────────────

  stdout.writeln();
  stdout.writeln('=' * 60);
  stdout.writeln('RESULTS');
  stdout.writeln('=' * 60);

  final skipped = results.where((r) => r.skipped).length;
  final tested = results.where((r) => !r.skipped).length;
  final encodeOk = results.where((r) => !r.skipped && r.encodeSuccess).length;
  final engineOk = results.where((r) => !r.skipped && r.engineSuccess).length;
  final matchOk = results.where((r) => !r.skipped && r.outputMatch).length;

  stdout.writeln('Total files found:     ${results.length}');
  stdout.writeln('Skipped (imports/neg): $skipped');
  stdout.writeln('Tested:                $tested');
  stdout.writeln();

  if (tested > 0) {
    final encodePct = (encodeOk * 100.0 / tested).toStringAsFixed(1);
    final enginePct = (engineOk * 100.0 / tested).toStringAsFixed(1);
    final matchPct = (matchOk * 100.0 / tested).toStringAsFixed(1);

    stdout.writeln('Encode success:  $encodeOk / $tested ($encodePct%)');
    stdout.writeln('Engine success:  $engineOk / $tested ($enginePct%)');
    stdout.writeln('Output match:    $matchOk / $tested ($matchPct%)');
  } else {
    stdout.writeln('No tests were eligible for testing.');
  }

  // Show some failures for debugging.
  final encodeFails =
      results.where((r) => !r.skipped && !r.encodeSuccess).take(10).toList();
  if (encodeFails.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('Sample encode failures (up to 10):');
    for (final r in encodeFails) {
      stdout.writeln('  ${r.path}');
      stdout.writeln('    ${r.encodeError}');
    }
  }

  final engineFails = results
      .where((r) => !r.skipped && r.encodeSuccess && !r.engineSuccess)
      .take(10)
      .toList();
  if (engineFails.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('Sample engine failures (up to 10):');
    for (final r in engineFails) {
      stdout.writeln('  ${r.path}');
      stdout.writeln('    ${r.engineError}');
    }
  }

  final mismatches = results
      .where((r) => !r.skipped && r.engineSuccess && !r.outputMatch)
      .take(10)
      .toList();
  if (mismatches.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('Sample output mismatches (up to 10):');
    for (final r in mismatches) {
      stdout.writeln('  ${r.path}');
      stdout.writeln('    dart:   ${_truncate(r.dartOutput ?? '', 80)}');
      stdout.writeln('    engine: ${_truncate(r.engineOutput ?? '', 80)}');
    }
  }

  // Timing summary.
  final encodeTimes =
      results.where((r) => !r.skipped && r.encodeSuccess).toList();
  if (encodeTimes.isNotEmpty) {
    final totalEncodeMs =
        encodeTimes.fold<int>(0, (s, r) => s + r.encodeTime.inMilliseconds);
    final avgEncodeMs = totalEncodeMs ~/ encodeTimes.length;
    stdout.writeln();
    stdout.writeln(
        'Avg encode time: ${avgEncodeMs}ms (total: ${totalEncodeMs}ms)');
  }

  final engineTimes =
      results.where((r) => !r.skipped && r.engineSuccess).toList();
  if (engineTimes.isNotEmpty) {
    final totalEngineMs =
        engineTimes.fold<int>(0, (s, r) => s + r.engineTime.inMilliseconds);
    final avgEngineMs = totalEngineMs ~/ engineTimes.length;
    stdout.writeln(
        'Avg engine time: ${avgEngineMs}ms (total: ${totalEngineMs}ms)');
  }

  // Cleanup.
  stdout.writeln();
  stdout.writeln('Cleaning up temp directory...');
  try {
    await tmpDir.delete(recursive: true);
    stdout.writeln('Done.');
  } catch (e) {
    stdout.writeln('Warning: could not delete temp dir: $e');
  }
}

String _truncate(String s, int maxLen) {
  final oneLine = s.replaceAll('\n', '\\n');
  if (oneLine.length <= maxLen) return oneLine;
  return '${oneLine.substring(0, maxLen - 3)}...';
}
