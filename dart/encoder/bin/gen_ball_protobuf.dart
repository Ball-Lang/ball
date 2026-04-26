/// Generates the ball_protobuf program from the protobuf Dart source files.
///
/// Encodes each protobuf implementation file under dart/shared/lib/protobuf/
/// into a Ball module, combines them into a single program, and writes both
/// proto3 JSON and binary protobuf output.
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

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_encoder/encoder.dart';

/// Protobuf source files to encode, in dependency order.
/// Each path is relative to the ball_base package root (dart/shared/).
const _sourceFiles = [
  'lib/protobuf/wire_varint.dart',
  'lib/protobuf/wire_fixed.dart',
  'lib/protobuf/wire_bytes.dart',
  'lib/protobuf/field_int.dart',
  'lib/protobuf/field_fixed.dart',
  'lib/protobuf/field_len.dart',
  'lib/protobuf/marshal.dart',
  'lib/protobuf/unmarshal.dart',
  'lib/protobuf/json_codec.dart',
  'lib/protobuf/well_known.dart',
  'lib/protobuf/editions.dart',
  'lib/protobuf/grpc_frame.dart',
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
  final outputDir = args.isNotEmpty ? args[0] : '../shared';
  final sharedRoot = '../shared';

  final uriOverrides = _buildUriOverrides();
  final encoder = DartEncoder();
  final userModules = <Module>[];

  for (final relPath in _sourceFiles) {
    final file = File('$sharedRoot/$relPath');
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
    userModules.add(module);
  }

  final (:stdModule, :dartStdModule, :collectionsModule, :protoModule) =
      encoder.buildStdModules();

  final program = Program()
    ..name = 'ball_protobuf'
    ..version = '1.0.0'
    ..entryModule = 'ball_protobuf.marshal'
    ..entryFunction = ''
    ..modules.addAll([
      stdModule,
      if (dartStdModule != null) dartStdModule,
      if (collectionsModule != null) collectionsModule,
      if (protoModule != null) protoModule,
      ...userModules,
    ]);

  // Write proto3 JSON.
  final jsonOutput = program.toProto3Json();
  final jsonString = const JsonEncoder.withIndent('  ').convert(jsonOutput);
  File('$outputDir/ball_protobuf.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('$jsonString\n');

  // Write binary protobuf.
  File('$outputDir/ball_protobuf.bin')
      .writeAsBytesSync(program.writeToBuffer());

  // Summary.
  var totalFunctions = 0;
  for (final m in program.modules) {
    totalFunctions += m.functions.length;
  }
  stderr.writeln(
    'Generated ball_protobuf: '
    '${program.modules.length} modules, '
    '$totalFunctions total functions',
  );
  stderr.writeln('  -> $outputDir/ball_protobuf.json');
  stderr.writeln('  -> $outputDir/ball_protobuf.bin');
}
