/// [RpcException] and the [RpcMetadata] header/trailer type.
library;

import 'rpc_code.dart';

/// Call metadata: the headers (and trailers) carried alongside an RPC.
///
/// A flat string-to-string map. Binary metadata (gRPC `-bin` / Connect `-bin`
/// base64 headers) is represented with its already-encoded string value; the
/// transports do not interpret keys here.
typedef RpcMetadata = Map<String, String>;

/// A failed RPC: a [code], a human-readable [message], and optional structured
/// [details].
///
/// Transports throw this on any non-OK outcome — a non-200 Connect unary
/// response, a non-zero `grpc-status` trailer, or a Connect end-of-stream
/// envelope carrying an error. [details] holds the protocol's error details
/// verbatim (for Connect unary/stream errors, the decoded `details[]` entries:
/// each a map with `type`/`value`/optional `debug`).
class RpcException implements Exception {
  /// The status code of the failure (never [RpcCode.ok]).
  final RpcCode code;

  /// A human-readable description of the failure.
  final String message;

  /// Protocol-specific structured error details (may be empty).
  final List<Object?> details;

  /// Trailing metadata carried with the error, when the transport surfaces it.
  final RpcMetadata? metadata;

  RpcException(
    this.code,
    this.message, {
    List<Object?> details = const [],
    this.metadata,
  }) : details = List.unmodifiable(details);

  @override
  String toString() {
    final buf = StringBuffer('RpcException(${code.connectName}: $message');
    if (details.isNotEmpty) buf.write(', details: $details');
    buf.write(')');
    return buf.toString();
  }
}
