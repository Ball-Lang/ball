/// `protoc-gen-ball-connect` — the SEPARATE Connect/gRPC service-stub plugin.
///
/// Like `protoc-gen-ball`, this is a protobuf code-generator plugin: it reads a
/// serialized `CodeGeneratorRequest` from stdin and writes a serialized
/// `CodeGeneratorResponse` to stdout (see plugin.proto). It is a **thin
/// stdin/stdout wrapper** over the unit-testable [runConnectPlugin] core in
/// `lib/src/plugin.dart`.
///
/// It emits ONLY `<file>.connect.dart` service files (a typed `ball_rpc` client
/// + a `ball_protobuf` `ServiceDescriptor` per service). The message
/// `.pb.dart` files come from the separate `protoc-gen-ball` plugin — a
/// message-only `.proto` produces no output here, and every `.connect.dart`
/// imports its request/response types from the corresponding `.pb.dart`. This
/// split follows the connect-es precedent (decoupled service plugins) so
/// message-only consumers never pull service code.
///
/// ## Building
///
/// ```sh
/// cd dart/ball_protobuf_gen
/// dart compile exe bin/protoc_gen_ball_connect.dart -o protoc-gen-ball-connect
/// ```
///
/// (You may also run it unbuilt via
/// `dart run bin/protoc_gen_ball_connect.dart`, but the compiled executable is
/// what `protoc`/`buf` expect on PATH.)
///
/// ## Invoking with protoc
///
/// Generate messages AND services together — run both plugins in one protoc
/// invocation (each writes to the same `--*_out` tree):
///
/// ```sh
/// protoc \
///   --plugin=protoc-gen-ball=./protoc-gen-ball \
///   --plugin=protoc-gen-ball-connect=./protoc-gen-ball-connect \
///   --ball_out=./out \
///   --ball-connect_out=./out \
///   path/to/your_service.proto
/// ```
///
/// ## Invoking with buf
///
/// List both local plugins in `buf.gen.yaml`; `buf generate` runs them in
/// order into the same `out` directory:
///
/// ```yaml
/// version: v2
/// plugins:
///   - local: ./dart/ball_protobuf_gen/protoc-gen-ball
///     out: gen
///   - local: ./dart/ball_protobuf_gen/protoc-gen-ball-connect
///     out: gen
/// ```
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
    responseBytes = runConnectPlugin(requestBytes);
  } catch (e, st) {
    // A failure to even parse the request is an error in protoc/the plugin
    // itself (not in the user's .proto), so report it on stderr and exit
    // non-zero. Errors in the .proto files are instead returned via
    // CodeGeneratorResponse.error with exit code 0.
    stderr.writeln('protoc-gen-ball-connect: $e');
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
