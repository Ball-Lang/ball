/// Descriptor-driven protobuf binary unmarshaling (decoding).
///
/// Decodes raw protobuf binary bytes into a message represented as
/// `Map<String, Object?>`, using a list of field descriptors that map field
/// numbers to names and types.
///
/// Field descriptor format (same as marshal):
/// ```dart
/// {
///   'number': int,        // protobuf field number
///   'name': String,       // field name in the output map
///   'type': String,       // protobuf type: int32, uint32, sint32, int64,
///                         //   uint64, sint64, bool, enum, fixed32, sfixed32,
///                         //   fixed64, sfixed64, float, double, string,
///                         //   bytes, message
///   'repeated': bool?,    // true if the field is repeated (optional)
///   'mapEntry': bool?,    // true if this is a map field (optional)
///   'keyType': String?,   // map key type (required if mapEntry is true)
///   'valueType': String?, // map value type (required if mapEntry is true)
///   'messageDescriptor':  // sub-message descriptor (for type == 'message')
///       List<Map<String, Object?>>?,
/// }
/// ```
///
/// References:
///   - https://protobuf.dev/programming-guides/encoding/
///   - https://protobuf.dev/programming-guides/encoding/#structure
library;

import 'wire_varint.dart';
import 'wire_fixed.dart';
import 'field_int.dart';
import 'field_fixed.dart';
import 'field_len.dart';

/// Find a field descriptor by field number.
///
/// Scans [descriptor] for an entry whose `'number'` matches [fieldNumber].
/// Returns `null` if no matching descriptor is found (unknown field).
Map<String, Object?>? findFieldByNumber(
  List<Map<String, Object?>> descriptor,
  int fieldNumber,
) {
  for (int i = 0; i < descriptor.length; i++) {
    if (descriptor[i]['number'] == fieldNumber) {
      return descriptor[i];
    }
  }
  return null;
}

/// Skip an unknown field (field number not in descriptor).
///
/// Returns the number of bytes consumed (not counting the tag, which the
/// caller has already read).
///
/// Wire type mapping:
///   - 0 (VARINT): read and discard a varint
///   - 1 (I64): skip 8 bytes
///   - 2 (LEN): read length varint, skip that many bytes
///   - 5 (I32): skip 4 bytes
///
/// Throws [FormatException] for unsupported wire types (3, 4 are deprecated
/// group start/end).
int skipField(List<int> bytes, int offset, int wireType) {
  switch (wireType) {
    case 0:
      // VARINT: read until continuation bit is clear.
      final result = decodeVarint(bytes, offset);
      return result['bytesRead']!;
    case 1:
      // I64: always 8 bytes.
      return 8;
    case 2:
      // LEN: varint length prefix + that many bytes.
      final result = decodeVarint(bytes, offset);
      final length = result['value']!;
      final varintSize = result['bytesRead']!;
      return varintSize + length;
    case 5:
      // I32: always 4 bytes.
      return 4;
    default:
      throw FormatException(
        'Unknown or unsupported wire type $wireType at offset $offset',
      );
  }
}

