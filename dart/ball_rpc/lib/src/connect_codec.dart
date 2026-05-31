/// Pure (socket-free) Connect-protocol codec helpers.
///
/// Separated from [ConnectTransport] so the wire details — the streaming
/// envelope (1 flag byte + 4-byte big-endian length, reusing `grpc_frame`),
/// the end-of-stream bit, the `EndStreamResponse` JSON, and the unary error
/// JSON — are fully unit-testable without HTTP. Verified against the Connect
/// protocol spec <https://connectrpc.com/docs/protocol/>.
library;

import 'dart:convert';

import 'package:ball_protobuf/ball_protobuf.dart'
    show
        grpcDecodeFrameWithFlags,
        grpcEncodeFrameWithFlags,
        grpcFlagIsEndOfStream,
        grpcMakeFlags;

import 'rpc_code.dart';
import 'rpc_exception.dart';

/// The Connect protocol version, sent as the `connect-protocol-version` header.
const String connectProtocolVersion = '1';

/// `application/proto` — the unary Connect content type for binary messages.
const String connectUnaryProtoContentType = 'application/proto';

/// `application/connect+proto` — the streaming Connect content type for binary
/// messages.
const String connectStreamProtoContentType = 'application/connect+proto';

/// Encodes one Connect streaming envelope: a data frame carrying [message].
///
/// Layout is identical to a gRPC frame (1 flag byte + 4-byte big-endian length
/// + payload); the end-of-stream bit (bit 1) is `0` for a data frame.
List<int> connectEncodeMessage(List<int> message) =>
    grpcEncodeFrameWithFlags(message, grpcMakeFlags());

/// Encodes the final Connect end-of-stream envelope.
///
/// The flag byte sets the end-of-stream bit (bit 1); the payload is the
/// `EndStreamResponse` JSON: `{error?, metadata?}`. A successful stream omits
/// `error`; a failed stream carries it as a Connect error object
/// (`{code, message?, details?}`). [metadata] becomes the JSON `metadata`
/// object, whose values are arrays of strings per the spec.
List<int> connectEncodeEndStream({RpcException? error, RpcMetadata? metadata}) {
  final obj = <String, Object?>{};
  if (error != null) obj['error'] = _errorToJson(error);
  if (metadata != null && metadata.isNotEmpty) {
    obj['metadata'] = {
      for (final e in metadata.entries) e.key: [e.value],
    };
  }
  final payload = utf8.encode(jsonEncode(obj));
  return grpcEncodeFrameWithFlags(payload, grpcMakeFlags(endOfStream: true));
}

/// One decoded Connect envelope: either a data [message] or the end-of-stream
/// marker.
class ConnectEnvelope {
  /// Whether this is the final end-of-stream envelope (flag bit 1 set).
  final bool endOfStream;

  /// The raw payload bytes (a message for data frames; the `EndStreamResponse`
  /// JSON for the end-of-stream frame).
  final List<int> payload;

  /// For an [endOfStream] frame, the decoded error (or `null` on success).
  final RpcException? error;

  /// For an [endOfStream] frame, the decoded trailing metadata (or `null`).
  final RpcMetadata? metadata;

  /// Total bytes consumed from the source buffer (header + payload).
  final int bytesRead;

  const ConnectEnvelope({
    required this.endOfStream,
    required this.payload,
    required this.bytesRead,
    this.error,
    this.metadata,
  });
}

/// Decodes a single Connect envelope from [buffer] at [offset].
///
/// For a data frame, [ConnectEnvelope.payload] is the message bytes. For the
/// end-of-stream frame, the payload JSON is parsed into
/// [ConnectEnvelope.error] / [ConnectEnvelope.metadata].
ConnectEnvelope connectDecodeEnvelope(List<int> buffer, int offset) {
  final frame = grpcDecodeFrameWithFlags(buffer, offset);
  final flags = frame['flags'] as int;
  final payload = frame['messageBytes'] as List<int>;
  final bytesRead = frame['bytesRead'] as int;
  if (!grpcFlagIsEndOfStream(flags)) {
    return ConnectEnvelope(
      endOfStream: false,
      payload: payload,
      bytesRead: bytesRead,
    );
  }
  // End-of-stream: parse the EndStreamResponse JSON.
  RpcException? error;
  RpcMetadata? metadata;
  if (payload.isNotEmpty) {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is Map<String, Object?>) {
      final err = decoded['error'];
      if (err is Map<String, Object?>) {
        error = errorFromJson(err, metadata: _metadataFromJson(decoded));
      }
      metadata = _metadataFromJson(decoded);
    }
  }
  return ConnectEnvelope(
    endOfStream: true,
    payload: payload,
    bytesRead: bytesRead,
    error: error,
    metadata: metadata,
  );
}

/// Decodes every Connect envelope in [buffer] in order.
List<ConnectEnvelope> connectDecodeEnvelopes(List<int> buffer) {
  final out = <ConnectEnvelope>[];
  var offset = 0;
  while (offset < buffer.length) {
    final env = connectDecodeEnvelope(buffer, offset);
    out.add(env);
    offset += env.bytesRead;
  }
  return out;
}

/// Builds an [RpcException] from a decoded Connect error JSON object
/// (`{code, message?, details?}`).
///
/// An absent or unrecognized `code` maps to [RpcCode.unknown].
RpcException errorFromJson(Map<String, Object?> json, {RpcMetadata? metadata}) {
  final codeStr = json['code'];
  final code = codeStr is String
      ? RpcCode.fromConnectName(codeStr)
      : RpcCode.unknown;
  final message = json['message'];
  final details = json['details'];
  return RpcException(
    code,
    message is String ? message : '',
    details: details is List ? List<Object?>.from(details) : const [],
    metadata: metadata,
  );
}

Map<String, Object?> _errorToJson(RpcException e) {
  final obj = <String, Object?>{'code': e.code.connectName};
  if (e.message.isNotEmpty) obj['message'] = e.message;
  if (e.details.isNotEmpty) obj['details'] = e.details;
  return obj;
}

/// Reads the `metadata` object (`{key: [values...]}`) of an `EndStreamResponse`
/// into a flat [RpcMetadata] (first value per key wins). Returns `null` when
/// absent.
RpcMetadata? _metadataFromJson(Map<String, Object?> json) {
  final meta = json['metadata'];
  if (meta is! Map) return null;
  final out = <String, String>{};
  meta.forEach((key, value) {
    if (value is List && value.isNotEmpty) {
      out['$key'] = '${value.first}';
    } else if (value is String) {
      out['$key'] = value;
    }
  });
  return out.isEmpty ? null : out;
}
