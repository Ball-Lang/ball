import 'dart:convert';

/// Append a varint-encoded integer to [buffer].
///
/// Uses the standard protobuf variable-length encoding: each byte stores
/// 7 payload bits in the low position and a continuation flag in bit 7.
List<int> _appendVarint(List<int> buffer, int value) {
  while (value > 0x7F) {
    buffer.add((value & 0x7F) | 0x80);
    value = value >>> 7;
  }
  buffer.add(value & 0x7F);
  return buffer;
}

/// Decode a varint from [buffer] starting at [offset].
///
/// Returns `{value: int, bytesRead: int}`.
Map<String, Object> _decodeVarint(List<int> buffer, int offset) {
  var result = 0;
  var shift = 0;
  var bytesRead = 0;
  while (true) {
    var byte = buffer[offset + bytesRead];
    result = result | ((byte & 0x7F) << shift);
    bytesRead = bytesRead + 1;
    if ((byte & 0x80) == 0) {
      break;
    }
    shift = shift + 7;
  }
  return {'value': result, 'bytesRead': bytesRead};
}

/// Create an empty byte buffer.
List<int> makeBuffer() => [];

/// Append length-delimited raw bytes to [buffer].
///
/// Format: varint(length) + raw bytes.
/// Reference: https://protobuf.dev/programming-guides/encoding/#length-types
List<int> encodeBytes(List<int> buffer, List<int> data) {
  _appendVarint(buffer, data.length);
  buffer.addAll(data);
  return buffer;
}

/// Decode length-delimited bytes from [buffer] at [offset].
///
/// Returns `{data: List<int>, bytesRead: int}`.
Map<String, Object> decodeBytes(List<int> buffer, int offset) {
  var varintResult = _decodeVarint(buffer, offset);
  var length = varintResult['value'] as int;
  var varintSize = varintResult['bytesRead'] as int;
  var start = offset + varintSize;
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
