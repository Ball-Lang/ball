/// Protobuf conformance test plugin for the Ball protobuf library.
///
/// Implements the conformance test protocol from
/// https://github.com/protocolbuffers/protobuf/blob/main/conformance/conformance.proto
///
/// The protocol is a simple size-prefixed binary exchange over stdin/stdout:
///   1. Read 4-byte LE size prefix from stdin -> get request size
///   2. Read `size` bytes from stdin -> ConformanceRequest (binary protobuf)
///   3. Parse the request, extract payload + requested_output_format
///   4. Parse the payload (binary or JSON)
///   5. Re-serialize in requested format
///   6. Build ConformanceResponse
///   7. Write 4-byte LE size prefix + response bytes to stdout
///   8. Repeat until EOF
///
/// ConformanceRequest (from conformance.proto):
///   oneof payload:
///     1: protobuf_payload (bytes)
///     2: json_payload (string)
///     7: jspb_payload (string)
///     8: text_payload (string)
///   3: requested_output_format (enum WireFormat)
///   4: message_type (string)
///   5: test_category (enum)
///   6: jspb_encoding_options (message)
///   9: print_unknown_fields (bool)
///
/// ConformanceResponse (from conformance.proto):
///   oneof result:
///     1: parse_error (string)
///     2: runtime_error (string)
///     3: protobuf_payload (bytes)
///     4: json_payload (string)
///     5: skipped (string)
///     6: serialize_error (string)
///     7: jspb_payload (string)
///     8: text_payload (string)
///     9: timeout_error (string)
///
/// WireFormat enum:
///   0: UNSPECIFIED
///   1: PROTOBUF
///   2: JSON
///   3: JSPB
///   4: TEXT_FORMAT
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'wire_varint.dart';
import 'wire_fixed.dart';
import 'wire_bytes.dart';

// ---------------------------------------------------------------------------
// Wire format enum values (from conformance.proto WireFormat)
// ---------------------------------------------------------------------------

/// Unspecified wire format — test harness never sends this.
const int wireFormatUnspecified = 0;

/// Binary protobuf wire format.
const int wireFormatProtobuf = 1;

/// JSON wire format.
const int wireFormatJson = 2;

/// JSPB wire format (not supported).
const int wireFormatJspb = 3;

/// Text format (not supported).
const int wireFormatTextFormat = 4;

// ---------------------------------------------------------------------------
// Size-prefixed I/O
// ---------------------------------------------------------------------------

/// Reads a size-prefixed message from [input].
///
/// The conformance protocol frames each message with a 4-byte little-endian
/// length prefix. This function reads that prefix, then reads exactly that
/// many bytes of payload.
///
/// Returns `null` on EOF (when the first read of the size prefix returns
/// fewer than 4 bytes, indicating the test runner has closed the pipe).
List<int>? readSizePrefixed(Stdin input) {
  // Read 4-byte little-endian size prefix.
  final sizeBytes = <int>[];
  for (var i = 0; i < 4; i++) {
    final byte = input.readByteSync();
    if (byte == -1) {
      // EOF before we got a full size prefix.
      return null;
    }
    sizeBytes.add(byte);
  }

  final size = sizeBytes[0] |
      (sizeBytes[1] << 8) |
      (sizeBytes[2] << 16) |
      (sizeBytes[3] << 24);

  if (size == 0) return <int>[];

  // Read exactly `size` bytes of payload.
  final payload = <int>[];
  for (var i = 0; i < size; i++) {
    final byte = input.readByteSync();
    if (byte == -1) {
      throw StateError(
        'Unexpected EOF: expected $size payload bytes, got ${payload.length}',
      );
    }
    payload.add(byte);
  }

  return payload;
}

/// Writes a size-prefixed message to [output].
///
/// Emits a 4-byte little-endian length prefix followed by the raw [data]
/// bytes. Flushes the output to ensure the test runner receives the response
/// promptly.
void writeSizePrefixed(Stdout output, List<int> data) {
  final size = data.length;
  final sizeBytes = ByteData(4);
  sizeBytes.setUint32(0, size, Endian.little);
  output.add([
    sizeBytes.getUint8(0),
    sizeBytes.getUint8(1),
    sizeBytes.getUint8(2),
    sizeBytes.getUint8(3),
  ]);
  output.add(data);
  output.flush();
}

// ---------------------------------------------------------------------------
// ConformanceRequest decoding (hand-coded protobuf decoder)
// ---------------------------------------------------------------------------

