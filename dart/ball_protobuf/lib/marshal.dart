/// Descriptor-driven protobuf message marshaling (encoding).
///
/// Encodes a message represented as `Map<String, Object?>` into protobuf
/// binary bytes, using a field descriptor list to determine field numbers,
/// types, and encoding rules.
///
/// Each field descriptor is a `Map<String, Object?>` with:
///   - `'name'`     : field name (`String`)
///   - `'number'`   : field number (`int`)
///   - `'type'`     : protobuf type string, e.g. `'TYPE_INT32'`, `'TYPE_STRING'`
///   - `'label'`    : `'LABEL_REPEATED'` for repeated fields; absent or other
///                     value for singular fields
///   - `'typeName'` : for `TYPE_MESSAGE` / `TYPE_ENUM`, the fully-qualified
///                     message or enum type name (optional for scalar types)
///   - `'mapEntry'` : if present and `true`, indicates this message type is a
///                     map entry (has `key` = 1 and `value` = 2)
///   - `'keyType'`  : for map fields, the protobuf type of the key
///   - `'valueType'`: for map fields, the protobuf type of the value
///   - `'messageDescriptor'` : for `TYPE_MESSAGE` fields, the nested field
///                     descriptor list for the submessage
///
/// Proto3 rules applied:
///   - Singular scalar fields with default values (0, false, "", empty list/map)
///     are not serialized.
///   - Repeated scalar fields use packed encoding by default.
///   - Map fields are serialized as repeated message fields with key=1, value=2.
///
/// References:
///   - https://protobuf.dev/programming-guides/encoding/
///   - https://protobuf.dev/programming-guides/proto3/#maps
library;

import 'dart:convert';
import 'dart:typed_data';

import 'editions.dart';
import 'wire_varint.dart';
import 'wire_fixed.dart';
import 'wire_bytes.dart';
import 'field_int.dart';
import 'field_fixed.dart';
import 'field_len.dart';
import 'unmarshal.dart' show unknownFieldsKey;

// ---------------------------------------------------------------------------
// Wire type constants
// ---------------------------------------------------------------------------

/// Wire type 0: varint — int32, int64, uint32, uint64, sint32, sint64, bool, enum.
const int _wtVarint = 0;

/// Wire type 1: 64-bit — fixed64, sfixed64, double.
const int _wtI64 = 1;

/// Wire type 2: length-delimited — string, bytes, messages, packed repeated.
const int _wtLen = 2;

/// Wire type 3: start-group — the opening tag of a DELIMITED (group) message.
const int _wtSGroup = 3;

/// Wire type 4: end-group — the closing tag of a DELIMITED (group) message.
const int _wtEGroup = 4;

/// Wire type 5: 32-bit — fixed32, sfixed32, float.
const int _wtI32 = 5;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Returns the wire type for a protobuf field [type] string.
///
/// The [type] must be one of the `TYPE_*` constants from
/// `FieldDescriptorProto.Type` (e.g. `'TYPE_INT32'`, `'TYPE_STRING'`).
///
/// Throws [ArgumentError] for unrecognized type strings.
int wireTypeForFieldType(String type) {
  switch (type) {
    case 'TYPE_INT32':
    case 'TYPE_INT64':
    case 'TYPE_UINT32':
    case 'TYPE_UINT64':
    case 'TYPE_SINT32':
    case 'TYPE_SINT64':
    case 'TYPE_BOOL':
    case 'TYPE_ENUM':
      return _wtVarint;

    case 'TYPE_FIXED64':
    case 'TYPE_SFIXED64':
    case 'TYPE_DOUBLE':
      return _wtI64;

    case 'TYPE_STRING':
    case 'TYPE_BYTES':
    case 'TYPE_MESSAGE':
      return _wtLen;

    case 'TYPE_FIXED32':
    case 'TYPE_SFIXED32':
    case 'TYPE_FLOAT':
      return _wtI32;

    default:
      throw ArgumentError('Unknown protobuf field type: $type');
  }
}

