/// Length-delimited (wire type 2) field encoding/decoding for protobuf.
///
/// Builds on the wire primitives in `wire_varint.dart`, `wire_fixed.dart`,
/// and `wire_bytes.dart` to provide complete field-level encode/decode for
/// strings, bytes, embedded messages, and packed repeated scalars.
///
/// Proto3 default-value elision: all encode functions are no-ops when the
/// value is empty (empty string, empty byte list, empty values list).
///
/// References:
///   - https://protobuf.dev/programming-guides/encoding/#length-types
///   - https://protobuf.dev/programming-guides/encoding/#packed
library;

import 'dart:convert';

import 'wire_varint.dart';
import 'wire_fixed.dart';
import 'wire_bytes.dart';

/// Wire type constant for length-delimited fields.
const int _wireTypeLEN = 2;

/// Encode a string field (wire type 2): tag + varint(utf8_len) + utf8_bytes.
///
/// Proto3 rule: does not emit anything if [value] is empty.
///
/// Returns [buffer] with the field bytes appended.
List<int> encodeStringField(
  List<int> buffer,
  int fieldNumber,
  String value,
) {
  if (value.isEmpty) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeLEN);
  encodeString(buffer, value);
  return buffer;
}

/// Encode a bytes field (wire type 2): tag + varint(len) + raw_bytes.
///
/// Proto3 rule: does not emit anything if [value] is empty.
///
/// Returns [buffer] with the field bytes appended.
List<int> encodeBytesField(
  List<int> buffer,
  int fieldNumber,
  List<int> value,
) {
  if (value.isEmpty) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeLEN);
  encodeBytes(buffer, value);
  return buffer;
}

/// Encode an embedded message field (wire type 2):
/// tag + varint(msg_len) + msg_bytes.
///
/// The [messageBytes] must be pre-encoded by the caller (i.e. the caller
/// marshals the submessage into bytes first, then passes them here).
///
/// Proto3 rule: does not emit anything if [messageBytes] is empty.
///
/// Returns [buffer] with the field bytes appended.
List<int> encodeMessageField(
  List<int> buffer,
  int fieldNumber,
  List<int> messageBytes,
) {
  if (messageBytes.isEmpty) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeLEN);
  encodeBytes(buffer, messageBytes);
  return buffer;
}

/// Encode a packed repeated varints field (wire type 2):
/// tag + varint(total_len) + concatenated varint-encoded values.
///
/// Used for repeated scalar fields that use varint encoding (int32, int64,
/// uint32, uint64, sint32, sint64, bool, enum).
///
/// Proto3 rule: does not emit anything if [values] is empty.
///
/// Returns [buffer] with the field bytes appended.
List<int> encodePackedVarintsField(
  List<int> buffer,
  int fieldNumber,
  List<int> values,
) {
  if (values.isEmpty) return buffer;
  // Encode all values into a temporary buffer to determine total byte length.
  List<int> temp = [];
  for (int i = 0; i < values.length; i++) {
    encodeVarint(temp, values[i]);
  }
  encodeTag(buffer, fieldNumber, _wireTypeLEN);
  encodeBytes(buffer, temp);
  return buffer;
}

/// Encode a packed repeated fixed32 field (wire type 2):
/// tag + varint(total_len) + concatenated 4-byte little-endian values.
///
/// Used for repeated fixed32/sfixed32/float fields.
///
/// Proto3 rule: does not emit anything if [values] is empty.
///
/// Returns [buffer] with the field bytes appended.
List<int> encodePackedFixed32Field(
  List<int> buffer,
  int fieldNumber,
  List<int> values,
) {
  if (values.isEmpty) return buffer;
  List<int> temp = [];
  for (int i = 0; i < values.length; i++) {
    encodeFixed32(temp, values[i]);
  }
  encodeTag(buffer, fieldNumber, _wireTypeLEN);
  encodeBytes(buffer, temp);
  return buffer;
}

/// Encode a packed repeated fixed64 field (wire type 2):
/// tag + varint(total_len) + concatenated 8-byte little-endian values.
///
/// Used for repeated fixed64/sfixed64/double fields.
///
/// Proto3 rule: does not emit anything if [values] is empty.
///
/// Returns [buffer] with the field bytes appended.
List<int> encodePackedFixed64Field(
  List<int> buffer,
  int fieldNumber,
  List<int> values,
) {
  if (values.isEmpty) return buffer;
  List<int> temp = [];
  for (int i = 0; i < values.length; i++) {
    encodeFixed64(temp, values[i]);
  }
  encodeTag(buffer, fieldNumber, _wireTypeLEN);
  encodeBytes(buffer, temp);
  return buffer;
}

/// Decode a UTF-8 string from raw length-delimited [data].
///
/// The caller has already extracted the raw bytes from the wire (after
/// reading the tag and length prefix). This function simply performs
/// UTF-8 decoding.
String decodeStringValue(List<int> data) {
  return utf8.decode(data);
}

/// Decode concatenated varint-encoded integers from [data].
///
/// The caller has already extracted the raw bytes for the packed field.
/// This function reads varints one after another until all bytes are
/// consumed.
///
/// Returns a list of decoded integer values.
List<int> decodePackedVarints(List<int> data) {
  List<int> results = [];
  int offset = 0;
  while (offset < data.length) {
    Map<String, int> result = decodeVarint(data, offset);
    results.add(result['value']!);
    offset += result['bytesRead']!;
  }
  return results;
}

/// Decode concatenated fixed32 (4-byte little-endian) integers from [data].
///
/// The caller has already extracted the raw bytes for the packed field.
/// This function reads 4-byte chunks until all bytes are consumed.
///
/// Returns a list of decoded 32-bit unsigned integer values.
///
/// Throws a [FormatException] if the data length is not a multiple of 4.
List<int> decodePackedFixed32(List<int> data) {
  if (data.length % 4 != 0) {
    throw FormatException(
      'Packed fixed32 data length must be a multiple of 4, '
      'got ${data.length}',
    );
  }
  List<int> results = [];
  int offset = 0;
  while (offset < data.length) {
    Map<String, int> result = decodeFixed32(data, offset);
    results.add(result['value']!);
    offset += result['bytesRead']!;
  }
  return results;
}
