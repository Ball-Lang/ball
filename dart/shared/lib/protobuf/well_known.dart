/// Helpers for working with protobuf well-known types as plain Dart maps.
///
/// Each well-known type (Struct, Value, Timestamp, Duration, Any) is
/// represented as `Map<String, Object?>` matching the proto3 JSON mapping.
/// These functions convert between that representation and idiomatic Dart
/// types, following the canonical JSON encoding rules from:
///   - https://protobuf.dev/reference/protobuf/google.protobuf/
///   - https://protobuf.dev/programming-guides/proto3/#json
library;

// ---------------------------------------------------------------------------
// google.protobuf.Struct ↔ Dart Map
// ---------------------------------------------------------------------------

/// Converts a `google.protobuf.Struct` JSON map to a plain Dart map.
///
/// A Struct has a single `"fields"` key whose value is a map of string keys
/// to `google.protobuf.Value` objects. This function recursively converts
/// each Value to its native Dart representation.
///
/// If [struct] already lacks a `"fields"` wrapper (i.e. it is already a
/// flat map of Values), it is treated as the fields map directly.
Map<String, Object?> structToMap(Map<String, Object?> struct) {
  final fields = struct['fields'];
  final Map<String, Object?> fieldMap;

  if (fields is Map<String, Object?>) {
    fieldMap = fields;
  } else {
    // Treat the entire map as the fields map (already unwrapped).
    fieldMap = struct;
  }

  final result = <String, Object?>{};
  for (final entry in fieldMap.entries) {
    if (entry.value is Map<String, Object?>) {
      result[entry.key] = valueToNative(entry.value as Map<String, Object?>);
    } else {
      result[entry.key] = entry.value;
    }
  }
  return result;
}

/// Converts a plain Dart map to a `google.protobuf.Struct` JSON map.
///
/// Wraps the entries in the canonical `{"fields": {...}}` envelope, converting
/// each value to a `google.protobuf.Value` via [nativeToValue].
Map<String, Object?> mapToStruct(Map<String, Object?> map) {
  final fields = <String, Object?>{};
  for (final entry in map.entries) {
    fields[entry.key] = nativeToValue(entry.value);
  }
  return {'fields': fields};
}

// ---------------------------------------------------------------------------
// google.protobuf.Value ↔ native Dart value
// ---------------------------------------------------------------------------

/// Converts a `google.protobuf.Value` JSON map to its native Dart equivalent.
///
/// A Value has exactly one of the following keys set (the `kind` oneof):
///   - `"nullValue"`   → `null`
///   - `"numberValue"` → `num`
///   - `"stringValue"` → `String`
///   - `"boolValue"`   → `bool`
///   - `"structValue"` → `Map<String, Object?>` (recursively via [structToMap])
///   - `"listValue"`   → `List<Object?>` (recursively converts each element)
///
/// Returns `null` for unrecognized or empty Value maps.
Object? valueToNative(Map<String, Object?> value) {
  if (value.containsKey('nullValue')) {
    return null;
  }
  if (value.containsKey('numberValue')) {
    return value['numberValue'];
  }
  if (value.containsKey('stringValue')) {
    return value['stringValue'];
  }
  if (value.containsKey('boolValue')) {
    return value['boolValue'];
  }
  if (value.containsKey('structValue')) {
    final sv = value['structValue'];
    if (sv is Map<String, Object?>) {
      return structToMap(sv);
    }
    return sv;
  }
  if (value.containsKey('listValue')) {
    final lv = value['listValue'];
    if (lv is Map<String, Object?>) {
      final values = lv['values'];
      if (values is List) {
        return values.map((e) {
          if (e is Map<String, Object?>) return valueToNative(e);
          return e;
        }).toList();
      }
    }
    if (lv is List) {
      return lv.map((e) {
        if (e is Map<String, Object?>) return valueToNative(e);
        return e;
      }).toList();
    }
    return lv;
  }
  return null;
}