/// Encodes a message field using DELIMITED (group) wire format: a START_GROUP
/// tag (wire type 3), the submessage [body], then a matching END_GROUP tag
/// (wire type 4). This is the editions `message_encoding = DELIMITED`
/// representation (and the proto2 `group` encoding). Unlike length-prefixed
/// (wire type 2) the body is NOT length-prefixed — it is terminated by the
/// END_GROUP tag.
List<int> encodeGroupField(List<int> buffer, int fieldNumber, List<int> body) {
  encodeTag(buffer, fieldNumber, _wtSGroup);
  buffer.addAll(body);
  encodeTag(buffer, fieldNumber, _wtEGroup);
  return buffer;
}

/// Marshals a message ([message]) to protobuf binary bytes using [descriptor].
///
/// Iterates over each field descriptor, looks up the corresponding value in
/// [message] by name, and encodes it according to its type and label.
///
/// Returns the encoded protobuf bytes as a `List<int>`.
List<int> marshal(
  Map<String, Object?> message,
  List<Map<String, Object?>> descriptor,
) {
  final buffer = <int>[];

  for (final field in descriptor) {
    final name = field['name'] as String;
    final fieldNumber = field['number'] as int;
    final type = field['type'] as String;
    final label = field['label'] as String?;
    final features = field['features'] as Map<String, String>?;
    final value = message[name];

    // Skip null values — field not present in the message map.
    if (value == null) continue;

    // Map fields: descriptor carries keyType/valueType metadata. Accept any
    // `Map` — binary unmarshal yields native-typed keys (`Map<Object?,Object?>`
    // keyed by e.g. `int`), while the JSON codec yields string keys; both must
    // round-trip through here.
    if (label == 'LABEL_REPEATED' &&
        type == 'TYPE_MESSAGE' &&
        value is Map &&
        field['mapEntry'] == true) {
      final keyType = field['keyType'] as String? ?? 'TYPE_STRING';
      final valueType = field['valueType'] as String? ?? 'TYPE_STRING';
      // For `map<K, message>` the value sub-message's field descriptors live on
      // the map field itself (set by the descriptor bridge); thread them through
      // so message-typed values re-marshal instead of failing.
      final valueDescriptor =
          field['messageDescriptor'] as List<Map<String, Object?>>?;
      marshalMapField(
        buffer,
        fieldNumber,
        value,
        keyType,
        valueType,
        valueDescriptor: valueDescriptor,
      );
      continue;
    }

    // Repeated fields.
    if (label == 'LABEL_REPEATED') {
      final list = value as List<Object?>;
      if (list.isEmpty) continue;

      if (type == 'TYPE_MESSAGE') {
        // Repeated messages are never packed — each is a separate record.
        // DELIMITED (group) encoding wraps each in START_GROUP/END_GROUP;
        // otherwise each is a length-prefixed (LEN) field.
        final delimited = features != null && isDelimited(features);
        final msgDescriptor =
            field['messageDescriptor'] as List<Map<String, Object?>>?;
        for (final item in list) {
          if (item == null) continue;
          final subBytes = msgDescriptor != null
              ? marshal(item as Map<String, Object?>, msgDescriptor)
              : item as List<int>;
          if (delimited) {
            encodeGroupField(buffer, fieldNumber, subBytes);
          } else {
            // Force-emit each element, including an empty submessage:
            // encodeMessageField would drop a zero-length one and misalign the
            // array (e.g. a repeated wrapper element holding the value 0).
            encodeTag(buffer, fieldNumber, _wtLen);
            encodeBytes(buffer, subBytes);
          }
        }
      } else if (type == 'TYPE_STRING') {
        // Repeated strings are not packed — each is a separate LEN field, and
        // every element is emitted (even ""), so indices stay aligned.
        for (final item in list) {
          if (item == null) continue;
          encodeTag(buffer, fieldNumber, _wtLen);
          encodeBytes(buffer, utf8.encode(item as String));
        }
      } else if (type == 'TYPE_BYTES') {
        // Repeated bytes are not packed — each is a separate LEN field, every
        // element emitted (even empty).
        for (final item in list) {
          if (item == null) continue;
          encodeTag(buffer, fieldNumber, _wtLen);
          encodeBytes(buffer, item as List<int>);
        }
      } else if (features != null && isExpandedRepeated(features)) {
        // Expanded scalar repeated (proto2 / EXPANDED override): each element
        // is its own tag-value record rather than one packed blob. Every
        // element is written, including default values (no proto3 elision).
        for (final item in list) {
          if (item == null) continue;
          _writeScalarForced(buffer, fieldNumber, type, item);
        }
      } else {
        // Packed scalar repeated field (proto3 / editions default).
        marshalRepeated(buffer, fieldNumber, type, list);
      }
      continue;
    }

    // Singular field. With EXPLICIT/LEGACY_REQUIRED presence the value is
    // serialized even when it equals the type default (proto3/IMPLICIT elides).
    // A *set* oneof member is also always serialized (its presence on the wire
    // is what selects the oneof case) — value==null was already skipped above,
    // so a present member here is a set one. A DELIMITED message field is
    // emitted as a group (wire type 3/4).
    final msgDescriptor =
        field['messageDescriptor'] as List<Map<String, Object?>>?;
    marshalField(
      buffer,
      fieldNumber,
      type,
      value,
      explicitPresence:
          field['oneof'] != null ||
          (features != null && hasExplicitPresence(features)),
      delimited: features != null && isDelimited(features),
      messageDescriptor: msgDescriptor,
    );
  }

  // Re-emit any retained unknown fields (raw tag+value bytes captured by
  // unmarshal), preserving them across a binary round-trip.
  final unknown = message[unknownFieldsKey];
  if (unknown is List<int>) buffer.addAll(unknown);

  return buffer;
}