/// Decode a single field value given its wire type and field type.
///
/// [bytes] is the full message buffer, [offset] points to the start of the
/// value (after the tag). [wireType] is from the tag. [fieldType] is the
/// protobuf type string from the descriptor.
///
/// Returns a map with:
///   - `'value'`: the decoded value
///   - `'bytesRead'`: bytes consumed
Map<String, Object?> unmarshalFieldValue(
  List<int> bytes,
  int offset,
  int wireType,
  String fieldType,
) {
  switch (wireType) {
    case 0:
      // VARINT
      final result = decodeVarint(bytes, offset);
      final rawVarint = result['value']!;
      final bytesRead = result['bytesRead']!;
      final Object value;
      switch (fieldType) {
        case 'int32':
          value = decodeAsInt32(rawVarint);
        case 'uint32':
          value = decodeAsUint32(rawVarint);
        case 'sint32':
          value = decodeAsSint32(rawVarint);
        case 'sint64':
          value = decodeAsSint64(rawVarint);
        case 'bool':
          value = decodeAsBool(rawVarint);
        case 'enum':
          value = rawVarint;
        case 'int64':
        case 'uint64':
          value = rawVarint;
        default:
          // For unknown varint-based types, return raw value.
          value = rawVarint;
      }
      return {'value': value, 'bytesRead': bytesRead};

    case 1:
      // I64: fixed64, sfixed64, double
      if (fieldType == 'double') {
        final value = decodeDouble(bytes, offset);
        return {'value': value, 'bytesRead': 8};
      }
      final result = decodeFixed64(bytes, offset);
      final int rawValue = result['value']!;
      if (fieldType == 'sfixed64') {
        // sfixed64 uses two's-complement, same bit pattern as fixed64.
        return {'value': rawValue, 'bytesRead': 8};
      }
      return {'value': rawValue, 'bytesRead': 8};

    case 2:
      // LEN: string, bytes, message, packed repeated
      final lenResult = decodeVarint(bytes, offset);
      final length = lenResult['value']!;
      final varintSize = lenResult['bytesRead']!;
      final dataStart = offset + varintSize;
      final data = bytes.sublist(dataStart, dataStart + length);
      final totalBytesRead = varintSize + length;

      final Object value;
      switch (fieldType) {
        case 'string':
          value = decodeStringValue(data);
        case 'bytes':
          value = data;
        case 'message':
          // Return raw bytes; the caller must unmarshal with sub-descriptor.
          value = data;
        default:
          // For other types in LEN wire format, return raw bytes (could be
          // packed repeated or unknown).
          value = data;
      }
      return {'value': value, 'bytesRead': totalBytesRead};

    case 5:
      // I32: fixed32, sfixed32, float
      if (fieldType == 'float') {
        final value = decodeFloat(bytes, offset);
        return {'value': value, 'bytesRead': 4};
      }
      final result = decodeFixed32(bytes, offset);
      final int rawValue = result['value']!;
      if (fieldType == 'sfixed32') {
        // sfixed32: sign-extend from 32 bits.
        final signed = (rawValue << 32) >> 32;
        return {'value': signed, 'bytesRead': 4};
      }
      return {'value': rawValue, 'bytesRead': 4};

    default:
      throw FormatException(
        'Unknown wire type $wireType at offset $offset',
      );
  }
}

/// Decode a repeated field. Handles both packed (wire type 2) and
/// unpacked (each element has its own tag) encoding.
///
/// For packed encoding (wire type 2), the length-delimited data contains
/// multiple values concatenated together. For unpacked, this function
/// decodes a single element and returns it as a one-element list.
///
/// [bytes] is the full buffer, [offset] is the start of the value data
/// (after the tag), [wireType] is from the tag, and [fieldType] is the
/// element type.
///
/// Returns a map with:
///   - `'values'`: `List<Object?>` of decoded values
///   - `'bytesRead'`: bytes consumed
Map<String, Object?> unmarshalRepeated(
  List<int> bytes,
  int offset,
  int wireType,
  String fieldType,
) {
  // Check if this is packed encoding: wire type 2 for scalar types.
  if (wireType == 2 && _isPackableType(fieldType)) {
    // Packed: length-delimited blob of concatenated values.
    final lenResult = decodeVarint(bytes, offset);
    final length = lenResult['value']!;
    final varintSize = lenResult['bytesRead']!;
    final dataStart = offset + varintSize;
    final data = bytes.sublist(dataStart, dataStart + length);
    final totalBytesRead = varintSize + length;

    final List<Object?> values = _decodePackedValues(data, fieldType);
    return {'values': values, 'bytesRead': totalBytesRead};
  }

  // Unpacked: single element with its own tag.
  final result = unmarshalFieldValue(bytes, offset, wireType, fieldType);
  return {
    'values': [result['value']],
    'bytesRead': result['bytesRead'] as int,
  };
}

