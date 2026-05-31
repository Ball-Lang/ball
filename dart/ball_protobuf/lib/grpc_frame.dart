/// gRPC Length-Prefixed-Message framing.
///
/// Implements the gRPC wire format for HTTP/2 DATA frames as specified in
/// grpc/doc/PROTOCOL-HTTP2.md.
///
/// Frame layout:
/// ```
/// Byte 0:    Compressed-Flag (0 = uncompressed, 1 = compressed)
/// Bytes 1-4: Message-Length   (4 bytes, big-endian unsigned int32)
/// Bytes 5+:  Message data     (protobuf binary)
/// ```
library;

/// Size of the gRPC frame header in bytes (1 flag + 4 length).
const int _headerSize = 5;

// ---------------------------------------------------------------------------
// Frame flag-byte bits
// ---------------------------------------------------------------------------
//
// The leading flag byte is a bitset. gRPC defines bit 0 (compression); the
// Connect streaming protocol additionally uses bit 1 to mark the final
// end-of-stream envelope (the `EndStreamResponse`). Exposing the bits lets the
// same frame codec serve both transports.

/// Flag-byte bit 0: the payload is compressed.
const int grpcFlagCompressed = 0x01;

/// Flag-byte bit 1: this is the Connect streaming end-of-stream envelope.
const int grpcFlagEndOfStream = 0x02;

/// Whether the compression bit (bit 0) is set in [flags].
bool grpcFlagIsCompressed(int flags) => (flags & grpcFlagCompressed) != 0;

/// Whether the end-of-stream bit (bit 1) is set in [flags] (Connect streaming).
bool grpcFlagIsEndOfStream(int flags) => (flags & grpcFlagEndOfStream) != 0;

/// Builds a flag byte from the [compressed] / [endOfStream] bits.
int grpcMakeFlags({bool compressed = false, bool endOfStream = false}) =>
    (compressed ? grpcFlagCompressed : 0) |
    (endOfStream ? grpcFlagEndOfStream : 0);

/// Encode a gRPC frame: 1-byte compression flag + 4-byte big-endian length +
/// message bytes.
///
/// [messageBytes] is the raw protobuf-encoded message payload.
/// [compressed] indicates whether the payload has been compressed; `false`
/// writes `0x00`, `true` writes `0x01`.
///
/// Returns the complete length-prefixed frame as a byte list.
List<int> grpcEncodeFrame(List<int> messageBytes, {bool compressed = false}) {
  var length = messageBytes.length;
  var frame = List<int>.filled(_headerSize + length, 0);
  // Byte 0: compression flag.
  frame[0] = compressed ? 1 : 0;
  // Bytes 1-4: message length, big-endian.
  frame[1] = (length >>> 24) & 0xFF;
  frame[2] = (length >>> 16) & 0xFF;
  frame[3] = (length >>> 8) & 0xFF;
  frame[4] = length & 0xFF;
  // Bytes 5+: message payload.
  for (var i = 0; i < length; i++) {
    frame[_headerSize + i] = messageBytes[i];
  }
  return frame;
}

/// Decode a single gRPC frame from [buffer] starting at [offset].
///
/// Returns a map with:
/// - `messageBytes` (`List<int>`): the decoded message payload.
/// - `compressed` (`bool`): whether the compression flag was set.
/// - `bytesRead` (`int`): total bytes consumed (header + payload), so the
///   caller can advance the read position.
///
/// Throws [RangeError] if [buffer] does not contain a complete frame at the
/// given offset.
Map<String, Object?> grpcDecodeFrame(List<int> buffer, int offset) {
  if (offset + _headerSize > buffer.length) {
    throw RangeError('Incomplete gRPC frame header at offset $offset');
  }
  var compressed = buffer[offset] != 0;
  var length =
      ((buffer[offset + 1] << 24) |
          (buffer[offset + 2] << 16) |
          (buffer[offset + 3] << 8) |
          buffer[offset + 4]) &
      0xFFFFFFFF;
  if (offset + _headerSize + length > buffer.length) {
    throw RangeError(
      'Incomplete gRPC frame payload at offset $offset: '
      'expected $length bytes, '
      'have ${buffer.length - offset - _headerSize}',
    );
  }
  var messageBytes = buffer.sublist(
    offset + _headerSize,
    offset + _headerSize + length,
  );
  return {
    'messageBytes': messageBytes,
    'compressed': compressed,
    'bytesRead': _headerSize + length,
  };
}

/// Encode a frame with an explicit [flags] byte (1 flag + 4-byte big-endian
/// length + message bytes).
///
/// This is the flag-byte-aware sibling of [grpcEncodeFrame]: instead of the
/// single `compressed` bool it takes the full flag bitset, so a Connect
/// streaming end-of-stream envelope can set [grpcFlagEndOfStream] (bit 1). Build
/// [flags] with [grpcMakeFlags]. `grpcEncodeFrame(bytes, compressed: c)` is
/// exactly `grpcEncodeFrameWithFlags(bytes, c ? grpcFlagCompressed : 0)`.
List<int> grpcEncodeFrameWithFlags(List<int> messageBytes, int flags) {
  var length = messageBytes.length;
  var frame = List<int>.filled(_headerSize + length, 0);
  // Byte 0: the full flag bitset (compression bit 0, end-of-stream bit 1).
  frame[0] = flags & 0xFF;
  // Bytes 1-4: message length, big-endian.
  frame[1] = (length >>> 24) & 0xFF;
  frame[2] = (length >>> 16) & 0xFF;
  frame[3] = (length >>> 8) & 0xFF;
  frame[4] = length & 0xFF;
  // Bytes 5+: message payload.
  for (var i = 0; i < length; i++) {
    frame[_headerSize + i] = messageBytes[i];
  }
  return frame;
}

