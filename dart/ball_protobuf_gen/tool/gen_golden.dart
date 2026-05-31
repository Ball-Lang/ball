/// Regenerates the golden `test/golden/test_messages.pb.dart` from the
/// checked-in conformance `FileDescriptorSet`
/// (`tests/editions/descriptors/test_messages.fds.binpb`).
///
/// Run from the package root:
///
/// ```sh
/// cd dart/ball_protobuf_gen
/// dart run tool/gen_golden.dart
/// ```
///
/// The golden is a single self-contained file holding the generated
/// mutable-over-Map models for every message + enum in the set (proto2,
/// proto3, edition2023 TestAllTypes plus the well-known types). The
/// `message_roundtrip_test.dart` gate imports it directly and proves it
/// round-trips through the `ball_protobuf` runtime; a separate test asserts the
/// committed golden matches a fresh regeneration (drift guard).
library;

import 'dart:io';

import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';

import 'golden_format.dart';

void main() {
  final fdsPath = _findDescriptorSet();
  final fds = File(fdsPath).readAsBytesSync();
  final generated = generateCombinedDartFile(
    fds,
    outputPath: 'test_messages.pb.dart',
  );

  final outDir = Directory(_goldenDir());
  outDir.createSync(recursive: true);
  final outFile = File('${outDir.path}/test_messages.pb.dart');
  // Format the emitted source so the committed golden is formatting-stable
  // (CI runs `dart format --set-exit-if-changed`). [formatGolden] is shared
  // with the drift-guard test so regeneration matches the committed file.
  outFile.writeAsStringSync(formatGolden(generated.content));

  stdout.writeln(
    'Wrote + formatted ${outFile.path} (${outFile.lengthSync()} bytes)',
  );
}

/// Walks up from the CWD to the package root (where `pubspec.yaml` lives) and
/// returns its `test/golden` directory.
String _goldenDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/lib/src').existsSync()) {
      return '${dir.path}/test/golden';
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  // Fallback: assume CWD is the package root.
  return '${Directory.current.path}/test/golden';
}

/// Walks up to the repo-root conformance `FileDescriptorSet`.
String _findDescriptorSet() {
  const rel = 'tests/editions/descriptors/test_messages.fds.binpb';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final f = File('${dir.path}/$rel');
    if (f.existsSync()) return f.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate $rel from ${Directory.current.path}');
}