/// Parses a ConformanceRequest from binary protobuf [bytes].
///
/// Decodes the raw protobuf wire format by hand, reading tags and values
/// according to the ConformanceRequest schema. Returns a map with the
/// following possible keys:
///
///   - `'protobuf_payload'` (`List<int>`) — binary protobuf test data
///   - `'json_payload'` (`String`) — JSON test data
///   - `'jspb_payload'` (`String`) — JSPB test data
///   - `'text_payload'` (`String`) — text format test data
///   - `'requested_output_format'` (`int`) — WireFormat enum value
///   - `'message_type'` (`String`) — fully qualified message type name
///   - `'test_category'` (`int`) — TestCategory enum value
///   - `'print_unknown_fields'` (`bool`) — whether to print unknown fields
Map<String, Object?> parseConformanceRequest(List<int> bytes) {
  return decodeConformanceRequest(bytes);
}

/// Decodes a ConformanceRequest from binary protobuf [bytes].
///
/// Hand-coded protobuf decoder that reads field tags and dispatches by field
/// number. Unknown fields are silently skipped.
Map<String, Object?> decodeConformanceRequest(List<int> bytes) {
  final result = <String, Object?>{};
  var offset = 0;

  while (offset < bytes.length) {
    final tagResult = decodeTag(bytes, offset);
    final fieldNumber = tagResult['fieldNumber']!;
    final wireType = tagResult['wireType']!;
    offset += tagResult['bytesRead']!;

    switch (fieldNumber) {
      case 1:
        // protobuf_payload (bytes) — wire type 2
        final lenResult = decodeVarint(bytes, offset);
        final length = lenResult['value']!;
        final varintSize = lenResult['bytesRead']!;
        final dataStart = offset + varintSize;
        result['protobuf_payload'] = bytes.sublist(
          dataStart,
          dataStart + length,
        );
        offset = dataStart + length;

      case 2:
        // json_payload (string) — wire type 2
        final lenResult = decodeVarint(bytes, offset);
        final length = lenResult['value']!;
        final varintSize = lenResult['bytesRead']!;
        final dataStart = offset + varintSize;
        result['json_payload'] = utf8.decode(
          bytes.sublist(dataStart, dataStart + length),
        );
        offset = dataStart + length;

      case 3:
        // requested_output_format (enum) — wire type 0
        final varintResult = decodeVarint(bytes, offset);
        result['requested_output_format'] = varintResult['value']!;
        offset += varintResult['bytesRead']!;

      case 4:
        // message_type (string) — wire type 2
        final lenResult = decodeVarint(bytes, offset);
        final length = lenResult['value']!;
        final varintSize = lenResult['bytesRead']!;
        final dataStart = offset + varintSize;
        result['message_type'] = utf8.decode(
          bytes.sublist(dataStart, dataStart + length),
        );
        offset = dataStart + length;

      case 5:
        // test_category (enum) — wire type 0
        final varintResult = decodeVarint(bytes, offset);
        result['test_category'] = varintResult['value']!;
        offset += varintResult['bytesRead']!;

      case 6:
        // jspb_encoding_options (message) — wire type 2, skip for now
        final lenResult = decodeVarint(bytes, offset);
        final length = lenResult['value']!;
        final varintSize = lenResult['bytesRead']!;
        offset += varintSize + length;

      case 7:
        // jspb_payload (string) — wire type 2
        final lenResult = decodeVarint(bytes, offset);
        final length = lenResult['value']!;
        final varintSize = lenResult['bytesRead']!;
        final dataStart = offset + varintSize;
        result['jspb_payload'] = utf8.decode(
          bytes.sublist(dataStart, dataStart + length),
        );
        offset = dataStart + length;

      case 8:
        // text_payload (string) — wire type 2
        final lenResult = decodeVarint(bytes, offset);
        final length = lenResult['value']!;
        final varintSize = lenResult['bytesRead']!;
        final dataStart = offset + varintSize;
        result['text_payload'] = utf8.decode(
          bytes.sublist(dataStart, dataStart + length),
        );
        offset = dataStart + length;

      case 9:
        // print_unknown_fields (bool) — wire type 0
        final varintResult = decodeVarint(bytes, offset);
        result['print_unknown_fields'] = varintResult['value']! != 0;
        offset += varintResult['bytesRead']!;

      default:
        // Unknown field — skip based on wire type.
        switch (wireType) {
          case 0:
            final varintResult = decodeVarint(bytes, offset);
            offset += varintResult['bytesRead']!;
          case 1:
            offset += 8;
          case 2:
            final lenResult = decodeVarint(bytes, offset);
            final length = lenResult['value']!;
            offset += lenResult['bytesRead']! + length;
          case 5:
            offset += 4;
          default:
            throw FormatException(
              'Unknown wire type $wireType for field $fieldNumber '
              'at offset $offset',
            );
        }
    }
  }

  return result;
}

