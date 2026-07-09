import 'dart:convert';

import 'wire_varint.dart';

/// Create an empty byte buffer.
List<int> makeBuffer() => [];

/// Append length-delimited raw bytes to [buffer].
///
/// Format: varint(length) + raw bytes.
/// Reference: https://protobuf.dev/programming-guides/encoding/#length-types
List<int> encodeBytes(List<int> buffer, List<int> data) {
  encodeVarint(buffer, data.length);
  // Append per-item (NOT buffer.addAll(data)): addAll encodes to the
  // non-mutating `list_concat` on the C++/TS targets, which returns a NEW list
  // that callers relying on in-place mutation (marshal discards the return
  // value) silently drop — corrupting every string/bytes/packed/message field.
  // `.add` compiles to an in-place `list_push` on the shared buffer, so the
  // appended bytes are visible to the caller. See .claude/rules/dart.md.
  for (final b in data) {
    buffer.add(b);
  }
  return buffer;
}

/// Decode length-delimited bytes from [buffer] at [offset].
///
/// Returns `{data: List<int>, bytesRead: int}`.
Map<String, Object> decodeBytes(List<int> buffer, int offset) {
  var varintResult = decodeVarint(buffer, offset);
  var length = varintResult['value']!;
  var varintSize = varintResult['bytesRead']!;
  var start = offset + varintSize;
  if (start + length > buffer.length) {
    throw FormatException(
      'Length-delimited field overflows buffer at offset $offset: '
      'need $length bytes, have ${buffer.length - start}',
    );
  }
  var data = buffer.sublist(start, start + length);
  return {'data': data, 'bytesRead': varintSize + length};
}

/// Encode a string as length-delimited UTF-8 bytes.
///
/// Format: varint(utf8_byte_length) + utf8 bytes.
List<int> encodeString(List<int> buffer, String value) {
  var encoded = utf8.encode(value);
  return encodeBytes(buffer, encoded);
}

/// Decode a string from length-delimited UTF-8 bytes at [offset].
///
/// Returns `{value: String, bytesRead: int}`.
Map<String, Object> decodeString(List<int> buffer, int offset) {
  var bytesResult = decodeBytes(buffer, offset);
  var data = bytesResult['data'] as List<int>;
  var bytesRead = bytesResult['bytesRead'] as int;
  var decoded = utf8.decode(data);
  return {'value': decoded, 'bytesRead': bytesRead};
}
