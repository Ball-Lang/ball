/// Generates the cross-target editions-resolver conformance program.
///
/// This is the Phase 6 portability proof (see docs/EDITIONS_SPEC.md): it encodes the
/// REAL editions resolver (`edition.dart` + `editions.dart`, the same sources
/// that ship in `ball_protobuf`) plus a small driver into a self-contained Ball
/// Program, and drops it into `tests/conformance/`. The existing conformance
/// matrix then runs that one program on the Dart, TypeScript, and C++ engines
/// and asserts byte-identical stdout against the checked-in
/// `*.expected_output.txt` — proving the Ball-source editions engine resolves
/// identically on every target.
///
/// Regenerate whenever edition.dart / editions.dart change:
///   cd dart/encoder && dart run tool/gen_editions_conformance.dart
/// then re-run the Dart engine to refresh the expected_output (the tool does
/// not write expected_output; run_conformance / the harness produces it).
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart' show encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_encoder/encoder.dart';

/// Driver: exercises the resolver deterministically. Output is formatted via
/// the fixed `featureKeys()` order (no sort) and manual string concatenation
/// (no join), so it is identical across engines regardless of map-iteration or
/// list-formatting differences.
const _driverSource = r'''
import 'editions.dart';

String fmtFeatures(Map<String, String> f) {
  var out = '';
  final keys = featureKeys();
  for (var i = 0; i < keys.length; i++) {
    if (i > 0) {
      out = out + ',';
    }
    final v = f[keys[i]];
    out = out + keys[i] + '=' + (v == null ? '?' : v);
  }
  return out;
}

void main() {
  print('2023: ' + fmtFeatures(baseFeaturesForEdition(1000)));
  print('proto3: ' + fmtFeatures(baseFeaturesForEdition(999)));
  print('legacy: ' + fmtFeatures(baseFeaturesForEdition(900)));
  print('2023+IMPLICIT: ' +
      fmtFeatures(
          resolveFeatures('2023', null, null, {'field_presence': 'IMPLICIT'})));
}
''';

void main() {
  const sharedRoot = '../shared';
  final encoder = DartEncoder();
  final uriOverrides = {'edition.dart': 'edition', 'editions.dart': 'editions'};

  Module encodeSource(String relPath, String moduleName) {
    final file = File('$sharedRoot/$relPath');
    if (!file.existsSync()) {
      stderr.writeln('ERROR: source not found: ${file.path}');
      exit(1);
    }
    final (:module, importStubs: _) = encoder.encodeModule(
      file.readAsStringSync(),
      moduleName: moduleName,
      uriToModuleOverrides: uriOverrides,
    );
    return module;
  }

  final editionMod = encodeSource('lib/protobuf/edition.dart', 'edition');
  final editionsMod = encodeSource('lib/protobuf/editions.dart', 'editions');
  final (:module, importStubs: _) = encoder.encodeModule(
    _driverSource,
    moduleName: 'main',
    uriToModuleOverrides: uriOverrides,
  );
  final mainMod = module;

  final std = encoder.buildStdModules();

  final program = Program()
    ..name = 'editions_resolver'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std.stdModule,
      if (std.collectionsModule != null) std.collectionsModule!,
      if (std.protoModule != null) std.protoModule!,
      editionMod,
      editionsMod,
      mainMod,
    ]);

  final jsonOutput = encodeBallFileJson(program);
  final jsonString = const JsonEncoder.withIndent('  ').convert(jsonOutput);
  final outPath = '../../tests/conformance/256_editions_resolver.ball.json';
  File(outPath).writeAsStringSync('$jsonString\n');

  var totalFunctions = 0;
  for (final m in program.modules) {
    totalFunctions += m.functions.length;
  }
  stderr.writeln(
    'Wrote $outPath (${program.modules.length} modules, '
    '$totalFunctions functions)',
  );
}