/// Decode a single frame from [buffer] at [offset], exposing the full flag byte.
///
/// This is the flag-byte-aware sibling of [grpcDecodeFrame] (which only reports
/// the compression bool). Returns a map with:
/// - `messageBytes` (`List<int>`): the decoded message payload.
/// - `flags` (`int`): the raw flag byte (test with [grpcFlagIsCompressed] /
///   [grpcFlagIsEndOfStream]).
/// - `compressed` (`bool`): convenience for `flags & grpcFlagCompressed`.
/// - `endOfStream` (`bool`): convenience for `flags & grpcFlagEndOfStream`
///   (the Connect streaming end-of-stream marker).
/// - `bytesRead` (`int`): total bytes consumed (header + payload).
///
/// Throws [RangeError] if [buffer] does not contain a complete frame at
/// [offset].
Map<String, Object?> grpcDecodeFrameWithFlags(List<int> buffer, int offset) {
  if (offset + _headerSize > buffer.length) {
    throw RangeError('Incomplete gRPC frame header at offset $offset');
  }
  var flags = buffer[offset] & 0xFF;
  var length =
      ((buffer[offset + 1] << 24) |
          (buffer[offset + 2] << 16) |
          (buffer[offset + 3] << 8) |
          buffer[offset + 4]) &
      0xFFFFFFFF;
  if (offset + _headerSize + length > buffer.length) {
    throw RangeError(
      'Incomplete gRPC frame payload at offset $offset: '
      'expected $length bytes, '
      'have ${buffer.length - offset - _headerSize}',
    );
  }
  var messageBytes = buffer.sublist(
    offset + _headerSize,
    offset + _headerSize + length,
  );
  return {
    'messageBytes': messageBytes,
    'flags': flags,
    'compressed': grpcFlagIsCompressed(flags),
    'endOfStream': grpcFlagIsEndOfStream(flags),
    'bytesRead': _headerSize + length,
  };
}

/// Encode multiple gRPC frames (for streaming).
///
/// Each element of [messages] is a raw protobuf-encoded message. All frames
/// share the same [compressed] flag. Returns the concatenation of all
/// length-prefixed frames.
List<int> grpcEncodeFrames(
  List<List<int>> messages, {
  bool compressed = false,
}) {
  // Pre-compute total size to avoid repeated list growth.
  var totalSize = 0;
  for (var msg in messages) {
    totalSize += _headerSize + msg.length;
  }
  var result = List<int>.filled(totalSize, 0);
  var pos = 0;
  for (var msg in messages) {
    var frame = grpcEncodeFrame(msg, compressed: compressed);
    for (var i = 0; i < frame.length; i++) {
      result[pos + i] = frame[i];
    }
    pos += frame.length;
  }
  return result;
}

/// Decode all gRPC frames from [buffer].
///
/// Returns a list of maps, each containing:
/// - `messageBytes` (`List<int>`): the decoded message payload.
/// - `compressed` (`bool`): whether the compression flag was set.
List<Map<String, Object?>> grpcDecodeFrames(List<int> buffer) {
  var frames = <Map<String, Object?>>[];
  var offset = 0;
  while (offset < buffer.length) {
    var decoded = grpcDecodeFrame(buffer, offset);
    var bytesRead = decoded['bytesRead'] as int;
    frames.add({
      'messageBytes': decoded['messageBytes'],
      'compressed': decoded['compressed'],
    });
    offset += bytesRead;
  }
  return frames;
}

/// Extract service method descriptors from a FileDescriptorProto-like map.
///
/// [serviceDescriptor] should have a `methods` key containing a list of maps,
/// each with `name`, `inputType`, `outputType`, and optionally
/// `clientStreaming` and `serverStreaming` boolean flags.
///
/// Returns a list of maps, each with:
/// - `name` (`String`): the method name.
/// - `inputType` (`String`): the fully-qualified input message type.
/// - `outputType` (`String`): the fully-qualified output message type.
/// - `clientStreaming` (`bool`): whether the client streams requests.
/// - `serverStreaming` (`bool`): whether the server streams responses.
List<Map<String, Object?>> extractServiceMethods(
  Map<String, Object?> serviceDescriptor,
) {
  var methods = serviceDescriptor['methods'];
  if (methods == null || methods is! List) {
    return [];
  }
  var result = <Map<String, Object?>>[];
  for (var method in methods) {
    if (method is! Map<String, Object?>) continue;
    result.add({
      'name': method['name'] ?? '',
      'inputType': method['inputType'] ?? '',
      'outputType': method['outputType'] ?? '',
      'clientStreaming': method['clientStreaming'] == true,
      'serverStreaming': method['serverStreaming'] == true,
    });
  }
  return result;
}