/// Converts a native Dart value to a `google.protobuf.Value` JSON map.
///
/// Supported types:
///   - `null`                  → `{"nullValue": "NULL_VALUE"}`
///   - `num`                   → `{"numberValue": n}`
///   - `String`                → `{"stringValue": s}`
///   - `bool`                  → `{"boolValue": b}`
///   - `Map<String, Object?>`  → `{"structValue": mapToStruct(m)}`
///   - `List`                  → `{"listValue": {"values": [...]}}`
///
/// Throws [ArgumentError] for unsupported types.
Map<String, Object?> nativeToValue(Object? value) {
  if (value == null) {
    return {'nullValue': 'NULL_VALUE'};
  }
  if (value is num) {
    return {'numberValue': value};
  }
  if (value is String) {
    return {'stringValue': value};
  }
  if (value is bool) {
    return {'boolValue': value};
  }
  if (value is Map<String, Object?>) {
    return {'structValue': mapToStruct(value)};
  }
  if (value is List) {
    return {
      'listValue': {
        'values': value.map((e) => nativeToValue(e)).toList(),
      },
    };
  }
  throw ArgumentError(
    'Cannot convert ${value.runtimeType} to google.protobuf.Value',
  );
}

// ---------------------------------------------------------------------------
// google.protobuf.Timestamp ↔ RFC 3339 string
// ---------------------------------------------------------------------------

/// Converts a `google.protobuf.Timestamp` to an RFC 3339 string.
///
/// A Timestamp contains `"seconds"` (int64, seconds since Unix epoch) and
/// optional `"nanos"` (int32, sub-second nanoseconds in `[0, 999999999]`).
///
/// Output format: `"1972-01-01T10:00:20.021Z"` (trailing zeros in the
/// fractional part are trimmed; the fraction is omitted entirely when nanos
/// is zero).
String timestampToRfc3339(Map<String, Object?> timestamp) {
  final seconds = _toInt(timestamp['seconds'] ?? 0);
  final nanos = _toInt(timestamp['nanos'] ?? 0);

  final dt = DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  );

  final datePart = '${_pad4(dt.year)}-${_pad2(dt.month)}-${_pad2(dt.day)}';
  final timePart = '${_pad2(dt.hour)}:${_pad2(dt.minute)}:${_pad2(dt.second)}';

  if (nanos == 0) {
    return '${datePart}T${timePart}Z';
  }

  // Format nanos as 3, 6, or 9 digits depending on precision needed.
  final nanoStr = nanos.toString().padLeft(9, '0');
  // Trim trailing zeros but keep at least 3 digits for millis.
  String fractional = nanoStr;
  // Remove trailing zeros.
  while (fractional.length > 1 && fractional.endsWith('0')) {
    fractional = fractional.substring(0, fractional.length - 1);
  }

  return '${datePart}T$timePart.${fractional}Z';
}

/// Parses an RFC 3339 string into a `google.protobuf.Timestamp`.
///
/// Accepts strings like `"1972-01-01T10:00:20.021Z"` or without fractional
/// seconds like `"2000-01-01T00:00:00Z"`.
///
/// Returns `{"seconds": int, "nanos": int}`.
Map<String, Object?> rfc3339ToTimestamp(String rfc3339) {
  final dt = DateTime.parse(rfc3339);
  final seconds = dt.millisecondsSinceEpoch ~/ 1000;

  // Extract fractional seconds from the string to preserve full nanosecond
  // precision (DateTime only holds microseconds).
  int nanos = 0;
  final dotIndex = rfc3339.indexOf('.');
  if (dotIndex != -1) {
    // Find the end of the fractional part (before 'Z' or timezone offset).
    int endIndex = rfc3339.length;
    for (int i = dotIndex + 1; i < rfc3339.length; i++) {
      if (rfc3339[i] == 'Z' ||
          rfc3339[i] == 'z' ||
          rfc3339[i] == '+' ||
          rfc3339[i] == '-') {
        endIndex = i;
        break;
      }
    }
    final fracStr = rfc3339.substring(dotIndex + 1, endIndex).padRight(9, '0');
    nanos = int.parse(fracStr.substring(0, 9));
  }

  return {'seconds': seconds, 'nanos': nanos};
}

// ---------------------------------------------------------------------------
// google.protobuf.Duration ↔ string
// ---------------------------------------------------------------------------

