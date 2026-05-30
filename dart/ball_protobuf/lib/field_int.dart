/// Protobuf integer field encoding/decoding.
///
/// Each encode function appends a complete field (tag + value) to a buffer for
/// wire type 0 (VARINT) integer types: int32, int64, uint32, uint64, sint32,
/// sint64, bool, and enum.
///
/// Each decode function interprets a raw varint value as the appropriate type.
///
/// Proto3 default-value rule: encode functions return the buffer unchanged when
/// the value is the default (0 for integers, false for bool), because proto3
/// does not serialize default values on the wire.
///
/// References:
///   - https://protobuf.dev/programming-guides/encoding/#varints
///   - https://protobuf.dev/programming-guides/encoding/#signed-ints
///
/// Test vectors:
///   encodeInt32Field([], 1, 150) -> [8, 150, 1]   (tag 0x08, varint 150)
///   encodeInt32Field([], 1, 0)   -> []              (default skipped)
///   encodeSint32Field([], 1, -1) -> [8, 1]          (tag 0x08, zigzag(-1)=1)
///   encodeBoolField([], 1, true) -> [8, 1]
///   encodeBoolField([], 1, false)-> []               (default skipped)
///   decodeAsInt32(0xFFFFFFFF)    -> -1               (32-bit signed)
///   decodeAsUint32(0x1FFFFFFFF)  -> 0xFFFFFFFF       (mask to 32 bits)
///   decodeAsSint32(1)            -> -1               (zigzag decode)
///   decodeAsBool(0)              -> false
///   decodeAsBool(1)              -> true
library;

import 'wire_varint.dart';
import 'wire_fixed.dart';

/// Wire type constant for VARINT fields.
const int _wireTypeVarint = 0;

// ---------------------------------------------------------------------------
// Encode functions
// ---------------------------------------------------------------------------

/// Encodes an int32 field: tag(fieldNumber, VARINT) + varint(value).
///
/// For negative values, protobuf encodes int32 as a 10-byte varint (sign-
/// extended to 64 bits). Dart's `int` is already 64-bit two's-complement,
/// so passing a negative value to [encodeVarint] naturally produces the
/// correct encoding.
///
/// Returns [buffer] unchanged if [value] is 0 (proto3 default).
List<int> encodeInt32Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeVarint);
  encodeVarint(buffer, value);
  return buffer;
}

/// Encodes an int64 field: tag(fieldNumber, VARINT) + varint(value).
///
/// Returns [buffer] unchanged if [value] is 0 (proto3 default).
List<int> encodeInt64Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeVarint);
  encodeVarint(buffer, value);
  return buffer;
}

/// Encodes a uint32 field: tag(fieldNumber, VARINT) + varint(value).
///
/// [value] is expected to be in the range [0, 2^32 - 1].
///
/// Returns [buffer] unchanged if [value] is 0 (proto3 default).
List<int> encodeUint32Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeVarint);
  encodeVarint(buffer, value);
  return buffer;
}

/// Encodes a uint64 field: tag(fieldNumber, VARINT) + varint(value).
///
/// [value] is expected to be in the range [0, 2^64 - 1]. Negative Dart ints
/// are treated as their unsigned 64-bit representation.
///
/// Returns [buffer] unchanged if [value] is 0 (proto3 default).
List<int> encodeUint64Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeVarint);
  encodeVarint(buffer, value);
  return buffer;
}

/// Encodes a sint32 field: tag(fieldNumber, VARINT) + varint(zigzag32(value)).
///
/// ZigZag encoding maps signed values to unsigned so that small absolute
/// values produce small varints (efficient for fields that are often negative).
///
/// Returns [buffer] unchanged if [value] is 0 (proto3 default).
List<int> encodeSint32Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeVarint);
  encodeVarint(buffer, encodeZigZag32(value));
  return buffer;
}

/// Encodes a sint64 field: tag(fieldNumber, VARINT) + varint(zigzag64(value)).
///
/// Returns [buffer] unchanged if [value] is 0 (proto3 default).
List<int> encodeSint64Field(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeVarint);
  encodeVarint(buffer, encodeZigZag64(value));
  return buffer;
}

/// Encodes a bool field: tag(fieldNumber, VARINT) + varint(value ? 1 : 0).
///
/// Returns [buffer] unchanged if [value] is false (proto3 default).
List<int> encodeBoolField(List<int> buffer, int fieldNumber, bool value) {
  if (!value) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeVarint);
  encodeVarint(buffer, 1);
  return buffer;
}

/// Encodes an enum field: tag(fieldNumber, VARINT) + varint(value).
///
/// Enums are represented as plain int32 on the wire.
///
/// Returns [buffer] unchanged if [value] is 0 (proto3 default).
List<int> encodeEnumField(List<int> buffer, int fieldNumber, int value) {
  if (value == 0) return buffer;
  encodeTag(buffer, fieldNumber, _wireTypeVarint);
  encodeVarint(buffer, value);
  return buffer;
}

// ---------------------------------------------------------------------------
// Decode functions
// ---------------------------------------------------------------------------

/// Interprets [rawVarint] as a signed 32-bit integer.
///
/// Truncates to the lowest 32 bits and sign-extends by shifting left then
/// arithmetic-shifting right.
int decodeAsInt32(int rawVarint) {
  // Mask to 32 bits, then sign-extend: shift left by 32 to place bit 31
  // into the sign position of a 64-bit int, then arithmetic right shift back.
  return (rawVarint << 32) >> 32;
}

/// Interprets [rawVarint] as an unsigned 32-bit integer.
///
/// Masks to the lowest 32 bits, discarding any higher bits.
int decodeAsUint32(int rawVarint) {
  return rawVarint & 0xFFFFFFFF;
}

/// Interprets [rawVarint] as a ZigZag-encoded signed 32-bit integer.
///
/// Applies ZigZag decoding to recover the original signed value.
int decodeAsSint32(int rawVarint) {
  return decodeZigZag(rawVarint);
}

/// Interprets [rawVarint] as a ZigZag-encoded signed 64-bit integer.
///
/// Applies ZigZag decoding to recover the original signed value.
int decodeAsSint64(int rawVarint) {
  return decodeZigZag(rawVarint);
}

/// Interprets [rawVarint] as a signed 64-bit integer.
///
/// This is an identity function — Dart ints are already 64-bit two's-complement
/// — but it exists for symmetry with [decodeAsInt32] and for documentation
/// purposes at call sites.
int decodeAsInt64(int rawVarint) {
  return rawVarint;
}

/// Interprets [rawVarint] as an unsigned 64-bit integer.
///
/// This is an identity function — the varint decoder already produces the
/// unsigned representation — but it exists for symmetry with [decodeAsUint32]
/// and for documentation purposes at call sites.
int decodeAsUint64(int rawVarint) {
  return rawVarint;
}

/// Interprets [rawVarint] as a boolean.
///
/// Returns `true` if [rawVarint] is non-zero, `false` otherwise.
bool decodeAsBool(int rawVarint) {
  return rawVarint != 0;
}
