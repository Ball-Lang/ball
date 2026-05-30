/// Conformance test program entrypoint for the upstream protobuf
/// `conformance_test_runner`.
///
/// The runner spawns this process once and streams size-prefixed
/// `ConformanceRequest`s over stdin, reading `ConformanceResponse`s from stdout
/// until EOF. We build a descriptor registry (with per-field resolved Editions
/// features) from a protoc `FileDescriptorSet`, then drive `ball_protobuf`'s
/// feature-aware codecs via the shared loop in `lib/conformance.dart`.
///
/// Lives in `tool/` (not `bin/`): it depends on `ball_base` (a dev-dependency,
/// for the generated descriptor types), so it must not be a published package
/// executable. Run it for the conformance suite as:
///
///   dart compile exe dart/ball_protobuf/tool/conformance_main.dart -o ball_conformance
///   conformance_test_runner --maximum_edition 2023 \
///     --failure_list dart/ball_protobuf/conformance/failure_list_ball.txt \
///     -- ./ball_conformance
///
/// Optional arg0: path to the FileDescriptorSet (defaults to a walk-up search
/// for tests/editions/descriptors/test_messages.fds.binpb).
library;

import 'dart:io';

import 'package:ball_protobuf/conformance.dart' show runConformanceLoop;

import 'descriptor_bridge.dart';

void main(List<String> args) {
  final fdsPath = args.isNotEmpty ? args[0] : _findDescriptorSet();
  final registry = buildRegistry(File(fdsPath).readAsBytesSync());
  runConformanceLoop(registry);
}

/// Walks up from the current directory to locate the checked-in conformance
/// FileDescriptorSet, so the program works regardless of the runner's CWD.
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
  stderr.writeln(
    'conformance: could not locate $rel from ${Directory.current.path}; '
    'pass the FileDescriptorSet path as the first argument.',
  );
  exit(70);
}
