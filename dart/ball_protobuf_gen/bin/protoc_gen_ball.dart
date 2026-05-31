/// `protoc-gen-ball` — the protoc/buf code-generator plugin entry point.
///
/// A protobuf plugin reads a serialized `CodeGeneratorRequest` from stdin and
/// writes a serialized `CodeGeneratorResponse` to stdout (see plugin.proto).
/// This binary is a **thin stdin/stdout wrapper**: all logic lives in the
/// unit-testable [runPlugin] core in `lib/src/plugin.dart`.
///
/// ## Building
///
/// ```sh
/// cd dart/ball_protobuf_gen
/// dart compile exe bin/protoc_gen_ball.dart -o protoc-gen-ball
/// ```
///
/// (You may also run it unbuilt via `dart run bin/protoc_gen_ball.dart`, but the
/// executable is what `protoc`/`buf` expect on PATH.)
///
/// ## Invoking with protoc
///
/// `protoc` discovers a plugin named `protoc-gen-NAME` on PATH and invokes it
/// for `--NAME_out`:
///
/// ```sh
/// # with ./protoc-gen-ball on PATH (or via --plugin):
/// protoc --plugin=protoc-gen-ball=./protoc-gen-ball \
///        --ball_out=./out \
///        --ball_opt=some=option \
///        path/to/your.proto
/// ```
///
/// ## Invoking with buf
///
/// Add a local plugin entry to `buf.gen.yaml`:
///
/// ```yaml
/// version: v2
/// plugins:
///   - local: ./dart/ball_protobuf_gen/protoc-gen-ball
///     out: gen
///     # opt: some=option
/// ```
///
/// then `buf generate`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';

Future<void> main(List<String> args) async {
  // Read ALL stdin bytes (the serialized CodeGeneratorRequest). protoc/buf
  // close stdin after writing the request, so draining to EOF is correct.
  final requestBytes = await _readAllStdin();

  final List<int> responseBytes;
  try {
    responseBytes = runPlugin(requestBytes);
  } catch (e, st) {
    // Per plugin.proto: a failure to even parse the request is an error in
    // protoc/the plugin itself, not in the user's .proto, so report it on
    // stderr and exit non-zero (errors in the .proto files would instead be
    // returned via CodeGeneratorResponse.error with exit code 0).
    stderr.writeln('protoc-gen-ball: $e');
    stderr.writeln(st);
    exitCode = 1;
    return;
  }

  stdout.add(responseBytes);
  await stdout.flush();
}

/// Drains stdin to EOF and returns the bytes.
Future<List<int>> _readAllStdin() async {
  final chunks = <List<int>>[];
  await for (final chunk in stdin) {
    chunks.add(chunk);
  }
  final total = chunks.fold<int>(0, (n, c) => n + c.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final chunk in chunks) {
    out.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return out;
}