/// Decode a map field entry from its raw bytes.
///
/// Protobuf maps are encoded as repeated messages where each entry has
/// field 1 = key and field 2 = value. This function decodes one such
/// entry message.
///
/// [entryBytes] is the raw bytes of the map entry message (after the
/// length prefix). [keyType] and [valueType] are the protobuf types
/// for the key and value respectively.
///
/// Returns a map with:
///   - `'key'`: the decoded key
///   - `'value'`: the decoded value
Map<String, Object?> unmarshalMapField(
  List<int> entryBytes,
  String keyType,
  String valueType,
) {
  Object? key;
  Object? value;
  int offset = 0;

  while (offset < entryBytes.length) {
    final tagResult = decodeTag(entryBytes, offset);
    final fieldNumber = tagResult['fieldNumber']!;
    final wireType = tagResult['wireType']!;
    offset += tagResult['bytesRead']!;

    if (fieldNumber == 1) {
      // Key field.
      final fieldResult = unmarshalFieldValue(
        entryBytes,
        offset,
        wireType,
        keyType,
      );
      key = fieldResult['value'];
      offset += fieldResult['bytesRead'] as int;
    } else if (fieldNumber == 2) {
      // Value field.
      final fieldResult = unmarshalFieldValue(
        entryBytes,
        offset,
        wireType,
        valueType,
      );
      value = fieldResult['value'];
      offset += fieldResult['bytesRead'] as int;
    } else {
      // Unknown field in map entry — skip.
      offset += skipField(entryBytes, offset, wireType);
    }
  }

  return {'key': key, 'value': value};
}

