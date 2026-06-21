/// Generates the `ball_protobuf` library from the protobuf Dart source files.
///
/// Encodes each protobuf implementation file under dart/shared/lib/protobuf/
/// into a Ball [Module], then assembles them into a single **facade [Module]**
/// whose `module_imports[]` embed each implementation module inline via
/// [InlineSource] (`json` = `jsonEncode(m.toProto3Json())`, a bare proto3
/// module — decode with `mergeFromProto3Json`). This keeps `ball_protobuf` a single,
/// self-contained file while preserving its internal multi-module structure —
/// and, unlike the previous `Program`-with-empty-`entry_function` shape, it is a
/// real reusable library with no fake entry point (see docs/EDITIONS_PLAN.md
/// §2.1). std / std_collections / proto are intentionally NOT
/// bundled: a library does not ship std; the consuming program or engine
/// provides it.
///
/// The output is wrapped in the self-describing `BallFile` Any envelope as
/// `ball.v1.Module` (`@type` in JSON), so it round-trips through
/// `decodeModuleJson` / `decodeModuleBinary`.
///
/// Usage:
///   cd dart/encoder && dart run bin/gen_ball_protobuf.dart [output_dir]
///
/// Outputs:
///   ball_protobuf.json — proto3 JSON (human-readable)
///   ball_protobuf.bin  — binary protobuf (compact)
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show encodeBallFileBinary, encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_encoder/encoder.dart';

/// Protobuf source files to encode, in dependency order.
/// Each path is relative to the ball_protobuf package root (dart/ball_protobuf/).
const _sourceFiles = [
  'lib/edition.dart',
  'lib/wire_varint.dart',
  'lib/wire_fixed.dart',
  'lib/wire_bytes.dart',
  'lib/field_int.dart',
  'lib/field_fixed.dart',
  'lib/field_len.dart',
  'lib/marshal.dart',
  'lib/unmarshal.dart',
  'lib/json_codec.dart',
  'lib/well_known.dart',
  'lib/editions.dart',
  'lib/grpc_frame.dart',
];

/// Map from relative file path to Ball module name.
String _fileToModule(String relPath) {
  // lib/protobuf/wire_varint.dart -> ball_protobuf.wire_varint
  final fileName = relPath.split('/').last.replaceAll('.dart', '');
  return 'ball_protobuf.$fileName';
}

/// Build URI-to-module overrides for relative imports between protobuf files.
///
/// For example, `wire_varint.dart` imported from `marshal.dart` resolves to
/// `ball_protobuf.wire_varint`.
Map<String, String> _buildUriOverrides() {
  final overrides = <String, String>{};
  for (final path in _sourceFiles) {
    final fileName = path.split('/').last;
    overrides[fileName] = _fileToModule(path);
  }
  return overrides;
}

void main(List<String> args) {
  // The compiled artifact stays in ball_base (dart/shared) — it is a build
  // output for downstream targets, not part of the published ball_protobuf
  // source package. The engine sources are read from the ball_protobuf package.
  final outputDir = args.isNotEmpty ? args[0] : '../shared';
  final pkgRoot = '../ball_protobuf';

  final uriOverrides = _buildUriOverrides();
  final encoder = DartEncoder();
  final implModules = <Module>[];

  for (final relPath in _sourceFiles) {
    final file = File('$pkgRoot/$relPath');
    if (!file.existsSync()) {
      stderr.writeln('ERROR: Source file not found: ${file.path}');
      exit(1);
    }

    final source = file.readAsStringSync();
    final moduleName = _fileToModule(relPath);

    final (:module, importStubs: _) = encoder.encodeModule(
      source,
      moduleName: moduleName,
      uriToModuleOverrides: uriOverrides,
    );
    implModules.add(module);
  }

  // Facade Module: a real reusable library (no entry point) whose
  // module_imports embed each implementation module inline. Cross-module calls
  // already reference modules by their own names (ball_protobuf.<file>), so the
  // import alias is the module's own name. std/std_collections/proto
  // are NOT bundled — the consuming program or engine provides them.
  final facade = Module()
    ..name = 'ball_protobuf'
    ..description =
        'Editions-capable, portable protobuf engine authored in Ball-portable '
        'Dart and compiled to every target language. Self-contained: each '
        'implementation module is embedded inline.'
    ..moduleImports.addAll([
      for (final m in implModules)
        ModuleImport()
          ..name = m.name
          ..inline = (InlineSource()..json = jsonEncode(m.toProto3Json())),
    ]);

  // Write proto3 JSON (self-describing Any envelope -> ball.v1.Module).
  final jsonOutput = encodeBallFileJson(facade);
  final jsonString = const JsonEncoder.withIndent('  ').convert(jsonOutput);
  File('$outputDir/ball_protobuf.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('$jsonString\n');

  // Write binary protobuf (serialized Any).
  File(
    '$outputDir/ball_protobuf.bin',
  ).writeAsBytesSync(encodeBallFileBinary(facade));

  // Summary.
  var totalFunctions = 0;
  for (final m in implModules) {
    totalFunctions += m.functions.length;
  }
  stderr.writeln(
    'Generated ball_protobuf facade Module: '
    '${facade.moduleImports.length} inline modules, '
    '$totalFunctions total functions',
  );
  stderr.writeln('  -> $outputDir/ball_protobuf.json');
  stderr.writeln('  -> $outputDir/ball_protobuf.bin');
}