/// Marshals a single scalar field value and appends it to [buffer].
///
/// Applies proto3 default-value elision: values equal to the type's default
/// (0, 0.0, false, empty string, empty bytes) are not written unless
/// [repeated] is true (packed encoding handles its own elision).
///
/// For `TYPE_MESSAGE`, [value] must be either a pre-encoded `List<int>` or
/// will be treated as such.
///
/// Returns [buffer] with the field bytes appended.
List<int> marshalField(
  List<int> buffer,
  int fieldNumber,
  String type,
  Object? value, {
  bool repeated = false,
  bool explicitPresence = false,
  bool delimited = false,
  List<Map<String, Object?>>? messageDescriptor,
}) {
  if (value == null) return buffer;

  // Explicit / required presence: a present value is serialized even when it
  // equals the type default. The low-level encoders below bake in proto3
  // default elision, so route singular scalars through the forced writer.
  // (Message fields track presence separately — handled by the normal path.)
  if (explicitPresence && !repeated && type != 'TYPE_MESSAGE') {
    return _writeScalarForced(buffer, fieldNumber, type, value);
  }

  switch (type) {
    case 'TYPE_INT32':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeInt32Field(buffer, fieldNumber, v);
    case 'TYPE_INT64':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeInt64Field(buffer, fieldNumber, v);
    case 'TYPE_UINT32':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeUint32Field(buffer, fieldNumber, v);
    case 'TYPE_UINT64':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeUint64Field(buffer, fieldNumber, v);
    case 'TYPE_SINT32':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeSint32Field(buffer, fieldNumber, v);
    case 'TYPE_SINT64':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeSint64Field(buffer, fieldNumber, v);
    case 'TYPE_BOOL':
      final v = value as bool;
      if (!repeated && !v) return buffer;
      encodeBoolField(buffer, fieldNumber, v);
    case 'TYPE_ENUM':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeEnumField(buffer, fieldNumber, v);
    case 'TYPE_FIXED32':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeFixed32Field(buffer, fieldNumber, v);
    case 'TYPE_FIXED64':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeFixed64Field(buffer, fieldNumber, v);
    case 'TYPE_SFIXED32':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeSfixed32Field(buffer, fieldNumber, v);
    case 'TYPE_SFIXED64':
      final v = _toInt(value);
      if (!repeated && v == 0) return buffer;
      encodeSfixed64Field(buffer, fieldNumber, v);
    case 'TYPE_FLOAT':
      final v = _toDouble(value);
      if (!repeated && identical(v, 0.0)) return buffer;
      encodeFloatField(buffer, fieldNumber, v);
    case 'TYPE_DOUBLE':
      final v = _toDouble(value);
      if (!repeated && identical(v, 0.0)) return buffer;
      encodeDoubleField(buffer, fieldNumber, v);
    case 'TYPE_STRING':
      final v = value as String;
      if (!repeated && v.isEmpty) return buffer;
      encodeStringField(buffer, fieldNumber, v);
    case 'TYPE_BYTES':
      final v = value as List<int>;
      if (!repeated && v.isEmpty) return buffer;
      encodeBytesField(buffer, fieldNumber, v);
    case 'TYPE_MESSAGE':
      // Value is either pre-encoded bytes (List<int>) or a map that needs
      // marshaling via a messageDescriptor.
      final List<int> v;
      if (value is List<int>) {
        v = value;
      } else if (value is Map<String, Object?> && messageDescriptor != null) {
        v = marshal(value, messageDescriptor);
      } else if (value is Map<String, Object?>) {
        throw ArgumentError(
          'TYPE_MESSAGE field $fieldNumber received a Map but no '
          'messageDescriptor was provided for auto-marshaling',
        );
      } else {
        throw ArgumentError(
          'TYPE_MESSAGE field $fieldNumber expected List<int> or '
          'Map<String, Object?>, got ${value.runtimeType}',
        );
      }
      if (delimited) {
        // DELIMITED (group): a present submessage is always emitted, including
        // an empty one (START_GROUP/END_GROUP carries presence on its own).
        encodeGroupField(buffer, fieldNumber, v);
      } else {
        // A present singular message is emitted even when empty (tag + length 0)
        // — message fields carry presence, and an absent field was already
        // elided by the null check at the call site. Eliding a present empty
        // message would drop it on round-trip (ValidDataScalar.MESSAGE).
        encodeTag(buffer, fieldNumber, _wtLen);
        encodeBytes(buffer, v);
      }
    default:
      throw ArgumentError('Unknown protobuf field type: $type');
  }

  return buffer;
}

