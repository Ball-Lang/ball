/// Field-level encoding for protobuf fixed-width integer and floating-point
/// types.
///
/// Wraps the wire primitives from `wire_fixed.dart` with field tag emission
/// and proto3 default-value skipping (zero values are not serialized).
///
/// Fixed-width wire types:
///   - Wire type 5 (I32): fixed32, sfixed32, float  — 4 bytes little-endian
///   - Wire type 1 (I64): fixed64, sfixed64, double — 8 bytes little-endian
///
/// IEEE 754 float/double encoding uses `dart:typed_data.ByteData` for correct
/// bit-level conversion. This is a Dart-native solution; other Ball target
/// languages will need equivalent std_memory operations.
///
/// References:
///   - https://protobuf.dev/programming-guides/encoding/#non-varint-numbers
///   - https://protobuf.dev/programming-guides/encoding/#structure
///
/// Test vectors:
///   encodeFixed32Field([], 1, 0)         -> []  (proto3 default skipped)
///   encodeFixed32Field([], 1, 1)         -> [13, 1, 0, 0, 0]
///   encodeFixed64Field([], 1, 0)         -> []  (proto3 default skipped)
///   encodeFixed64Field([], 1, 1)         -> [9, 1, 0, 0, 0, 0, 0, 0, 0]
///   encodeFloatField([], 1, 0.0)         -> []  (proto3 default skipped)
///   encodeFloatField([], 1, 1.0)         -> [13, 0, 0, 128, 63]
///   encodeDoubleField([], 1, 0.0)        -> []  (proto3 default skipped)
///   encodeDoubleField([], 1, 1.0)        -> [9, 0, 0, 0, 0, 0, 0, 240, 63]
///   decodeFloat([0, 0, 128, 63], 0)      -> 1.0
///   decodeDouble([0, 0, 0, 0, 0, 0, 240, 63], 0) -> 1.0
library;

import 'dart:typed_data';

import 'wire_fixed.dart';

// ---------------------------------------------------------------------------
// Fixed-width integer fields
// ---------------------------------------------------------------------------

/// Encodes a `fixed32` field (wire type 5) into [buffer].
///
/// Proto3 rule: if [value] is 0, nothing is written (default value is omitted).
/// The unsigned 32-bit [value] is serialized as a field tag followed by 4
/// little-endian bytes.
///
/// Returns the same [buffer] list, possibly with bytes appended.
List<int> encodeFixed32Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, 5);
  encodeFixed32(buffer, value);
  return buffer;
}

/// Encodes a `fixed64` field (wire type 1) into [buffer].
///
/// Proto3 rule: if [value] is 0, nothing is written.
/// The unsigned 64-bit [value] is serialized as a field tag followed by 8
/// little-endian bytes.
///
/// Returns the same [buffer] list, possibly with bytes appended.
List<int> encodeFixed64Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, 1);
  encodeFixed64(buffer, value);
  return buffer;
}

/// Encodes an `sfixed32` field (wire type 5) into [buffer].
///
/// Proto3 rule: if [value] is 0, nothing is written.
/// The signed 32-bit [value] is serialized identically to `fixed32` on the
/// wire — the sign is preserved in the two's-complement bit pattern and the
/// 4-byte little-endian encoding is the same.
///
/// Returns the same [buffer] list, possibly with bytes appended.
List<int> encodeSfixed32Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, 5);
  encodeFixed32(buffer, value);
  return buffer;
}

/// Encodes an `sfixed64` field (wire type 1) into [buffer].
///
/// Proto3 rule: if [value] is 0, nothing is written.
/// The signed 64-bit [value] is serialized identically to `fixed64` on the
/// wire — the sign is preserved in the two's-complement bit pattern and the
/// 8-byte little-endian encoding is the same.
///
/// Returns the same [buffer] list, possibly with bytes appended.
List<int> encodeSfixed64Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, 1);
  encodeFixed64(buffer, value);
  return buffer;
}

// ---------------------------------------------------------------------------
// Floating-point fields
// ---------------------------------------------------------------------------

