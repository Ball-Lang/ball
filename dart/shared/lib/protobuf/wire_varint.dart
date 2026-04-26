/// Varint (LEB128) and ZigZag encoding/decoding for protobuf wire format.
///
/// These functions implement the unsigned varint encoding (LEB128) and
/// signed integer ZigZag encoding used by Protocol Buffers.
///
/// No imports beyond implicit `dart:core`. All operations use only standard
/// Dart integer arithmetic, bitwise ops, and list manipulation — primitives
/// that map directly to Ball `std` base functions.
///
/// References:
///   - https://protobuf.dev/programming-guides/encoding/#varints
///   - https://protobuf.dev/programming-guides/encoding/#signed-ints
///
/// Test vectors:
///   encodeVarint([], 0)   → [0]
///   encodeVarint([], 1)   → [1]
///   encodeVarint([], 127) → [127]
///   encodeVarint([], 128) → [128, 1]
///   encodeVarint([], 300) → [172, 2]
///   encodeVarint([], 150) → [150, 1]   (official docs example)
///   encodeZigZag32(0)     → 0
///   encodeZigZag32(-1)    → 1
///   encodeZigZag32(1)     → 2
///   encodeZigZag32(-2)    → 3
///   decodeZigZag(0)       → 0
///   decodeZigZag(1)       → -1
///   decodeZigZag(2)       → 1
library;

/// Appends the varint-encoded (LEB128) representation of [value] to [buffer].
///
/// Each output byte carries 7 bits of payload in bits 0–6 and a continuation
/// flag in bit 7 (MSB). The continuation bit is set on every byte except the
/// last, signaling that more bytes follow.
///
/// [value] is treated as an unsigned 64-bit integer. Negative Dart ints
/// (which are two's-complement 64-bit) will encode as their unsigned
/// representation — 10 bytes for the full 64-bit range.
///
/// Returns the same [buffer] list with the varint bytes appended, allowing
/// fluent chaining.
List<int> encodeVarint(List<int> buffer, int value) {
  // Mask to unsigned 64-bit: on the Dart VM, ints are already 64-bit
  // two's-complement, so negative values naturally produce the unsigned
  // bit pattern when processed with >>> (logical right shift).
  int remaining = value;
  do {
    // Extract the lowest 7 bits.
    int byte = remaining & 0x7F;
    // Logical right shift by 7 to advance to the next group.
    remaining = remaining >>> 7;
    // If there are more groups to encode, set the continuation bit.
    if (remaining != 0) {
      byte = byte | 0x80;
    }
    buffer.add(byte);
  } while (remaining != 0);
  return buffer;
}

/// Decodes a varint (LEB128) from [buffer] starting at [offset].
///
/// Returns a map with two entries:
///   - `'value'`: the decoded unsigned integer.
///   - `'bytesRead'`: the number of bytes consumed from the buffer.
///
/// Throws a [FormatException] if the varint exceeds 10 bytes (the maximum
/// for a 64-bit value) or if the buffer ends before the varint is complete.
Map<String, int> decodeVarint(List<int> buffer, int offset) {
  int result = 0;
  int shift = 0;
  int bytesRead = 0;

  while (true) {
    if (offset + bytesRead >= buffer.length) {
      throw FormatException(
        'Unexpected end of buffer while decoding varint at offset $offset',
      );
    }

    int byte = buffer[offset + bytesRead];
    bytesRead++;

    // Accumulate the 7 payload bits at the current shift position.
    result = result | ((byte & 0x7F) << shift);
    shift += 7;

    // If the continuation bit (MSB) is not set, we are done.
    if ((byte & 0x80) == 0) {
      break;
    }

    // Varints longer than 10 bytes cannot represent a 64-bit value.
    if (bytesRead >= 10) {
      throw FormatException(
        'Varint exceeds maximum length of 10 bytes at offset $offset',
      );
    }
  }

  return {'value': result, 'bytesRead': bytesRead};
}

/// ZigZag-encodes a signed 32-bit integer.
///
/// Maps signed values to unsigned values so that values with small absolute
/// magnitude have small varint encodings:
///   0 → 0, -1 → 1, 1 → 2, -2 → 3, 2 → 4, …
///
/// Formula: `(n << 1) ^ (n >> 31)`
///
/// The arithmetic right shift (`>>`) propagates the sign bit, producing
/// either all-zeros (positive) or all-ones (negative), which the XOR then
/// uses to flip or preserve the shifted bits.
int encodeZigZag32(int n) {
  return (n << 1) ^ (n >> 31);
}

/// ZigZag-encodes a signed 64-bit integer.
///
/// Same principle as [encodeZigZag32] but uses a 63-bit arithmetic shift
/// to handle the full 64-bit signed range.
///
/// Formula: `(n << 1) ^ (n >> 63)`
int encodeZigZag64(int n) {
  return (n << 1) ^ (n >> 63);
}

/// ZigZag-decodes an unsigned integer back to its signed representation.
///
/// Reverses the mapping performed by [encodeZigZag32] or [encodeZigZag64]:
///   0 → 0, 1 → -1, 2 → 1, 3 → -2, 4 → 2, …
///
/// Formula: `(n >>> 1) ^ -(n & 1)`
///
/// The logical right shift (`>>>`) drops the encoding's LSB parity flag,
/// while `-(n & 1)` produces an all-zeros or all-ones mask that restores
/// the original sign via XOR.
int decodeZigZag(int n) {
  return (n >>> 1) ^ -(n & 1);
}
