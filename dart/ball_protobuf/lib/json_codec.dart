/// Descriptor-driven Proto3 JSON marshaling and unmarshaling.
///
/// Converts between Dart `Map<String, Object?>` message representations and
/// Proto3 JSON format, using the same field descriptor lists as the binary
/// `marshal.dart` / `unmarshal.dart` codecs.
///
/// Field descriptor format (same as binary marshal/unmarshal):
/// ```dart
/// {
///   'name'     : String,       // snake_case field name
///   'number'   : int,          // protobuf field number
///   'type'     : String,       // protobuf type: 'TYPE_INT32', 'TYPE_STRING', etc.
///   'label'    : String?,      // 'LABEL_REPEATED' for repeated fields
///   'typeName' : String?,      // fully-qualified enum/message type name
///   'mapEntry' : bool?,        // true if this is a map<K,V> field
///   'keyType'  : String?,      // map key type
///   'valueType': String?,      // map value type
///   'messageDescriptor': List<Map<String, Object?>>?,  // sub-message descriptor
///   'enumValues': Map<int, String>?,  // enum ordinal -> name mapping
/// }
/// ```
///
/// Proto3 JSON rules implemented:
///   - Field names: snake_case -> lowerCamelCase in output; accept both on input.
///   - int64/uint64: encoded as JSON strings (too large for JS `Number`).
///   - bytes: encoded as base64 strings.
///   - float/double: NaN -> "NaN", Infinity -> "Infinity", -Infinity -> "-Infinity".
///   - enum: encoded as string name (first enum value name for ordinal 0).
///   - bool: true/false.
///   - message: nested JSON object.
///   - repeated: JSON array.
///   - map: JSON object (keys always strings in JSON).
///   - Default values are omitted from output.
///
/// References:
///   - https://protobuf.dev/programming-guides/json/
///   - https://protobuf.dev/programming-guides/proto3/#json
library;

import 'dart:convert';

import 'editions.dart';

// ---------------------------------------------------------------------------
// UTF-8 validation (editions utf8_validation = VERIFY)
// ---------------------------------------------------------------------------

/// Whether [s] contains an unpaired UTF-16 surrogate (i.e. cannot be encoded as
/// well-formed UTF-8). Dart strings are UTF-16 code-unit sequences; a lone or
/// mis-ordered surrogate has no valid Unicode scalar value.
bool _hasUnpairedSurrogate(String s) {
  for (int i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      // High surrogate — must be immediately followed by a low surrogate.
      if (i + 1 >= s.length) return true;
      final next = s.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++; // consume the valid pair
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return true; // lone low surrogate
    }
  }
  return false;
}

/// Throws [FormatException] when [features] require UTF-8 validation
/// (`utf8_validation = VERIFY`) and [s] is not well-formed UTF-8. A no-op when
/// validation is not required or [features] is absent (proto2 / NONE).
void _verifyUtf8IfRequired(String s, Map<String, String>? features) {
  if (features != null &&
      requiresUtf8Validation(features) &&
      _hasUnpairedSurrogate(s)) {
    throw FormatException(
      'Invalid UTF-8 string (unpaired surrogate) under utf8_validation=VERIFY',
    );
  }
}

// ---------------------------------------------------------------------------
// Name conversion
// ---------------------------------------------------------------------------

/// Converts a snake_case field name to lowerCamelCase.
///
/// Splits on underscores and capitalizes the first letter of each segment
/// after the first. Leading/trailing underscores are preserved as empty
/// segments (dropped by split), matching protobuf's canonical JSON name
/// generation.
///
/// Examples:
///   "foo_bar"     -> "fooBar"
///   "foo_bar_baz" -> "fooBarBaz"
///   "foo"         -> "foo"
///   ""            -> ""
String toCamelCase(String snakeCase) {
  if (snakeCase.isEmpty) return snakeCase;
  // Preserve leading underscores.
  int leadingUnderscores = 0;
  while (leadingUnderscores < snakeCase.length &&
      snakeCase[leadingUnderscores] == '_') {
    leadingUnderscores++;
  }
  final prefix = snakeCase.substring(0, leadingUnderscores);
  final rest = snakeCase.substring(leadingUnderscores);
  if (rest.isEmpty) return snakeCase;
  final parts = rest.split('_');
  final buffer = StringBuffer(prefix);
  buffer.write(parts[0]);
  for (int i = 1; i < parts.length; i++) {
    final part = parts[i];
    if (part.isEmpty) continue;
    buffer.write(part[0].toUpperCase());
    if (part.length > 1) {
      buffer.write(part.substring(1));
    }
  }
  return buffer.toString();
}