/// Calculates the encoded byte size of [message] without producing output.
///
/// This is used when encoding length-prefixed submessages: the parent needs
/// to know the byte length before writing the length prefix.
int sizeOfMessage(
  Map<String, Object?> message,
  List<Map<String, Object?>> descriptor,
) {
  // The simplest correct implementation: marshal to bytes and measure length.
  // This avoids duplicating all the size-calculation logic for every type.
  return marshal(message, descriptor).length;
}

/// Writes a scalar field WITHOUT proto3 default elision — for EXPLICIT/required
/// presence and EXPANDED repeated elements, where a present (possibly default)
/// value must still appear on the wire.
///
/// Non-default values go through the normal (eliding) encoder; a value the
/// encoder drops (the type default) is then written as tag + the wire-type's
/// zero payload. Not for `TYPE_MESSAGE` (message presence is handled
/// separately).
List<int> _writeScalarForced(
  List<int> buffer,
  int fieldNumber,
  String type,
  Object? value,
) {
  final before = buffer.length;
  marshalField(buffer, fieldNumber, type, value, repeated: true);
  if (buffer.length != before) return buffer; // non-default: encoder wrote it.
  final wt = wireTypeForFieldType(type);
  encodeTag(buffer, fieldNumber, wt);
  if (wt == _wtI32) {
    buffer.addAll(const [0, 0, 0, 0]);
  } else if (wt == _wtI64) {
    buffer.addAll(const [0, 0, 0, 0, 0, 0, 0, 0]);
  } else {
    // VARINT (0) and LEN (length 0) both encode as a single zero byte.
    buffer.add(0);
  }
  return buffer;
}

