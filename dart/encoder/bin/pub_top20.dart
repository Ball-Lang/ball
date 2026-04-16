/// Top-20 pub package validation harness.
///
/// Downloads popular pub packages, encodes each to Ball, runs capability
/// analysis, and reports pass/fail. Run from dart/:
///
///   dart run ball_encoder:pub_top20 [--filter <name>]
library;

import 'dart:io';

import 'package:ball_base/capability_analyzer.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';

const _packages = [
  'path',
  'collection',
  'meta',
  'async',
  'crypto',
  'convert',
  'logging',
  'args',
  'string_scanner',
  'stack_trace',
  'source_span',
  'typed_data',
  'term_glyph',
  'matcher',
  'boolean_selector',
  'pool',
  'yaml',
  'glob',
  'watcher',
  'shelf',
];

class _Result {
  final String package;
  final String version;
  final bool encodeSuccess;
  final String? encodeError;
  final int moduleCount;
  final int functionCount;
  final bool isPure;
  final Set<String> capabilities;
  final Duration encodeTime;

  _Result({
    required this.package,
    required this.version,
    required this.encodeSuccess,
    this.encodeError,
    this.moduleCount = 0,
    this.functionCount = 0,
    this.isPure = true,
    this.capabilities = const {},
    this.encodeTime = Duration.zero,
  });
}

Future<void> main(List<String> args) async {
  final filter = args.indexOf('--filter');
  final filterName =
      filter >= 0 && filter + 1 < args.length ? args[filter + 1] : null;

  final packages = filterName != null
      ? _packages.where((p) => p.contains(filterName)).toList()
      : _packages;

  final client = PubClient();
  final results = <_Result>[];

  stdout.writeln('Ball Top-20 Pub Package Validation');
  stdout.writeln('=' * 50);
  stdout.writeln('Packages to test: ${packages.length}');
  stdout.writeln();

  for (final name in packages) {
    stdout.write('  $name... ');
    try {
      final versionInfo = await client.resolveVersion(name, 'any');
      final version = versionInfo.version;
      stdout.write('v$version ');

      final pkgDir = await client.downloadPackage(
        name,
        version,
        archiveUrl: versionInfo.archiveUrl,
      );

      final sw = Stopwatch()..start();
      try {
        final encoder = PackageEncoder(pkgDir);
        final program = encoder.encode();
        sw.stop();

        final report = analyzeCapabilities(program);
        final caps = report.capabilities
            .where((c) => c.capability != 'pure')
            .map((c) => c.capability)
            .toSet();

        var fnCount = 0;
        for (final m in program.modules) {
          fnCount += m.functions.length;
        }

        results.add(_Result(
          package: name,
          version: version,
          encodeSuccess: true,
          moduleCount: program.modules.length,
          functionCount: fnCount,
          isPure: report.summary.isPure,
          capabilities: caps,
          encodeTime: sw.elapsed,
        ));

        stdout.writeln(
          'OK (${program.modules.length} modules, $fnCount fns, '
          '${sw.elapsedMilliseconds}ms, '
          '${caps.isEmpty ? "pure" : caps.join("+")})',
        );
      } catch (e) {
        sw.stop();
        results.add(_Result(
          package: name,
          version: version,
          encodeSuccess: false,
          encodeError: e.toString().split('\n').first,
          encodeTime: sw.elapsed,
        ));
        stdout.writeln('FAIL: ${e.toString().split('\n').first}');
      }

      try {
        await pkgDir.delete(recursive: true);
      } catch (_) {}
    } catch (e) {
      results.add(_Result(
        package: name,
        version: '?',
        encodeSuccess: false,
        encodeError: 'Download failed: ${e.toString().split('\n').first}',
      ));
      stdout.writeln('DOWNLOAD FAIL: ${e.toString().split('\n').first}');
    }
  }

  stdout.writeln();
  stdout.writeln('=' * 50);
  final passed = results.where((r) => r.encodeSuccess).length;
  final failed = results.where((r) => !r.encodeSuccess).length;
  final pct = results.isEmpty ? 0.0 : passed * 100.0 / results.length;
  stdout.writeln(
      'Results: $passed passed, $failed failed, ${results.length} total');
  stdout.writeln('Success rate: ${pct.toStringAsFixed(1)}%');

  if (failed > 0) {
    stdout.writeln();
    stdout.writeln('Failures:');
    for (final r in results.where((r) => !r.encodeSuccess)) {
      stdout.writeln('  ${r.package}@${r.version}: ${r.encodeError}');
    }
  }

  client.close();
}