/// Converts a lowerCamelCase name to snake_case.
///
/// Inserts an underscore before each uppercase letter and lowercases the
/// result.
///
/// Examples:
///   "fooBar"    -> "foo_bar"
///   "fooBarBaz" -> "foo_bar_baz"
///   "foo"       -> "foo"
///   ""          -> ""
String toSnakeCase(String camelCase) {
  if (camelCase.isEmpty) return camelCase;
  final buffer = StringBuffer();
  for (int i = 0; i < camelCase.length; i++) {
    final ch = camelCase[i];
    if (ch == ch.toUpperCase() && ch != ch.toLowerCase()) {
      // Uppercase letter — insert underscore separator.
      if (buffer.isNotEmpty) {
        buffer.write('_');
      }
      buffer.write(ch.toLowerCase());
    } else {
      buffer.write(ch);
    }
  }
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// Default value detection
// ---------------------------------------------------------------------------

/// Returns `true` if [value] is the proto3 default for the given field [type].
///
/// Proto3 defaults:
///   - Numeric types (int32, int64, uint32, uint64, sint32, sint64,
///     fixed32, fixed64, sfixed32, sfixed64, float, double): 0 or 0.0
///   - bool: false
///   - string: ""
///   - bytes: empty list
///   - enum: 0
///   - message: null
///   - repeated / map: empty list or empty map
bool isDefaultValue(Object? value, String type) {
  if (value == null) return true;
  switch (type) {
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
      return value is num && value == 0;
    case 'TYPE_FLOAT':
    case 'TYPE_DOUBLE':
      return value is num && value == 0.0;
    case 'TYPE_BOOL':
      return value is bool && !value;
    case 'TYPE_STRING':
      return value is String && value.isEmpty;
    case 'TYPE_BYTES':
      return value is List && value.isEmpty;
    case 'TYPE_ENUM':
      return value is int && value == 0;
    case 'TYPE_MESSAGE':
      return false; // null is already handled above; a non-null message is never default.
    default:
      return false;
  }
}

// ---------------------------------------------------------------------------
// Ensure defaults
// ---------------------------------------------------------------------------

/// Returns a copy of [message] with missing fields filled in with proto3
/// default values according to [descriptor].
///
/// Fields already present in the map are left unchanged. Fields absent from
/// the map are inserted with their type-appropriate default: 0, 0.0, false,
/// "", empty list, or null.
Map<String, Object?> ensureDefaults(
  Map<String, Object?> message,
  List<Map<String, Object?>> descriptor,
) {
  final result = Map<String, Object?>.from(message);
  for (final field in descriptor) {
    final name = field['name'] as String;
    if (result.containsKey(name)) continue;

    final type = field['type'] as String;
    final label = field['label'] as String?;
    final isMap = field['mapEntry'] == true;

    if (isMap) {
      result[name] = <String, Object?>{};
    } else if (label == 'LABEL_REPEATED') {
      result[name] = <Object?>[];
    } else {
      result[name] = _defaultForType(type);
    }
  }
  return result;
}

/// Returns the proto3 default value for a scalar/message [type].
Object? _defaultForType(String type) {
  switch (type) {
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
    case 'TYPE_ENUM':
      return 0;
    case 'TYPE_FLOAT':
    case 'TYPE_DOUBLE':
      return 0.0;
    case 'TYPE_BOOL':
      return false;
    case 'TYPE_STRING':
      return '';
    case 'TYPE_BYTES':
      return <int>[];
    case 'TYPE_MESSAGE':
      return null;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Single-field value conversion
// ---------------------------------------------------------------------------

/// Converts a single protobuf field [value] to its Proto3 JSON representation.
///
/// Type-specific conversions:
///   - `TYPE_INT64`, `TYPE_UINT64`, `TYPE_SINT64`, `TYPE_SFIXED64`,
///     `TYPE_FIXED64`: encoded as JSON string (too large for JS number).
///   - `TYPE_BYTES`: encoded as base64 string.
///   - `TYPE_FLOAT`, `TYPE_DOUBLE`: NaN/Infinity/-Infinity as string literals.
///   - `TYPE_ENUM`: encoded as string name using the [enumValues] map. Falls
///     back to the integer if no name mapping is available.
///   - `TYPE_MESSAGE`: recursively marshaled using [messageDescriptor].
///   - All other scalar types pass through unchanged.
///
/// [enumValues] is an optional `Map<int, String>` mapping enum ordinals to
/// their Proto3 names. [messageDescriptor] is the nested field descriptor
/// list for `TYPE_MESSAGE` fields.
Object? fieldToJson(
  Object? value,
  String type, {
  Map<int, String>? enumValues,
  List<Map<String, Object?>>? messageDescriptor,
  Map<String, String>? features,
}) {
  if (value == null) return null;

  switch (type) {
    // Signed 64-bit integers: encode as a string per the Proto3 JSON spec.
    case 'TYPE_INT64':
    case 'TYPE_SINT64':
    case 'TYPE_SFIXED64':
      return value.toString();

    // Unsigned 64-bit: a Dart int holding a value >= 2^63 is stored as a
    // negative bit pattern, so render it as the unsigned decimal (string).
    case 'TYPE_UINT64':
    case 'TYPE_FIXED64':
      if (value is int && value < 0) {
        return (BigInt.from(value) + (BigInt.one << 64)).toString();
      }
      return value.toString();

    // bytes: base64 encode.
    case 'TYPE_BYTES':
      if (value is List<int>) {
        return base64.encode(value);
      }
      return value;

    // float / double: handle special IEEE 754 values.
    case 'TYPE_FLOAT':
    case 'TYPE_DOUBLE':
      if (value is double) {
        if (value.isNaN) return 'NaN';
        if (value.isInfinite) {
          return value.isNegative ? '-Infinity' : 'Infinity';
        }
      }
      return value;

    // enum: encode as string name.
    case 'TYPE_ENUM':
      if (enumValues != null && value is int) {
        return enumValues[value] ?? value;
      }
      return value;

    // message: recursive marshal.
    case 'TYPE_MESSAGE':
      if (messageDescriptor != null && value is Map<String, Object?>) {
        return _marshalToMap(value, messageDescriptor);
      }
      return value;

    // string: pass through, optionally verifying UTF-8 (utf8_validation=VERIFY).
    case 'TYPE_STRING':
      if (value is String) {
        _verifyUtf8IfRequired(value, features);
      }
      return value;

    // All other scalar types (int32, uint32, sint32, bool,
    // fixed32, sfixed32) pass through directly.
    default:
      return value;
  }
}

/// Converts a Proto3 JSON value back to its protobuf field representation.
///
/// Type-specific conversions:
///   - `TYPE_INT64`, `TYPE_UINT64`, `TYPE_SINT64`, `TYPE_SFIXED64`,
///     `TYPE_FIXED64`: string -> int.
///   - `TYPE_BYTES`: base64 string -> `List<int>`.
///   - `TYPE_FLOAT`, `TYPE_DOUBLE`: "NaN"/"Infinity"/"-Infinity" -> double.
///   - `TYPE_ENUM`: string name -> ordinal using the reverse [enumValues] map.
///   - `TYPE_MESSAGE`: recursively unmarshaled using [messageDescriptor].
///   - `TYPE_INT32`, `TYPE_UINT32`, etc.: numeric coercion from JSON number.
///   - `TYPE_BOOL`: passed through.
///   - `TYPE_STRING`: passed through.
///
/// [enumValues] maps ordinal -> name; this function reverses it to look up
/// by name. [messageDescriptor] is the nested field descriptor list for
/// `TYPE_MESSAGE` fields.
Object? fieldFromJson(
  Object? jsonValue,
  String type, {
  Map<int, String>? enumValues,
  List<Map<String, Object?>>? messageDescriptor,
  Map<String, String>? features,
}) {
  if (jsonValue == null) return null;

  switch (type) {
    // 64-bit integers: a JSON string or number (proto3 JSON encodes these as
    // strings, but accepts numbers too; exponential and quoted forms allowed).
    case 'TYPE_INT64':
    case 'TYPE_UINT64':
    case 'TYPE_SINT64':
    case 'TYPE_SFIXED64':
    case 'TYPE_FIXED64':
      return _parseJsonInt(jsonValue);

    // bytes: base64 string -> List<int>.
    case 'TYPE_BYTES':
      if (jsonValue is String) {
        return base64.decode(jsonValue);
      }
      return jsonValue;

    // float / double: handle special string literals.
    case 'TYPE_FLOAT':
    case 'TYPE_DOUBLE':
      if (jsonValue is String) {
        switch (jsonValue) {
          case 'NaN':
            return double.nan;
          case 'Infinity':
            return double.infinity;
          case '-Infinity':
            return double.negativeInfinity;
          default:
            return double.parse(jsonValue);
        }
      }
      if (jsonValue is int) {
        return jsonValue.toDouble();
      }
      return jsonValue;

    // enum: string name -> ordinal.
    case 'TYPE_ENUM':
      if (jsonValue is String && enumValues != null) {
        // Reverse lookup: find the ordinal for this name.
        for (final entry in enumValues.entries) {
          if (entry.value == jsonValue) {
            return entry.key;
          }
        }
        // If the string is a numeric literal, parse it.
        final numeric = int.tryParse(jsonValue);
        if (numeric != null) return numeric;
        // Unknown enum name. Proto3 JSON (json_format = ALLOW, the editions
        // default) requires a known name or a numeric literal — reject. Under
        // LEGACY_BEST_EFFORT (proto2) or when features are absent, tolerate it
        // by passing the raw string through (legacy best-effort behavior).
        if (features != null && jsonFormatIsAllow(features)) {
          throw FormatException(
            'Unknown enum value "$jsonValue" (json_format=ALLOW requires a '
            'known name or numeric literal)',
          );
        }
        return jsonValue;
      }
      if (jsonValue is num) {
        return jsonValue.toInt();
      }
      return jsonValue;

    // message: recursive unmarshal.
    case 'TYPE_MESSAGE':
      if (messageDescriptor != null && jsonValue is Map) {
        final stringMap = <String, Object?>{};
        for (final entry in jsonValue.entries) {
          stringMap[entry.key.toString()] = entry.value;
        }
        return _unmarshalFromMap(stringMap, messageDescriptor);
      }
      return jsonValue;

    // Signed 32-bit integers: range-checked.
    case 'TYPE_INT32':
    case 'TYPE_SINT32':
    case 'TYPE_SFIXED32':
      final n = _parseJsonInt(jsonValue);
      if (n < -2147483648 || n > 2147483647) {
        throw FormatException('int32 field value out of range: $n');
      }
      return n;

    // Unsigned 32-bit integers: range-checked.
    case 'TYPE_UINT32':
    case 'TYPE_FIXED32':
      final n = _parseJsonInt(jsonValue);
      if (n < 0 || n > 4294967295) {
        throw FormatException('uint32 field value out of range: $n');
      }
      return n;

    case 'TYPE_BOOL':
      if (jsonValue is bool) return jsonValue;
      if (jsonValue is String) return jsonValue == 'true';
      return jsonValue;

    case 'TYPE_STRING':
      if (jsonValue is! String) {
        throw FormatException(
          'Expected a JSON string, got ${jsonValue.runtimeType}',
        );
      }
      _verifyUtf8IfRequired(jsonValue, features);
      return jsonValue;

    default:
      return jsonValue;
  }
}

/// Parses a proto3-JSON integer scalar [v] into a Dart `int`.
///
/// Accepts a JSON number or a quoted string, in plain or exponential form
/// (`"1E5"`), and unsigned 64-bit values up to 2^64-1 (folded into the signed
/// 64-bit bit pattern). Rejects bools and non-integral numbers with a
/// [FormatException] so malformed JSON becomes a parse error.
int _parseJsonInt(Object? v) {
  if (v is bool) {
    throw FormatException('Expected an integer JSON value, got a bool');
  }
  if (v is int) return v;
  if (v is double) {
    if (v.isFinite && v == v.truncateToDouble()) return v.toInt();
    throw FormatException('Non-integral JSON number for an integer field: $v');
  }
  if (v is String) {
    final direct = int.tryParse(v);
    if (direct != null) return direct;
    // Unsigned 64-bit values above 2^63 overflow a signed int; fold the bit
    // pattern (e.g. "18446744073709551615" -> -1).
    final big = BigInt.tryParse(v);
    if (big != null && big >= BigInt.zero && big < (BigInt.one << 64)) {
      return big.toSigned(64).toInt();
    }
    // Exponential / decimal forms, accepted only when integral.
    final d = double.tryParse(v);
    if (d != null && d.isFinite && d == d.truncateToDouble()) return d.toInt();
    throw FormatException('Invalid integer JSON value: "$v"');
  }
  throw FormatException('Expected an integer JSON value, got ${v.runtimeType}');
}

// ---------------------------------------------------------------------------
// Message-level marshal / unmarshal
// ---------------------------------------------------------------------------

/// Marshals a message to a Proto3 JSON string.
///
/// Converts the [message] map to Proto3 JSON using [descriptor] for field
/// type information. Field names are converted from snake_case to
/// lowerCamelCase. Default values are omitted per Proto3 convention.
///
/// Returns a compact JSON string.
String marshalJson(
  Map<String, Object?> message,
  List<Map<String, Object?>> descriptor,
) {
  final jsonMap = _marshalToMap(message, descriptor);
  return jsonEncode(jsonMap);
}

/// Unmarshals a Proto3 JSON string into a message map.
///
/// Accepts both lowerCamelCase and snake_case field names in the input JSON.
/// Fields are mapped back to their snake_case names in the output map.
///
/// Returns a `Map<String, Object?>` with field values decoded from JSON.
Map<String, Object?> unmarshalJson(
  String jsonString,
  List<Map<String, Object?>> descriptor,
) {
  final jsonMap = jsonDecode(jsonString);
  if (jsonMap is! Map) {
    throw FormatException(
      'Expected a JSON object at top level, got ${jsonMap.runtimeType}',
    );
  }
  final stringMap = <String, Object?>{};
  for (final entry in jsonMap.entries) {
    stringMap[entry.key.toString()] = entry.value;
  }
  return _unmarshalFromMap(stringMap, descriptor);
}

// ---------------------------------------------------------------------------
// Internal marshal helpers
// ---------------------------------------------------------------------------

/// Converts a message map to a JSON-compatible `Map<String, Object?>`.
///
/// This is the core recursive worker for [marshalJson]. It converts field
/// names to camelCase, omits defaults, and recursively converts nested
/// messages, repeated fields, and map fields.
Map<String, Object?> _marshalToMap(
  Map<String, Object?> message,
  List<Map<String, Object?>> descriptor,
) {
  final result = <String, Object?>{};

  for (final field in descriptor) {
    final name = field['name'] as String;
    final type = field['type'] as String;
    final label = field['label'] as String?;
    final value = message[name];
    final isMap = field['mapEntry'] == true;
    final features = field['features'] as Map<String, String>?;
    final camelName = toCamelCase(name);

    if (isMap) {
      // Map field: encode as JSON object.
      if (value == null || (value is Map && value.isEmpty)) continue;
      final mapValue = value as Map;
      final valueType = field['valueType'] as String? ?? 'TYPE_STRING';
      final msgDesc = field['messageDescriptor'] as List<Map<String, Object?>>?;
      final enumVals = field['enumValues'] as Map<int, String>?;
      final jsonMap = <String, Object?>{};
      for (final entry in mapValue.entries) {
        final keyStr = entry.key.toString();
        jsonMap[keyStr] = fieldToJson(
          entry.value,
          valueType,
          enumValues: enumVals,
          messageDescriptor: msgDesc,
          features: features,
        );
      }
      result[camelName] = jsonMap;
    } else if (label == 'LABEL_REPEATED') {
      // Repeated field: encode as JSON array.
      if (value == null || (value is List && value.isEmpty)) continue;
      final list = value as List;
      final msgDesc = field['messageDescriptor'] as List<Map<String, Object?>>?;
      final enumVals = field['enumValues'] as Map<int, String>?;
      result[camelName] = [
        for (final item in list)
          fieldToJson(
            item,
            type,
            enumValues: enumVals,
            messageDescriptor: msgDesc,
            features: features,
          ),
      ];
    } else {
      // Singular field. With EXPLICIT/LEGACY_REQUIRED presence a present value
      // is emitted even when it equals the type default; a present-but-null
      // (unset) field is omitted. With implicit (proto3) presence — or no
      // resolved features — defaults are omitted as before (regression
      // firewall).
      final explicitPresence =
          features != null && hasExplicitPresence(features);
      if (explicitPresence) {
        if (value == null) continue;
      } else {
        if (isDefaultValue(value, type)) continue;
      }
      final msgDesc = field['messageDescriptor'] as List<Map<String, Object?>>?;
      final enumVals = field['enumValues'] as Map<int, String>?;
      result[camelName] = fieldToJson(
        value,
        type,
        enumValues: enumVals,
        messageDescriptor: msgDesc,
        features: features,
      );
    }
  }

  return result;
}

// ---------------------------------------------------------------------------
// Internal unmarshal helpers
// ---------------------------------------------------------------------------

/// Builds a lookup from both camelCase and snake_case names to the field
/// descriptor, so that either form is accepted during parsing.
Map<String, Map<String, Object?>> _buildFieldLookup(
  List<Map<String, Object?>> descriptor,
) {
  final lookup = <String, Map<String, Object?>>{};
  for (final field in descriptor) {
    final name = field['name'] as String;
    lookup[name] = field; // snake_case
    lookup[toCamelCase(name)] = field; // lowerCamelCase
  }
  return lookup;
}

/// Converts a JSON map to a message map using [descriptor].
///
/// This is the core recursive worker for [unmarshalJson]. It accepts both
/// camelCase and snake_case field names, converts values from JSON
/// representation to protobuf field values, and normalizes output keys to
/// snake_case.
Map<String, Object?> _unmarshalFromMap(
  Map<String, Object?> jsonMap,
  List<Map<String, Object?>> descriptor,
) {
  final lookup = _buildFieldLookup(descriptor);
  final result = <String, Object?>{};

  for (final entry in jsonMap.entries) {
    final jsonKey = entry.key;
    final jsonValue = entry.value;
    final field = lookup[jsonKey];

    if (field == null) {
      // Unknown field — skip (Proto3 JSON parsers should ignore unknown fields).
      continue;
    }

    final name = field['name'] as String;
    final type = field['type'] as String;
    final label = field['label'] as String?;
    final isMap = field['mapEntry'] == true;
    final msgDesc = field['messageDescriptor'] as List<Map<String, Object?>>?;
    final enumVals = field['enumValues'] as Map<int, String>?;
    final features = field['features'] as Map<String, String>?;

    if (isMap) {
      // Map field: JSON object -> Dart map.
      if (jsonValue is Map) {
        final valueType = field['valueType'] as String? ?? 'TYPE_STRING';
        final dartMap = <String, Object?>{};
        for (final mapEntry in jsonValue.entries) {
          final keyStr = mapEntry.key.toString();
          dartMap[keyStr] = fieldFromJson(
            mapEntry.value,
            valueType,
            enumValues: enumVals,
            messageDescriptor: msgDesc,
            features: features,
          );
        }
        result[name] = dartMap;
      } else {
        result[name] = jsonValue;
      }
    } else if (label == 'LABEL_REPEATED') {
      // Repeated field: JSON array -> Dart list.
      if (jsonValue is List) {
        result[name] = [
          for (final item in jsonValue)
            fieldFromJson(
              item,
              type,
              enumValues: enumVals,
              messageDescriptor: msgDesc,
              features: features,
            ),
        ];
      } else if (jsonValue != null) {
        throw FormatException(
          'Expected a JSON array for repeated field "$name", '
          'got ${jsonValue.runtimeType}',
        );
      }
      // A JSON `null` for a repeated field means the default (empty) — unset.
    } else {
      // Singular field.
      result[name] = fieldFromJson(
        jsonValue,
        type,
        enumValues: enumVals,
        messageDescriptor: msgDesc,
        features: features,
      );
    }
  }

  return result;
}