/// Converts a `google.protobuf.Duration` to its canonical string form.
///
/// A Duration contains `"seconds"` (int64) and optional `"nanos"` (int32,
/// same sign as seconds or zero, absolute value in `[0, 999999999]`).
///
/// Output: `"1.000340012s"`, `"-0.500s"`, `"0s"`.
/// Negative durations have a leading `-` and both seconds and nanos share
/// the sign.
String durationToString(Map<String, Object?> duration) {
  final seconds = _toInt(duration['seconds'] ?? 0);
  final nanos = _toInt(duration['nanos'] ?? 0);

  if (nanos == 0) {
    return '${seconds}s';
  }

  // Determine sign: the canonical form has a single leading '-' when the
  // overall duration is negative.
  final negative = seconds < 0 || (seconds == 0 && nanos < 0);
  final absSeconds = seconds.abs();
  final absNanos = nanos.abs();

  final nanoStr = absNanos.toString().padLeft(9, '0');
  // Trim trailing zeros.
  String fractional = nanoStr;
  while (fractional.length > 1 && fractional.endsWith('0')) {
    fractional = fractional.substring(0, fractional.length - 1);
  }

  final sign = negative ? '-' : '';
  return '$sign$absSeconds.${fractional}s';
}

/// Parses a duration string (`"Xs"`, `"X.Ns"`) into a
/// `google.protobuf.Duration`.
///
/// Returns `{"seconds": int, "nanos": int}`.
///
/// Throws [FormatException] if the string does not end with `'s'`.
Map<String, Object?> stringToDuration(String durationStr) {
  if (!durationStr.endsWith('s')) {
    throw FormatException(
      'Duration string must end with "s": $durationStr',
    );
  }

  final body = durationStr.substring(0, durationStr.length - 1);
  final negative = body.startsWith('-');
  final abs = negative ? body.substring(1) : body;

  final dotIndex = abs.indexOf('.');
  int seconds;
  int nanos;

  if (dotIndex == -1) {
    seconds = int.parse(abs);
    nanos = 0;
  } else {
    seconds = int.parse(abs.substring(0, dotIndex));
    final fracStr = abs.substring(dotIndex + 1).padRight(9, '0');
    nanos = int.parse(fracStr.substring(0, 9));
  }

  if (negative) {
    seconds = -seconds;
    if (nanos != 0) nanos = -nanos;
  }

  return {'seconds': seconds, 'nanos': nanos};
}

// ---------------------------------------------------------------------------
// google.protobuf.Any — pack/unpack
// ---------------------------------------------------------------------------

/// Packs a message into a `google.protobuf.Any` JSON representation.
///
/// The canonical proto3 JSON encoding of Any uses `"@type"` to carry the
/// type URL and merges the message fields into the same object:
/// ```json
/// {"@type": "type.googleapis.com/my.Type", "field1": "value1"}
/// ```
///
/// [typeUrl] should be a fully-qualified type URL (e.g.
/// `"type.googleapis.com/google.protobuf.Duration"`).
/// [message] is the message fields as a JSON-compatible map.
Map<String, Object?> packAny(String typeUrl, Map<String, Object?> message) {
  return {'@type': typeUrl, ...message};
}

/// Unpacks a `google.protobuf.Any` JSON representation.
///
/// Extracts the `"@type"` field and returns the remaining fields as the
/// message body.
///
/// Returns `{"typeUrl": String, "message": Map<String, Object?>}`.
///
/// Throws [ArgumentError] if the `"@type"` field is missing.
Map<String, Object?> unpackAny(Map<String, Object?> any) {
  final typeUrl = any['@type'];
  if (typeUrl is! String) {
    throw ArgumentError('Any message missing "@type" field');
  }

  final message = Map<String, Object?>.from(any);
  message.remove('@type');

  return {'typeUrl': typeUrl, 'message': message};
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Coerces a value to [int], handling both `int` and `num`.
int _toInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.parse(value);
  throw ArgumentError('Cannot convert $value (${value.runtimeType}) to int');
}

/// Left-pads an integer to 2 digits with a leading zero.
String _pad2(int n) => n.toString().padLeft(2, '0');

/// Left-pads an integer to 4 digits with leading zeros.
String _pad4(int n) => n.toString().padLeft(4, '0');
