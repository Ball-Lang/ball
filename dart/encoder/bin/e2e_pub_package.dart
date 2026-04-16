/// End-to-end test: download a pub package, encode to Ball, audit capabilities,
/// compile back to Dart, and write the output.
///
///   dart run ball_encoder:e2e_pub_package <package-name> [--version <ver>]
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/capability_analyzer.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: e2e_pub_package <package-name> [--version <ver>]');
    exit(1);
  }

  final name = args.first;
  final verIdx = args.indexOf('--version');
  final constraint =
      verIdx >= 0 && verIdx + 1 < args.length ? args[verIdx + 1] : 'any';

  final client = PubClient();

  stdout.writeln('1. Resolving $name@$constraint from pub.dev...');
  final versionInfo = await client.resolveVersion(name, constraint);
  stdout.writeln('   Resolved: v${versionInfo.version}');

  stdout.writeln('2. Downloading package archive...');
  final pkgDir = await client.downloadPackage(
    name,
    versionInfo.version,
    archiveUrl: versionInfo.archiveUrl,
  );
  stdout.writeln('   Extracted to: ${pkgDir.path}');

  stdout.writeln('3. Encoding to Ball...');
  final sw = Stopwatch()..start();
  final encoder = PackageEncoder(pkgDir);
  final program = encoder.encode();
  sw.stop();

  var fnCount = 0;
  for (final m in program.modules) {
    fnCount += m.functions.length;
  }
  stdout.writeln(
    '   ${program.modules.length} modules, $fnCount functions '
    '(${sw.elapsedMilliseconds}ms)',
  );

  stdout.writeln('4. Capability audit...');
  final report = analyzeCapabilities(program);
  stdout.writeln(formatCapabilityReport(report));

  stdout.writeln('5. Compiling back to Dart...');
  try {
    final compiler = DartCompiler(program);
    final dartSource = compiler.compile();
    final outPath = '/tmp/ball_e2e_${name}.dart';
    File(outPath).writeAsStringSync(dartSource);
    stdout.writeln('   Dart output: $outPath (${dartSource.length} chars)');
    stdout.writeln('   First 500 chars:');
    stdout.writeln(dartSource.substring(0, dartSource.length.clamp(0, 500)));
  } catch (e) {
    stderr.writeln('   Compile failed: $e');
  }

  // Write Ball JSON
  final jsonOut = const JsonEncoder.withIndent('  ')
      .convert(jsonDecode(jsonEncode(program.toProto3Json())));
  final ballPath = '/tmp/ball_e2e_${name}.ball.json';
  File(ballPath).writeAsStringSync(jsonOut);
  stdout.writeln('\n6. Ball JSON: $ballPath (${jsonOut.length} chars)');

  // Cleanup
  try {
    await pkgDir.delete(recursive: true);
  } catch (_) {}
  client.close();

  stdout.writeln('\nDone.');
}