/// Marshals a repeated scalar field using packed encoding and appends it to
/// [buffer].
///
/// Packed encoding writes a single tag + length prefix, then concatenates all
/// the scalar values without individual tags.
///
/// For non-packable types (string, bytes, message) this is a no-op — those
/// are handled by the caller with individual field entries.
///
/// Returns [buffer] with the packed field bytes appended.
List<int> marshalRepeated(
  List<int> buffer,
  int fieldNumber,
  String type,
  List<Object?> values,
) {
  if (values.isEmpty) return buffer;

  switch (type) {
    // Varint-encoded packed types.
    case 'TYPE_INT32':
    case 'TYPE_INT64':
    case 'TYPE_UINT32':
    case 'TYPE_UINT64':
      final ints = values.map(_toInt).toList();
      encodePackedVarintsField(buffer, fieldNumber, ints);

    case 'TYPE_SINT32':
      final temp = <int>[];
      for (final v in values) {
        encodeVarint(temp, encodeZigZag32(_toInt(v)));
      }
      encodeTag(buffer, fieldNumber, _wtLen);
      encodeBytes(buffer, temp);

    case 'TYPE_SINT64':
      final temp = <int>[];
      for (final v in values) {
        encodeVarint(temp, encodeZigZag64(_toInt(v)));
      }
      encodeTag(buffer, fieldNumber, _wtLen);
      encodeBytes(buffer, temp);

    case 'TYPE_BOOL':
      final ints = values.map((v) => (v as bool) ? 1 : 0).toList();
      encodePackedVarintsField(buffer, fieldNumber, ints);

    case 'TYPE_ENUM':
      final ints = values.map(_toInt).toList();
      encodePackedVarintsField(buffer, fieldNumber, ints);

    // Fixed-width packed types.
    case 'TYPE_FIXED32':
    case 'TYPE_SFIXED32':
      final ints = values.map(_toInt).toList();
      encodePackedFixed32Field(buffer, fieldNumber, ints);

    case 'TYPE_FLOAT':
      final temp = <int>[];
      for (final v in values) {
        temp.addAll(_encodeFloatBytes(_toDouble(v)));
      }
      encodeTag(buffer, fieldNumber, _wtLen);
      encodeBytes(buffer, temp);

    case 'TYPE_FIXED64':
    case 'TYPE_SFIXED64':
      final ints = values.map(_toInt).toList();
      encodePackedFixed64Field(buffer, fieldNumber, ints);

    case 'TYPE_DOUBLE':
      final temp = <int>[];
      for (final v in values) {
        temp.addAll(_encodeDoubleBytes(_toDouble(v)));
      }
      encodeTag(buffer, fieldNumber, _wtLen);
      encodeBytes(buffer, temp);

    // Non-packable types — encode each element as a separate field.
    case 'TYPE_STRING':
      for (final v in values) {
        if (v == null) continue;
        encodeStringField(buffer, fieldNumber, v as String);
      }

    case 'TYPE_BYTES':
      for (final v in values) {
        if (v == null) continue;
        encodeBytesField(buffer, fieldNumber, v as List<int>);
      }

    case 'TYPE_MESSAGE':
      for (final v in values) {
        if (v == null) continue;
        encodeMessageField(buffer, fieldNumber, v as List<int>);
      }

    default:
      throw ArgumentError(
        'Unknown protobuf field type for packed encoding: $type',
      );
  }

  return buffer;
}

