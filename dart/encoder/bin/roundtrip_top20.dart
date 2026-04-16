/// Round-trip validation: encode top pub packages, compile all modules back
/// to Dart, report per-module compile success rate.
///
///   dart run ball_encoder:roundtrip_top20 [--filter <name>]
library;

import 'dart:io';

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';

const _packages = [
  'path', 'collection', 'meta', 'async', 'crypto',
  'convert', 'logging', 'args', 'string_scanner', 'stack_trace',
  'source_span', 'typed_data', 'term_glyph', 'matcher',
  'boolean_selector', 'pool', 'yaml', 'glob', 'watcher', 'shelf',
];

Future<void> main(List<String> args) async {
  final filter = args.indexOf('--filter');
  final filterName = filter >= 0 && filter + 1 < args.length ? args[filter + 1] : null;
  final packages = filterName != null
      ? _packages.where((p) => p.contains(filterName)).toList()
      : _packages;

  final client = PubClient();
  var totalModules = 0;
  var compiledModules = 0;
  var totalPackages = 0;
  var fullSuccessPackages = 0;

  stdout.writeln('Ball Round-Trip Validation (encode → compile back)');
  stdout.writeln('=' * 55);

  for (final name in packages) {
    stdout.write('  $name... ');
    try {
      final vi = await client.resolveVersion(name, 'any');
      final pkgDir = await client.downloadPackage(name, vi.version, archiveUrl: vi.archiveUrl);

      final encoder = PackageEncoder(pkgDir);
      final program = encoder.encode();
      final compiler = DartCompiler(program, noFormat: true);
      final modules = compiler.compileAllModules();

      // Count non-base, non-stub modules (those with actual content).
      final contentModules = program.modules.where((m) {
        final allBase = m.functions.every((f) => f.isBase) && m.functions.isNotEmpty;
        if (allBase) return false;
        if (m.functions.isEmpty && m.typeDefs.isEmpty && m.types.isEmpty) return false;
        if (m.name == '__assets__') return false;
        return true;
      }).length;

      totalModules += contentModules;
      compiledModules += modules.length;
      totalPackages++;
      if (modules.length >= contentModules) fullSuccessPackages++;

      final stubs = program.modules.length - contentModules -
          program.modules.where((m) => m.functions.every((f) => f.isBase) && m.functions.isNotEmpty).length;
      stdout.writeln('${modules.length}/$contentModules modules OK, $stubs stubs skipped (v${vi.version})');

      try { await pkgDir.delete(recursive: true); } catch (_) {}
    } catch (e) {
      stdout.writeln('FAIL: ${e.toString().split('\n').first}');
      totalPackages++;
    }
  }

  stdout.writeln();
  stdout.writeln('=' * 55);
  stdout.writeln('Packages: $fullSuccessPackages/$totalPackages fully compiled');
  stdout.writeln('Modules: $compiledModules/$totalModules compiled');
  final pct = totalModules == 0 ? 0.0 : compiledModules * 100.0 / totalModules;
  stdout.writeln('Module compile rate: ${pct.toStringAsFixed(1)}%');

  client.close();
}