/// Converts a [double] to its IEEE 754 single-precision (float) 4-byte
/// little-endian representation.
///
/// Uses `dart:typed_data.ByteData` for correct bit-level conversion.
/// Other Ball target languages will need equivalent std_memory operations.
List<int> _encodeFloatBytes(double value) {
  final bd = ByteData(4);
  bd.setFloat32(0, value, Endian.little);
  return [bd.getUint8(0), bd.getUint8(1), bd.getUint8(2), bd.getUint8(3)];
}

/// Converts a [double] to its IEEE 754 double-precision 8-byte little-endian
/// representation.
///
/// Uses `dart:typed_data.ByteData` for correct bit-level conversion.
/// Other Ball target languages will need equivalent std_memory operations.
List<int> _encodeDoubleBytes(double value) {
  final bd = ByteData(8);
  bd.setFloat64(0, value, Endian.little);
  return [
    bd.getUint8(0),
    bd.getUint8(1),
    bd.getUint8(2),
    bd.getUint8(3),
    bd.getUint8(4),
    bd.getUint8(5),
    bd.getUint8(6),
    bd.getUint8(7),
  ];
}

/// Encodes a `float` field (wire type 5) into [buffer].
///
/// Proto3 rule: if [value] is 0.0, nothing is written.
/// The IEEE 754 single-precision [value] is serialized as a field tag followed
/// by 4 little-endian bytes.
///
/// Returns the same [buffer] list, possibly with bytes appended.
List<int> encodeFloatField(List<int> buffer, int fieldNumber, double value) {
  if (value == 0.0) return buffer;
  encodeTag(buffer, fieldNumber, 5);
  buffer.addAll(_encodeFloatBytes(value));
  return buffer;
}

/// Encodes a `double` field (wire type 1) into [buffer].
///
/// Proto3 rule: if [value] is 0.0, nothing is written.
/// The IEEE 754 double-precision [value] is serialized as a field tag followed
/// by 8 little-endian bytes.
///
/// Returns the same [buffer] list, possibly with bytes appended.
List<int> encodeDoubleField(List<int> buffer, int fieldNumber, double value) {
  if (value == 0.0) return buffer;
  encodeTag(buffer, fieldNumber, 1);
  buffer.addAll(_encodeDoubleBytes(value));
  return buffer;
}

// ---------------------------------------------------------------------------
// Floating-point decode helpers
// ---------------------------------------------------------------------------

/// Decodes 4 little-endian bytes from [buffer] at [offset] as an IEEE 754
/// single-precision float.
///
/// Throws a [RangeError] if fewer than 4 bytes are available at [offset].
double decodeFloat(List<int> buffer, int offset) {
  if (offset + 4 > buffer.length) {
    throw RangeError(
      'Not enough bytes to decode float at offset $offset '
      '(need 4, have ${buffer.length - offset})',
    );
  }
  final bd = ByteData(4);
  bd.setUint8(0, buffer[offset]);
  bd.setUint8(1, buffer[offset + 1]);
  bd.setUint8(2, buffer[offset + 2]);
  bd.setUint8(3, buffer[offset + 3]);
  return bd.getFloat32(0, Endian.little);
}

/// Decodes 8 little-endian bytes from [buffer] at [offset] as an IEEE 754
/// double-precision float.
///
/// Throws a [RangeError] if fewer than 8 bytes are available at [offset].
double decodeDouble(List<int> buffer, int offset) {
  if (offset + 8 > buffer.length) {
    throw RangeError(
      'Not enough bytes to decode double at offset $offset '
      '(need 8, have ${buffer.length - offset})',
    );
  }
  final bd = ByteData(8);
  bd.setUint8(0, buffer[offset]);
  bd.setUint8(1, buffer[offset + 1]);
  bd.setUint8(2, buffer[offset + 2]);
  bd.setUint8(3, buffer[offset + 3]);
  bd.setUint8(4, buffer[offset + 4]);
  bd.setUint8(5, buffer[offset + 5]);
  bd.setUint8(6, buffer[offset + 6]);
  bd.setUint8(7, buffer[offset + 7]);
  return bd.getFloat64(0, Endian.little);
}
