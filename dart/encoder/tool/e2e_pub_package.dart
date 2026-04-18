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
  final compiler = DartCompiler(program);

  // Try entry-point compile first (for executable packages).
  try {
    final dartSource = compiler.compile();
    final outPath = '/tmp/ball_e2e_${name}.dart';
    File(outPath).writeAsStringSync(dartSource);
    stdout.writeln('   Entry-point compile: $outPath (${dartSource.length} chars)');
  } catch (_) {
    stdout.writeln('   No entry point (library package) — using compileAllModules');
  }

  // Always compile all modules for library packages.
  final allModules = compiler.compileAllModules();
  final outDir = Directory('/tmp/ball_e2e_${name}_modules');
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync(recursive: true);

  var totalChars = 0;
  var compiledCount = 0;
  for (final entry in allModules.entries) {
    final fileName = '${entry.key.replaceAll('.', '_')}.dart';
    File('${outDir.path}/$fileName').writeAsStringSync(entry.value);
    totalChars += entry.value.length;
    compiledCount++;
  }

  // Count modules that were skipped (base, empty stubs).
  final skipped = program.modules.length - compiledCount - program.modules.where(
    (m) => m.functions.every((f) => f.isBase) && m.functions.isNotEmpty,
  ).length;

  stdout.writeln('   Compiled $compiledCount modules to ${outDir.path}/ ($totalChars total chars)');
  if (skipped > 0) stdout.writeln('   Skipped $skipped empty/stub modules');

  // Show a sample of the first compiled module.
  if (allModules.isNotEmpty) {
    final first = allModules.entries.first;
    stdout.writeln('   Sample (${first.key}):');
    stdout.writeln(first.value.substring(0, first.value.length.clamp(0, 400)));
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