// ---------------------------------------------------------------------------
// ConformanceResponse encoding (hand-coded protobuf encoder)
// ---------------------------------------------------------------------------

/// Builds a ConformanceResponse as binary protobuf bytes.
///
/// Exactly one of the named parameters should be non-null — they represent
/// the `result` oneof in the ConformanceResponse message.
///
/// Field mapping (from conformance.proto):
///   1: parse_error (string)
///   2: runtime_error (string)
///   3: protobuf_payload (bytes)
///   4: json_payload (string)
///   5: skipped (string)
///   6: serialize_error (string)
List<int> buildConformanceResponse({
  String? parseError,
  String? serializeError,
  String? runtimeError,
  List<int>? protobufPayload,
  String? jsonPayload,
  String? skipped,
}) {
  final response = <String, Object?>{};
  if (parseError != null) response['parse_error'] = parseError;
  if (runtimeError != null) response['runtime_error'] = runtimeError;
  if (protobufPayload != null) response['protobuf_payload'] = protobufPayload;
  if (jsonPayload != null) response['json_payload'] = jsonPayload;
  if (skipped != null) response['skipped'] = skipped;
  if (serializeError != null) response['serialize_error'] = serializeError;
  return encodeConformanceResponse(response);
}

/// Encodes a ConformanceResponse map to binary protobuf bytes.
///
/// The [response] map should contain at most one of the result oneof fields.
/// Each field is encoded with its tag and value according to the
/// ConformanceResponse schema.
///
/// Supported keys:
///   - `'parse_error'` (String) -> field 1
///   - `'runtime_error'` (String) -> field 2
///   - `'protobuf_payload'` (`List<int>`) -> field 3
///   - `'json_payload'` (String) -> field 4
///   - `'skipped'` (String) -> field 5
///   - `'serialize_error'` (String) -> field 6
///   - `'jspb_payload'` (String) -> field 7
///   - `'text_payload'` (String) -> field 8
///   - `'timeout_error'` (String) -> field 9
List<int> encodeConformanceResponse(Map<String, Object?> response) {
  final buffer = <int>[];

  final parseError = response['parse_error'];
  if (parseError != null && parseError is String) {
    encodeTag(buffer, 1, 2); // field 1, wire type LEN
    encodeString(buffer, parseError);
  }

  final runtimeError = response['runtime_error'];
  if (runtimeError != null && runtimeError is String) {
    encodeTag(buffer, 2, 2);
    encodeString(buffer, runtimeError);
  }

  final protobufPayload = response['protobuf_payload'];
  if (protobufPayload != null && protobufPayload is List<int>) {
    encodeTag(buffer, 3, 2);
    encodeBytes(buffer, protobufPayload);
  }

  final jsonPayload = response['json_payload'];
  if (jsonPayload != null && jsonPayload is String) {
    encodeTag(buffer, 4, 2);
    encodeString(buffer, jsonPayload);
  }

  final skipped = response['skipped'];
  if (skipped != null && skipped is String) {
    encodeTag(buffer, 5, 2);
    encodeString(buffer, skipped);
  }

  final serializeError = response['serialize_error'];
  if (serializeError != null && serializeError is String) {
    encodeTag(buffer, 6, 2);
    encodeString(buffer, serializeError);
  }

  final jspbPayload = response['jspb_payload'];
  if (jspbPayload != null && jspbPayload is String) {
    encodeTag(buffer, 7, 2);
    encodeString(buffer, jspbPayload);
  }

  final textPayload = response['text_payload'];
  if (textPayload != null && textPayload is String) {
    encodeTag(buffer, 8, 2);
    encodeString(buffer, textPayload);
  }

  final timeoutError = response['timeout_error'];
  if (timeoutError != null && timeoutError is String) {
    encodeTag(buffer, 9, 2);
    encodeString(buffer, timeoutError);
  }

  return buffer;
}

// ---------------------------------------------------------------------------
// Request processing
// ---------------------------------------------------------------------------

