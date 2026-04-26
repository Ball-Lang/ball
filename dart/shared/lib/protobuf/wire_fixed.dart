/// Fixed-width (32-bit / 64-bit) and field tag encoding/decoding for protobuf
/// wire format.
///
/// These functions implement:
///   - Fixed-width little-endian encoding for 32-bit and 64-bit unsigned
///     integers (wire types 5 and 1 respectively).
///   - Field tag encoding/decoding, where a tag is `(fieldNumber << 3) | wireType`
///     serialized as a varint.
///
/// No imports beyond implicit `dart:core`. All operations use only standard
/// Dart integer arithmetic, bitwise ops, and list manipulation -- primitives
/// that map directly to Ball `std` base functions.
///
/// References:
///   - https://protobuf.dev/programming-guides/encoding/#non-varint-numbers
///   - https://protobuf.dev/programming-guides/encoding/#structure
///
/// Test vectors:
///   encodeFixed32([], 0)           -> [0, 0, 0, 0]
///   encodeFixed32([], 1)           -> [1, 0, 0, 0]
///   encodeFixed32([], 256)         -> [0, 1, 0, 0]
///   encodeFixed32([], 0xFFFFFFFF)  -> [255, 255, 255, 255]
///   decodeFixed32([1, 0, 0, 0], 0) -> {value: 1, bytesRead: 4}
///
///   encodeFixed64([], 0)           -> [0, 0, 0, 0, 0, 0, 0, 0]
///   encodeFixed64([], 1)           -> [1, 0, 0, 0, 0, 0, 0, 0]
///   encodeFixed64([], 256)         -> [0, 1, 0, 0, 0, 0, 0, 0]
///   decodeFixed64([1, 0, 0, 0, 0, 0, 0, 0], 0) -> {value: 1, bytesRead: 8}
///
///   encodeTag([], 1, 0) -> [8]    (field 1, varint)
///   encodeTag([], 2, 2) -> [18]   (field 2, length-delimited)
///   decodeTag([8], 0)   -> {fieldNumber: 1, wireType: 0, bytesRead: 1}
library;

/// Appends 4 little-endian bytes representing [value] as an unsigned 32-bit
/// integer to [buffer].
///
/// The value is masked to 32 bits before encoding so that only the lowest 4
/// bytes are emitted regardless of the Dart int's full 64-bit range.
///
/// Returns the same [buffer] list with the 4 bytes appended, allowing fluent
/// chaining.
List<int> encodeFixed32(List<int> buffer, int value) {
  buffer.add(value & 0xFF);
  buffer.add((value >>> 8) & 0xFF);
  buffer.add((value >>> 16) & 0xFF);
  buffer.add((value >>> 24) & 0xFF);
  return buffer;
}

/// Decodes 4 little-endian bytes from [buffer] starting at [offset] as an
/// unsigned 32-bit integer.
///
/// Returns a map with two entries:
///   - `'value'`: the decoded 32-bit unsigned integer.
///   - `'bytesRead'`: always 4.
///
/// Throws a [RangeError] if there are fewer than 4 bytes available starting
/// at [offset].
Map<String, int> decodeFixed32(List<int> buffer, int offset) {
  if (offset + 4 > buffer.length) {
    throw RangeError(
      'Not enough bytes to decode fixed32 at offset $offset '
      '(need 4, have ${buffer.length - offset})',
    );
  }
  int value = buffer[offset] |
      (buffer[offset + 1] << 8) |
      (buffer[offset + 2] << 16) |
      (buffer[offset + 3] << 24);
  // Mask to unsigned 32-bit to avoid sign extension on 64-bit Dart ints.
  value = value & 0xFFFFFFFF;
  return {'value': value, 'bytesRead': 4};
}