/// Marshals a map field as repeated key-value pair messages.
///
/// In protobuf, `map<K, V>` is encoded on the wire as:
/// ```
/// repeated MapEntry { K key = 1; V value = 2; }
/// ```
/// Each entry is a length-delimited submessage containing field 1 (key)
/// and field 2 (value).
///
/// [mapValue] is the Dart map to encode. Keys may be native-typed (as binary
/// unmarshal produces — `int`/`bool`/`String`) or string-typed (as the JSON
/// codec produces); [keyType] determines how each key is interpreted on the
/// wire (e.g. `TYPE_STRING`, `TYPE_INT32`, etc.) and [_coerceMapKey] accepts
/// either representation.
///
/// Returns [buffer] with the map entry fields appended.
List<int> marshalMapField(
  List<int> buffer,
  int fieldNumber,
  Map<Object?, Object?> mapValue,
  String keyType,
  String valueType, {
  List<Map<String, Object?>>? valueDescriptor,
}) {
  if (mapValue.isEmpty) return buffer;

  for (final entry in mapValue.entries) {
    final entryBuffer = <int>[];

    // Encode key as field 1.
    final key = _coerceMapKey(entry.key, keyType);
    marshalField(entryBuffer, 1, keyType, key, repeated: true);

    // Encode value as field 2 (a message value re-marshals via its descriptor).
    if (entry.value != null) {
      marshalField(
        entryBuffer,
        2,
        valueType,
        entry.value,
        repeated: true,
        messageDescriptor: valueDescriptor,
      );
    }

    // Write the entry as a length-delimited submessage. Emit it even when the
    // body is empty (both key and value elided to their type-default) — a
    // {default: default} entry must still round-trip, but encodeMessageField
    // would drop a zero-length submessage.
    encodeTag(buffer, fieldNumber, _wtLen);
    encodeBytes(buffer, entryBuffer);
  }

  return buffer;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Coerces a Dart value to [int].
///
/// Handles `int` passthrough and `num` truncation.
int _toInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ArgumentError('Cannot convert $value (${value.runtimeType}) to int');
}

/// Coerces a Dart value to [double].
///
/// Handles `double` passthrough and `num` conversion.
double _toDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  throw ArgumentError('Cannot convert $value (${value.runtimeType}) to double');
}

/// Coerces a map key into the appropriate Dart type for the given [keyType].
///
/// Protobuf map keys can be any integer type, bool, or string. Keys reach us
/// either already native-typed (binary unmarshal: `int`/`bool`/`String`) or as
/// strings (JSON codec, where object keys are always strings), so we accept
/// both and normalize to the wire type the encoder expects.
Object _coerceMapKey(Object? key, String keyType) {
  switch (keyType) {
    case 'TYPE_STRING':
      return key is String ? key : key.toString();
    case 'TYPE_INT32':
    case 'TYPE_INT64':
    case 'TYPE_UINT32':
    case 'TYPE_UINT64':
    case 'TYPE_SINT32':
    case 'TYPE_SINT64':
    case 'TYPE_FIXED32':
    case 'TYPE_FIXED64':
    case 'TYPE_SFIXED32':
    case 'TYPE_SFIXED64':
      if (key is int) return key;
      if (key is num) return key.toInt();
      return int.parse(key as String);
    case 'TYPE_BOOL':
      if (key is bool) return key;
      return key == 'true';
    default:
      // Fallback: return the key as-is (non-null).
      return key ?? '';
  }
}

/// Converts a [double] to IEEE 754 single-precision 4-byte little-endian bytes.
List<int> _encodeFloatBytes(double value) {
  final bd = ByteData(4);
  bd.setFloat32(0, value, Endian.little);
  return [bd.getUint8(0), bd.getUint8(1), bd.getUint8(2), bd.getUint8(3)];
}

/// Converts a [double] to IEEE 754 double-precision 8-byte little-endian bytes.
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