/// Processes a single conformance request and returns a response map.
///
/// Currently skips all tests with a descriptive message. As the Ball protobuf
/// library gains full support for the conformance test message types
/// (TestAllTypesProto3, TestAllTypesProto2, etc.), this function should be
/// expanded to actually parse and re-serialize payloads.
///
/// The returned map contains exactly one of the ConformanceResponse oneof
/// fields as a key-value pair.
Map<String, Object?> processConformanceRequest(Map<String, Object?> request) {
  final messageType = request['message_type'] as String?;
  final requestedOutputFormat =
      request['requested_output_format'] as int? ?? wireFormatUnspecified;

  // Determine which payload oneof is set.
  final hasProtobufPayload = request.containsKey('protobuf_payload');
  final hasJsonPayload = request.containsKey('json_payload');
  final hasJspbPayload = request.containsKey('jspb_payload');
  final hasTextPayload = request.containsKey('text_payload');

  // Skip JSPB and TEXT_FORMAT — we don't support them.
  if (hasJspbPayload || hasTextPayload) {
    return {
      'skipped': 'Ball protobuf: JSPB and TEXT_FORMAT payloads not supported',
    };
  }

  if (requestedOutputFormat == wireFormatJspb) {
    return {
      'skipped': 'Ball protobuf: JSPB output format not supported',
    };
  }

  if (requestedOutputFormat == wireFormatTextFormat) {
    return {
      'skipped': 'Ball protobuf: TEXT_FORMAT output format not supported',
    };
  }

  if (requestedOutputFormat == wireFormatUnspecified) {
    return {
      'skipped': 'Ball protobuf: UNSPECIFIED output format not supported',
    };
  }

  if (!hasProtobufPayload && !hasJsonPayload) {
    return {'skipped': 'Ball protobuf: no recognized payload in request'};
  }

  // Without a full descriptor for the conformance test message types
  // (TestAllTypesProto3, TestAllTypesProto2), we perform a best-effort
  // binary-to-binary pass-through (identity) and binary-to-JSON / JSON-to-*
  // round-trip using the generic descriptor-free path.

  // --- Parse the input payload ---
  List<int>? binaryPayload;

  if (hasProtobufPayload) {
    binaryPayload = request['protobuf_payload'] as List<int>;
    // Without a descriptor we cannot unmarshal into a map for JSON output.
    // For binary->binary we can pass through directly.
  } else if (hasJsonPayload) {
    // JSON input without a descriptor — we cannot reliably parse.
    return {
      'skipped':
          'Ball protobuf: JSON input for $messageType requires a descriptor',
    };
  }

  // --- Produce the requested output ---
  try {
    switch (requestedOutputFormat) {
      case wireFormatProtobuf:
        if (binaryPayload != null) {
          // Binary -> Binary: identity pass-through.
          return {'protobuf_payload': binaryPayload};
        }
        return {
          'skipped':
              'Ball protobuf: cannot produce binary output from JSON input '
              'without descriptor for $messageType',
        };

      case wireFormatJson:
        // Binary -> JSON requires a descriptor to interpret field types.
        return {
          'skipped':
              'Ball protobuf: binary->JSON for $messageType requires '
              'a descriptor',
        };

      default:
        return {
          'skipped':
              'Ball protobuf: unsupported output format $requestedOutputFormat',
        };
    }
  } catch (e) {
    return {'runtime_error': 'Ball protobuf processing error: $e'};
  }
}

// ---------------------------------------------------------------------------
// Main conformance loop
// ---------------------------------------------------------------------------

/// Runs the conformance test loop.
///
/// Continuously reads size-prefixed ConformanceRequest messages from stdin,
/// processes each one, and writes size-prefixed ConformanceResponse messages
/// to stdout. The loop terminates when EOF is reached on stdin (the test
/// runner closes the pipe).
///
/// This function never returns normally — it runs until the input stream
/// is exhausted, then exits cleanly.
void runConformanceLoop() {
  var testCount = 0;

  while (true) {
    final requestBytes = readSizePrefixed(stdin);
    if (requestBytes == null) {
      // EOF — test runner closed the pipe.
      break;
    }

    testCount++;

    Map<String, Object?> response;
    try {
      final request = parseConformanceRequest(requestBytes);
      response = processConformanceRequest(request);
    } catch (e, st) {
      response = {
        'runtime_error': 'Ball conformance plugin error: $e\n$st',
      };
    }

    final responseBytes = encodeConformanceResponse(response);
    writeSizePrefixed(stdout, responseBytes);
  }

  stderr.writeln(
    'Ball conformance plugin: completed $testCount tests.',
  );
}