/// Appends 8 little-endian bytes representing [value] as an unsigned 64-bit
/// integer to [buffer].
///
/// On the Dart VM, `int` is a 64-bit two's-complement integer. Negative
/// values will encode as their unsigned bit pattern.
///
/// Returns the same [buffer] list with the 8 bytes appended, allowing fluent
/// chaining.
List<int> encodeFixed64(List<int> buffer, int value) {
  buffer.add(value & 0xFF);
  buffer.add((value >>> 8) & 0xFF);
  buffer.add((value >>> 16) & 0xFF);
  buffer.add((value >>> 24) & 0xFF);
  buffer.add((value >>> 32) & 0xFF);
  buffer.add((value >>> 40) & 0xFF);
  buffer.add((value >>> 48) & 0xFF);
  buffer.add((value >>> 56) & 0xFF);
  return buffer;
}

/// Decodes 8 little-endian bytes from [buffer] starting at [offset] as an
/// unsigned 64-bit integer.
///
/// Returns a map with two entries:
///   - `'value'`: the decoded 64-bit integer.
///   - `'bytesRead'`: always 8.
///
/// Throws a [RangeError] if there are fewer than 8 bytes available starting
/// at [offset].
Map<String, int> decodeFixed64(List<int> buffer, int offset) {
  if (offset + 8 > buffer.length) {
    throw RangeError(
      'Not enough bytes to decode fixed64 at offset $offset '
      '(need 8, have ${buffer.length - offset})',
    );
  }
  int value = buffer[offset] |
      (buffer[offset + 1] << 8) |
      (buffer[offset + 2] << 16) |
      (buffer[offset + 3] << 24) |
      (buffer[offset + 4] << 32) |
      (buffer[offset + 5] << 40) |
      (buffer[offset + 6] << 48) |
      (buffer[offset + 7] << 56);
  return {'value': value, 'bytesRead': 8};
}

/// Encodes a protobuf field tag and appends the varint-encoded bytes to
/// [buffer].
///
/// A field tag combines the [fieldNumber] and [wireType] into a single varint:
///   `tagValue = (fieldNumber << 3) | wireType`
///
/// Standard wire types:
///   - 0: VARINT (int32, int64, uint32, uint64, sint32, sint64, bool, enum)
///   - 1: I64 (fixed64, sfixed64, double)
///   - 2: LEN (string, bytes, embedded messages, packed repeated fields)
///   - 5: I32 (fixed32, sfixed32, float)
///
/// The varint encoding is inlined here (identical to `encodeVarint` from
/// `wire_varint.dart`) to avoid cross-file imports, which simplifies Ball
/// compilation.
///
/// Returns the same [buffer] list with the tag bytes appended.
List<int> encodeTag(List<int> buffer, int fieldNumber, int wireType) {
  int tagValue = (fieldNumber << 3) | wireType;
  // Inline varint encoding (LEB128).
  do {
    int byte = tagValue & 0x7F;
    tagValue = tagValue >>> 7;
    if (tagValue != 0) {
      byte = byte | 0x80;
    }
    buffer.add(byte);
  } while (tagValue != 0);
  return buffer;
}

/// Decodes a protobuf field tag from [buffer] starting at [offset].
///
/// Returns a map with three entries:
///   - `'fieldNumber'`: the field number extracted from the tag.
///   - `'wireType'`: the wire type (lowest 3 bits of the tag value).
///   - `'bytesRead'`: the number of bytes consumed (the varint length).
///
/// The varint decoding is inlined here to avoid cross-file imports.
///
/// Throws a [FormatException] if the varint exceeds 10 bytes or the buffer
/// ends before the varint is complete.
Map<String, int> decodeTag(List<int> buffer, int offset) {
  // Inline varint decoding.
  int result = 0;
  int shift = 0;
  int bytesRead = 0;

  while (true) {
    if (offset + bytesRead >= buffer.length) {
      throw FormatException(
        'Unexpected end of buffer while decoding tag varint at offset $offset',
      );
    }

    int byte = buffer[offset + bytesRead];
    bytesRead++;

    result = result | ((byte & 0x7F) << shift);
    shift += 7;

    if ((byte & 0x80) == 0) {
      break;
    }

    if (bytesRead >= 10) {
      throw FormatException(
        'Tag varint exceeds maximum length of 10 bytes at offset $offset',
      );
    }
  }

  int wireType = result & 0x07;
  int fieldNumber = result >>> 3;
  return {
    'fieldNumber': fieldNumber,
    'wireType': wireType,
    'bytesRead': bytesRead,
  };
}
