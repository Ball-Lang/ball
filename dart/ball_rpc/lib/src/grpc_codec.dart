/// Pure (socket-free) gRPC-over-HTTP/2 codec helpers: framing re-export and
/// trailer status mapping.
///
/// Verified against grpc/doc/PROTOCOL-HTTP2.md and the gRPC status-code list
/// <https://grpc.github.io/grpc/core/md_doc_statuscodes.html>.
library;

import 'dart:convert';

import 'rpc_code.dart';
import 'rpc_exception.dart';

/// `application/grpc+proto` — the gRPC content type for binary messages.
const String grpcProtoContentType = 'application/grpc+proto';

/// Builds the request path for a gRPC/Connect method:
/// `/{package}.{Service}/{Method}`.
///
/// [serviceFullName] is the fully-qualified service name (`package.Service`);
/// [methodName] is the method's short name. Returns e.g. `/acme.Eliza/Say`.
String rpcMethodPath(String serviceFullName, String methodName) =>
    '/$serviceFullName/$methodName';

/// Maps a gRPC trailer set to an [RpcException], or `null` when the call
/// succeeded (`grpc-status: 0` or absent).
///
/// [trailers] are the lower-cased HTTP/2 trailer fields. `grpc-status` is the
/// integer status code; `grpc-message` is the (percent-encoded) status message.
/// A missing `grpc-status` is treated as `0` (OK) per the protocol's "Trailers"
/// rules only when the response was otherwise well-formed — callers that never
/// saw a status should surface [RpcCode.unknown] themselves.
RpcException? grpcStatusFromTrailers(Map<String, String> trailers) {
  final statusStr = trailers['grpc-status'];
  if (statusStr == null) return null;
  final statusInt = int.tryParse(statusStr) ?? RpcCode.unknown.value;
  if (statusInt == 0) return null;
  final message = grpcDecodeMessage(trailers['grpc-message'] ?? '');
  return RpcException(RpcCode.fromValue(statusInt), message);
}

/// Decodes a gRPC `grpc-message` trailer value (percent-encoded ASCII).
///
/// Per PROTOCOL-HTTP2.md, the message is percent-encoded: bytes outside the
/// printable-ASCII subset are written as `%XX`. This reverses that encoding,
/// reconstructing the original UTF-8 message.
String grpcDecodeMessage(String encoded) {
  if (!encoded.contains('%')) return encoded;
  final bytes = <int>[];
  for (var i = 0; i < encoded.length; i++) {
    final ch = encoded.codeUnitAt(i);
    if (ch == 0x25 && i + 2 < encoded.length) {
      final hex = encoded.substring(i + 1, i + 3);
      final parsed = int.tryParse(hex, radix: 16);
      if (parsed != null) {
        bytes.add(parsed);
        i += 2;
        continue;
      }
    }
    bytes.add(ch);
  }
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return encoded;
  }
}

/// Encodes a `grpc-message` trailer value (percent-encoding non-ASCII /
/// reserved bytes), the inverse of [grpcDecodeMessage].
String grpcEncodeMessage(String message) {
  final bytes = utf8.encode(message);
  final buf = StringBuffer();
  for (final b in bytes) {
    // Printable ASCII except '%' is written verbatim; everything else is %XX.
    if (b >= 0x20 && b <= 0x7E && b != 0x25) {
      buf.writeCharCode(b);
    } else {
      buf.write('%');
      buf.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buf.toString();
}