/// Unmarshal protobuf binary bytes to a message (`Map<String, Object?>`).
///
/// Uses field descriptors to map field numbers to names and types.
///
/// [bytes] is the protobuf binary data. [descriptor] is a list of field
/// descriptors that define the message schema.
///
/// Returns the decoded message as a map from field names to values.
/// Unknown fields (not in the descriptor) are silently skipped.
/// Repeated fields accumulate into lists. Map fields decode as
/// `Map<Object?, Object?>` keyed by the map key type.
Map<String, Object?> unmarshal(
  List<int> bytes,
  List<Map<String, Object?>> descriptor,
) {
  final Map<String, Object?> message = {};
  int offset = 0;

  while (offset < bytes.length) {
    // 1. Read the tag.
    final tagResult = decodeTag(bytes, offset);
    final fieldNumber = tagResult['fieldNumber']!;
    final wireType = tagResult['wireType']!;
    offset += tagResult['bytesRead']!;

    // 2. Look up field descriptor.
    final fieldDesc = findFieldByNumber(descriptor, fieldNumber);

    if (fieldDesc == null) {
      // Unknown field — skip it.
      offset += skipField(bytes, offset, wireType);
      continue;
    }

    final fieldName = fieldDesc['name'] as String;
    final fieldType = fieldDesc['type'] as String;
    final isRepeated = fieldDesc['repeated'] == true;
    final isMapEntry = fieldDesc['mapEntry'] == true;

    // 3. Decode the value.
    if (isMapEntry) {
      // Map field: encoded as repeated message entries.
      final keyType = fieldDesc['keyType'] as String;
      final valueType = fieldDesc['valueType'] as String;
      final valueDescriptor =
          fieldDesc['messageDescriptor'] as List<Map<String, Object?>>?;

      // Read the length-delimited entry bytes.
      final lenResult = decodeVarint(bytes, offset);
      final length = lenResult['value']!;
      final varintSize = lenResult['bytesRead']!;
      final dataStart = offset + varintSize;
      final entryBytes = bytes.sublist(dataStart, dataStart + length);
      offset += varintSize + length;

      // Decode the map entry.
      final entry = unmarshalMapField(entryBytes, keyType, valueType);
      Object? entryKey = entry['key'];
      Object? entryValue = entry['value'];

      // If the value is a message type and we have a sub-descriptor,
      // unmarshal the raw bytes into a map.
      if (valueType == 'message' &&
          valueDescriptor != null &&
          entryValue is List<int>) {
        entryValue = unmarshal(entryValue, valueDescriptor);
      }

      // Initialize the map if needed and add the entry.
      final existingMap = message[fieldName];
      if (existingMap is Map) {
        existingMap[entryKey] = entryValue;
      } else {
        message[fieldName] = {entryKey: entryValue};
      }
    } else if (isRepeated) {
      // Repeated field.
      final result = unmarshalRepeated(bytes, offset, wireType, fieldType);
      final values = result['values'] as List<Object?>;
      offset += result['bytesRead'] as int;

      // If the element type is 'message' and we have a sub-descriptor,
      // unmarshal each raw bytes element.
      final messageDescriptor =
          fieldDesc['messageDescriptor'] as List<Map<String, Object?>>?;
      final List<Object?> decodedValues;
      if (fieldType == 'message' && messageDescriptor != null) {
        decodedValues = [];
        for (final v in values) {
          if (v is List<int>) {
            decodedValues.add(unmarshal(v, messageDescriptor));
          } else {
            decodedValues.add(v);
          }
        }
      } else {
        decodedValues = values;
      }

      // Append to existing list or create new one.
      final existing = message[fieldName];
      if (existing is List) {
        existing.addAll(decodedValues);
      } else {
        message[fieldName] = List<Object?>.from(decodedValues);
      }
    } else {
      // Singular field.
      final result = unmarshalFieldValue(bytes, offset, wireType, fieldType);
      Object? value = result['value'];
      offset += result['bytesRead'] as int;

      // If the field is a message type and we have a sub-descriptor,
      // unmarshal the raw bytes.
      final messageDescriptor =
          fieldDesc['messageDescriptor'] as List<Map<String, Object?>>?;
      if (fieldType == 'message' &&
          messageDescriptor != null &&
          value is List<int>) {
        value = unmarshal(value, messageDescriptor);
      }

      message[fieldName] = value;
    }
  }

  return message;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Whether a protobuf field type can be packed (scalar numeric / bool / enum).
bool _isPackableType(String fieldType) {
  switch (fieldType) {
    case 'int32':
    case 'int64':
    case 'uint32':
    case 'uint64':
    case 'sint32':
    case 'sint64':
    case 'bool':
    case 'enum':
    case 'fixed32':
    case 'sfixed32':
    case 'fixed64':
    case 'sfixed64':
    case 'float':
    case 'double':
      return true;
    default:
      return false;
  }
}

/// Decode packed scalar values from a length-delimited blob.
List<Object?> _decodePackedValues(List<int> data, String fieldType) {
  final List<Object?> values = [];
  int offset = 0;

  switch (fieldType) {
    // Varint-based types.
    case 'int32':
      final raw = decodePackedVarints(data);
      for (final v in raw) {
        values.add(decodeAsInt32(v));
      }
    case 'uint32':
      final raw = decodePackedVarints(data);
      for (final v in raw) {
        values.add(decodeAsUint32(v));
      }
    case 'sint32':
      final raw = decodePackedVarints(data);
      for (final v in raw) {
        values.add(decodeAsSint32(v));
      }
    case 'sint64':
      final raw = decodePackedVarints(data);
      for (final v in raw) {
        values.add(decodeAsSint64(v));
      }
    case 'int64':
    case 'uint64':
      values.addAll(decodePackedVarints(data));
    case 'bool':
      final raw = decodePackedVarints(data);
      for (final v in raw) {
        values.add(decodeAsBool(v));
      }
    case 'enum':
      values.addAll(decodePackedVarints(data));

    // Fixed32-based types.
    case 'fixed32':
    case 'sfixed32':
      final raw = decodePackedFixed32(data);
      if (fieldType == 'sfixed32') {
        for (final v in raw) {
          values.add((v << 32) >> 32); // sign-extend
        }
      } else {
        values.addAll(raw);
      }
    case 'float':
      while (offset < data.length) {
        values.add(decodeFloat(data, offset));
        offset += 4;
      }

    // Fixed64-based types.
    case 'fixed64':
    case 'sfixed64':
      while (offset < data.length) {
        final result = decodeFixed64(data, offset);
        values.add(result['value']!);
        offset += 8;
      }
    case 'double':
      while (offset < data.length) {
        values.add(decodeDouble(data, offset));
        offset += 8;
      }
  }

  return values;
}
