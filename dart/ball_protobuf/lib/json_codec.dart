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
import 'marshal.dart';
import 'unmarshal.dart';
import 'well_known.dart';

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
// ---------------------------------------------------------------------------
// Well-Known Types — proto3 JSON mapping
//
// WKTs are normal messages on the wire (decoded generically into a snake_case
// field map), but get a special JSON form. Dispatch is JSON-only and keys on
// the field's message type name. google.protobuf.Any is handled separately
// (it needs a type registry to resolve the embedded message).
// ---------------------------------------------------------------------------

/// Wrapper message FQN -> the protobuf type of its single `value` field.
const Map<String, String> _wktWrappers = {
  'google.protobuf.DoubleValue': 'TYPE_DOUBLE',
  'google.protobuf.FloatValue': 'TYPE_FLOAT',
  'google.protobuf.Int64Value': 'TYPE_INT64',
  'google.protobuf.UInt64Value': 'TYPE_UINT64',
  'google.protobuf.Int32Value': 'TYPE_INT32',
  'google.protobuf.UInt32Value': 'TYPE_UINT32',
  'google.protobuf.BoolValue': 'TYPE_BOOL',
  'google.protobuf.StringValue': 'TYPE_STRING',
  'google.protobuf.BytesValue': 'TYPE_BYTES',
};

const Set<String> _wktStructural = {
  'google.protobuf.Timestamp',
  'google.protobuf.Duration',
  'google.protobuf.FieldMask',
  'google.protobuf.Struct',
  'google.protobuf.Value',
  'google.protobuf.ListValue',
};

/// Whether [typeName] is a well-known type with a dedicated proto3-JSON form.
/// (google.protobuf.Any is excluded — it requires a type registry.)
bool isWellKnownJsonType(String typeName) =>
    _wktWrappers.containsKey(typeName) || _wktStructural.contains(typeName);

/// Converts a decoded WKT message [value] (snake_case proto field names) to its
/// proto3-JSON representation. [resolver] is the per-call Any resolver (unused
/// by the structural WKTs, threaded only for signature uniformity).
Object? wktToJson(
  String typeName,
  Object? value,
  Map<String, String>? features, [
  AnyTypeResolver? resolver,
]) {
  final wrapped = _wktWrappers[typeName];
  if (wrapped != null) {
    final v = (value is Map) ? value['value'] : null;
    return fieldToJson(v ?? _scalarZero(wrapped), wrapped, features: features);
  }
  switch (typeName) {
    case 'google.protobuf.Timestamp':
      final m = _asWktMap(value);
      _checkTimestampRange(m);
      return timestampToRfc3339(m);
    case 'google.protobuf.Duration':
      final m = _asWktMap(value);
      _checkDurationRange(m);
      return durationToString(m);
    case 'google.protobuf.FieldMask':
      return _fieldMaskToJson(_asWktMap(value));
    case 'google.protobuf.Struct':
      return _structMsgToJson(_asWktMap(value));
    case 'google.protobuf.Value':
      return _valueMsgToJson(_asWktMap(value));
    case 'google.protobuf.ListValue':
      return _listValueMsgToJson(_asWktMap(value));
  }
  return value;
}

/// Converts proto3-JSON [json] into a decoded WKT message map (snake_case).
/// [resolver] is the per-call Any resolver (unused by the structural WKTs,
/// threaded only for signature uniformity).
Object? wktFromJson(
  String typeName,
  Object? json,
  Map<String, String>? features, [
  AnyTypeResolver? resolver,
]) {
  final wrapped = _wktWrappers[typeName];
  if (wrapped != null) {
    if (json == null) return <String, Object?>{};
    return {'value': fieldFromJson(json, wrapped, features: features)};
  }
  switch (typeName) {
    case 'google.protobuf.Timestamp':
      if (json is! String) {
        throw FormatException('Timestamp must be a JSON string');
      }
      final ts = rfc3339ToTimestamp(json);
      _checkTimestampRange(_asWktMap(ts));
      return ts;
    case 'google.protobuf.Duration':
      if (json is! String) {
        throw FormatException('Duration must be a JSON string');
      }
      final m = stringToDuration(json);
      _checkDurationRange(m);
      return m;
    case 'google.protobuf.FieldMask':
      if (json is! String) {
        throw FormatException('FieldMask must be a JSON string');
      }
      return _fieldMaskFromJson(json);
    case 'google.protobuf.Struct':
      return _structMsgFromJson(json);
    case 'google.protobuf.Value':
      return _valueMsgFromJson(json);
    case 'google.protobuf.ListValue':
      return _listValueMsgFromJson(json);
  }
  return json;
}

Map<String, Object?> _asWktMap(Object? v) =>
    v is Map<String, Object?> ? v : const <String, Object?>{};

int _wktInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

/// The JSON-side zero for a wrapped scalar type (used for an empty wrapper).
Object? _scalarZero(String type) {
  switch (type) {
    case 'TYPE_BOOL':
      return false;
    case 'TYPE_STRING':
      return '';
    case 'TYPE_BYTES':
      return <int>[];
    case 'TYPE_FLOAT':
    case 'TYPE_DOUBLE':
      return 0.0;
    default:
      return 0;
  }
}

// Timestamp/Duration range validation (a serialize/parse error on overflow).
void _checkTimestampRange(Map<String, Object?> m) {
  final s = _wktInt(m['seconds']);
  final n = _wktInt(m['nanos']);
  if (s < -62135596800 || s > 253402300799) {
    throw FormatException('Timestamp seconds out of range: $s');
  }
  if (n < 0 || n > 999999999) {
    throw FormatException('Timestamp nanos out of range: $n');
  }
}

void _checkDurationRange(Map<String, Object?> m) {
  final s = _wktInt(m['seconds']);
  final n = _wktInt(m['nanos']);
  if (s < -315576000000 || s > 315576000000) {
    throw FormatException('Duration seconds out of range: $s');
  }
  if (n < -999999999 || n > 999999999) {
    throw FormatException('Duration nanos out of range: $n');
  }
  if (s != 0 && n != 0 && (s < 0) != (n < 0)) {
    throw FormatException('Duration seconds and nanos must have the same sign');
  }
}

// FieldMask: comma-joined camelCase paths <-> {paths: [snake_case]}.
String _fieldMaskToJson(Map<String, Object?> v) {
  final paths = v['paths'];
  if (paths is! List) return '';
  return paths
      .map((p) => (p as String).split('.').map(toCamelCase).join('.'))
      .join(',');
}

Map<String, Object?> _fieldMaskFromJson(String json) {
  if (json.isEmpty) return {'paths': <String>[]};
  final paths = json
      .split(',')
      .map((seg) => seg.split('.').map(toSnakeCase).join('.'))
      .toList();
  return {'paths': paths};
}

// Struct / Value / ListValue operate on the snake_case message representation
// (the field names protobuf decode produces), NOT the camelCase JSON form.
Object? _valueMsgToJson(Map<String, Object?> v) {
  if (v.containsKey('null_value')) return null;
  if (v.containsKey('number_value')) return v['number_value'];
  if (v.containsKey('string_value')) return v['string_value'];
  if (v.containsKey('bool_value')) return v['bool_value'];
  if (v.containsKey('struct_value')) {
    return _structMsgToJson(_asWktMap(v['struct_value']));
  }
  if (v.containsKey('list_value')) {
    return _listValueMsgToJson(_asWktMap(v['list_value']));
  }
  return null; // an empty Value is null
}

Map<String, Object?> _structMsgToJson(Map<String, Object?> s) {
  final fields = s['fields'];
  final out = <String, Object?>{};
  if (fields is Map) {
    for (final e in fields.entries) {
      out[e.key.toString()] = _valueMsgToJson(_asWktMap(e.value));
    }
  }
  return out;
}

List<Object?> _listValueMsgToJson(Map<String, Object?> l) {
  final vals = l['values'];
  return vals is List
      ? [for (final e in vals) _valueMsgToJson(_asWktMap(e))]
      : <Object?>[];
}

Map<String, Object?> _valueMsgFromJson(Object? j) {
  if (j == null) return {'null_value': 0};
  if (j is bool) return {'bool_value': j};
  if (j is num) return {'number_value': j.toDouble()};
  if (j is String) return {'string_value': j};
  if (j is Map) return {'struct_value': _structMsgFromJson(j)};
  if (j is List) return {'list_value': _listValueMsgFromJson(j)};
  throw FormatException(
    'Cannot convert ${j.runtimeType} to google.protobuf.Value',
  );
}

Map<String, Object?> _structMsgFromJson(Object? j) {
  if (j is! Map) throw FormatException('Struct must be a JSON object');
  final fields = <String, Object?>{};
  for (final e in j.entries) {
    fields[e.key.toString()] = _valueMsgFromJson(e.value);
  }
  return {'fields': fields};
}

Map<String, Object?> _listValueMsgFromJson(Object? j) {
  if (j is! List) throw FormatException('ListValue must be a JSON array');
  return {
    'values': [for (final e in j) _valueMsgFromJson(e)],
  };
}

// google.protobuf.Any — needs a type registry to (de)serialize the embedded
// message, so the host injects a resolver (e.g. the conformance program from
// its descriptor registry). When unset, Any falls back to a generic message.

/// A function resolving a message type name (stripped FQN, e.g.
/// `google.protobuf.Duration`) to its field descriptor list.
typedef AnyTypeResolver = List<Map<String, Object?>>? Function(String typeName);

/// The **library-global** Any resolver, set by the host (e.g.
/// `conformance.dart`) to enable Any JSON. It is the *fallback* used when a JSON
/// (de)serialization is started without a per-call resolver — preserving full
/// backward compatibility for callers that set this once and never thread a
/// resolver per call.
///
/// Prefer the per-call [AnyTypeResolver] threaded through
/// [messageToJson]/[messageFromJson] (and `marshalJson`/`unmarshalJson`); it
/// does not mutate this global, so concurrent generated models with different
/// registries do not stomp on each other.
List<Map<String, Object?>>? Function(String typeName)? anyTypeResolver;

/// Installs the library-global [anyTypeResolver] hook (used to resolve the type
/// embedded in a `google.protobuf.Any` during JSON conversion when no per-call
/// resolver is supplied). Kept for backward compatibility — `conformance.dart`
/// sets it once at startup.
void setAnyTypeResolver(
  List<Map<String, Object?>>? Function(String typeName)? resolver,
) {
  anyTypeResolver = resolver;
}

String _anyTypeName(String typeUrl) {
  final slash = typeUrl.lastIndexOf('/');
  return slash >= 0 ? typeUrl.substring(slash + 1) : typeUrl;
}

/// A decoded Any message `{type_url, value: <bytes>}` -> proto3 JSON. A
/// well-known embedded type is nested under a `"value"` member alongside
/// `"@type"`; any other message merges its fields into the same object.
///
/// [resolver] is the per-call Any type resolver; when null the library-global
/// [anyTypeResolver] is used (backward compatibility).
Object? _anyToJson(
  Object? value,
  Map<String, String>? features,
  AnyTypeResolver? resolver,
) {
  if (value is! Map) return value;
  final url = value['type_url'];
  if (url is! String || url.isEmpty) return <String, Object?>{};
  final fqn = _anyTypeName(url);
  final desc = (resolver ?? anyTypeResolver)?.call(fqn);
  if (desc == null) throw FormatException('Any: unknown type "$url"');
  final raw = value['value'];
  final msg = unmarshal(raw is List<int> ? raw : <int>[], desc);
  // A type with a custom JSON form (the WKTs, and Any itself) embeds under a
  // "value" member alongside "@type"; an ordinary message merges its fields.
  if (fqn == 'google.protobuf.Any') {
    return {'@type': url, 'value': _anyToJson(msg, features, resolver)};
  }
  if (isWellKnownJsonType(fqn)) {
    return {'@type': url, 'value': wktToJson(fqn, msg, features, resolver)};
  }
  return {'@type': url, ..._marshalToMap(msg, desc, resolver)};
}

/// A proto3-JSON Any object -> decoded message `{type_url, value: <bytes>}`.
///
/// [resolver] is the per-call Any type resolver; when null the library-global
/// [anyTypeResolver] is used (backward compatibility).
Object? _anyFromJson(Object? json, AnyTypeResolver? resolver) {
  if (json is! Map) throw FormatException('Any must be a JSON object');
  // An empty JSON object is a valid (empty) Any.
  if (json.isEmpty) return {'type_url': '', 'value': <int>[]};
  final url = json['@type'];
  if (url is! String || url.isEmpty) {
    throw FormatException('Any is missing a valid "@type"');
  }
  final fqn = _anyTypeName(url);
  final desc = (resolver ?? anyTypeResolver)?.call(fqn);
  if (desc == null) throw FormatException('Any: unknown type "$url"');
  final Map<String, Object?> embedded;
  if (fqn == 'google.protobuf.Any') {
    embedded = _asWktMap(_anyFromJson(json['value'], resolver));
  } else if (isWellKnownJsonType(fqn)) {
    embedded = _asWktMap(wktFromJson(fqn, json['value'], null, resolver));
  } else {
    final fields = <String, Object?>{};
    for (final e in json.entries) {
      if (e.key == '@type') continue;
      fields[e.key.toString()] = e.value;
    }
    embedded = _unmarshalFromMap(fields, desc, resolver);
  }
  return {'type_url': url, 'value': marshal(embedded, desc)};
}

Object? fieldToJson(
  Object? value,
  String type, {
  String? typeName,
  Map<int, String>? enumValues,
  List<Map<String, Object?>>? messageDescriptor,
  Map<String, String>? features,
  AnyTypeResolver? resolver,
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

    // message: recursive marshal (or a well-known-type JSON mapping).
    case 'TYPE_MESSAGE':
      if (typeName == 'google.protobuf.Any' &&
          (resolver ?? anyTypeResolver) != null) {
        return _anyToJson(value, features, resolver);
      }
      if (typeName != null && isWellKnownJsonType(typeName)) {
        return wktToJson(typeName, value, features, resolver);
      }
      if (messageDescriptor != null && value is Map<String, Object?>) {
        return _marshalToMap(value, messageDescriptor, resolver);
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
  String? typeName,
  Map<int, String>? enumValues,
  Map<String, int>? enumNames,
  List<Map<String, Object?>>? messageDescriptor,
  Map<String, String>? features,
  AnyTypeResolver? resolver,
}) {
  if (jsonValue == null) {
    // A JSON null on a google.protobuf.Value field is the null *value*
    // (null_value), not an absent field.
    if (typeName == 'google.protobuf.Value') return {'null_value': 0};
    return null;
  }

  switch (type) {
    // 64-bit integers: a JSON string or number (proto3 JSON encodes these as
    // strings, but accepts numbers too; exponential and quoted forms allowed).
    // Range-checked: signed in [-2^63, 2^63-1], unsigned in [0, 2^64-1].
    case 'TYPE_INT64':
    case 'TYPE_SINT64':
    case 'TYPE_SFIXED64':
      return _jsonInt64(jsonValue, signed: true);
    case 'TYPE_UINT64':
    case 'TYPE_FIXED64':
      return _jsonInt64(jsonValue, signed: false);

    // bytes: base64 string -> List<int>.
    case 'TYPE_BYTES':
      if (jsonValue is String) {
        return base64.decode(jsonValue);
      }
      return jsonValue;

    // float / double: special string literals, else a finite number in range.
    case 'TYPE_FLOAT':
    case 'TYPE_DOUBLE':
      final double d;
      if (jsonValue is String) {
        switch (jsonValue) {
          case 'NaN':
            return double.nan;
          case 'Infinity':
            return double.infinity;
          case '-Infinity':
            return double.negativeInfinity;
          default:
            d = double.parse(jsonValue);
            // A finite numeric literal that overflowed to infinity is invalid
            // (the explicit "Infinity" forms were handled above).
            if (!d.isFinite) {
              throw FormatException('Number out of range: "$jsonValue"');
            }
        }
      } else if (jsonValue is num) {
        d = jsonValue.toDouble();
        if (!d.isFinite) {
          throw FormatException('Number out of range: $jsonValue');
        }
      } else {
        throw FormatException(
          'Expected a number for float/double, got ${jsonValue.runtimeType}',
        );
      }
      // float (32-bit) magnitude must fit in IEEE-754 single precision.
      if (type == 'TYPE_FLOAT' && d.abs() > 3.4028234663852886e38) {
        throw FormatException('float field out of range: $d');
      }
      return d;

    // enum: string name -> ordinal.
    case 'TYPE_ENUM':
      if (jsonValue is String) {
        // Name -> number, including allow_alias aliases (enumNames carries every
        // spelling; enumValues only the canonical one).
        final byName = enumNames?[jsonValue];
        if (byName != null) return byName;
        if (enumValues != null) {
          for (final entry in enumValues.entries) {
            if (entry.value == jsonValue) return entry.key;
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

    // message: recursive unmarshal (or a well-known-type JSON mapping).
    case 'TYPE_MESSAGE':
      if (typeName == 'google.protobuf.Any' &&
          (resolver ?? anyTypeResolver) != null) {
        return _anyFromJson(jsonValue, resolver);
      }
      if (typeName != null && isWellKnownJsonType(typeName)) {
        return wktFromJson(typeName, jsonValue, features, resolver);
      }
      if (messageDescriptor != null) {
        if (jsonValue is! Map) {
          throw FormatException(
            'Expected a JSON object for a message field, '
            'got ${jsonValue.runtimeType}',
          );
        }
        final stringMap = <String, Object?>{};
        for (final entry in jsonValue.entries) {
          stringMap[entry.key.toString()] = entry.value;
        }
        return _unmarshalFromMap(stringMap, messageDescriptor, resolver);
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
int _parseJsonInt(Object? v) => _jsonBigInt(v).toSigned(64).toInt();

/// Parses an integer JSON scalar [v] to a [BigInt] (range-unbounded).
///
/// Accepts a number or a quoted string in plain or exponential form; rejects
/// bools, non-integral numbers, and strings with surrounding whitespace.
BigInt _jsonBigInt(Object? v) {
  if (v is bool) {
    throw FormatException('Expected an integer JSON value, got a bool');
  }
  if (v is int) return BigInt.from(v);
  if (v is double) {
    if (v.isFinite && v == v.truncateToDouble()) return BigInt.from(v);
    throw FormatException('Non-integral JSON number for an integer field: $v');
  }
  if (v is String) {
    if (v.trim() != v) {
      throw FormatException('Integer JSON string has whitespace: "$v"');
    }
    final big = BigInt.tryParse(v);
    if (big != null) return big;
    // Exponential / decimal forms, accepted only when integral.
    final d = double.tryParse(v);
    if (d != null && d.isFinite && d == d.truncateToDouble()) {
      return BigInt.from(d);
    }
    throw FormatException('Invalid integer JSON value: "$v"');
  }
  throw FormatException('Expected an integer JSON value, got ${v.runtimeType}');
}

/// Parses a 64-bit integer JSON scalar [v], range-checked: signed values must
/// be in [-2^63, 2^63-1], unsigned in [0, 2^64-1]. The result is the signed
/// 64-bit bit pattern (a uint64 >= 2^63 is stored as a negative Dart int).
int _jsonInt64(Object? v, {required bool signed}) {
  final b = _jsonBigInt(v);
  final lo = signed ? -(BigInt.one << 63) : BigInt.zero;
  final hi = signed
      ? (BigInt.one << 63) - BigInt.one
      : (BigInt.one << 64) - BigInt.one;
  if (b < lo || b > hi) {
    throw FormatException('64-bit integer out of range: $b');
  }
  return b.toSigned(64).toInt();
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
// Message-level proto3-JSON: public object-valued entry points (for codegen)
// ---------------------------------------------------------------------------

/// Converts a decoded message [message] (snake_case proto field names) to its
/// proto3-JSON value — a JSON-compatible `Map<String, Object?>` (camelCase
/// keys, defaults omitted), NOT a serialized string.
///
/// This is the object-valued sibling of [marshalJson] (`marshalJson` is exactly
/// `jsonEncode(messageToJson(message, descriptor))`). Generated model code
/// delegates its `toProto3Json()` here so the conformance-pinned runtime does
/// the conversion.
///
/// `google.protobuf.Any` fields need a type registry to resolve the embedded
/// message. Pass [anyTypeResolver] to supply one **for this call only** — it is
/// threaded through the codec internals and does **not** mutate the
/// library-global [anyTypeResolver] hook, so independent generated models with
/// different registries never stomp on each other. When omitted, the
/// already-installed library-global hook (if any) is used as a fallback
/// (preserving backward compatibility for `conformance.dart` and other callers
/// that set the global once).
Object? messageToJson(
  Map<String, Object?> message,
  List<Map<String, Object?>> descriptor, {
  List<Map<String, Object?>>? Function(String typeName)? anyTypeResolver,
}) {
  return _marshalToMap(message, descriptor, anyTypeResolver);
}

/// Converts a proto3-JSON value [json] (a decoded `Map`/`List`/scalar, NOT a
/// serialized string) into a decoded message map (snake_case proto field
/// names).
///
/// This is the object-valued sibling of [unmarshalJson] (`unmarshalJson` first
/// `jsonDecode`s its string, then calls this). Generated model code delegates
/// its `fromProto3Json()` here.
///
/// See [messageToJson] for the per-call [anyTypeResolver] threading (no global
/// mutation; falls back to the library-global hook when omitted).
Map<String, Object?> messageFromJson(
  Object? json,
  List<Map<String, Object?>> descriptor, {
  List<Map<String, Object?>>? Function(String typeName)? anyTypeResolver,
}) {
  if (json is! Map) {
    throw FormatException(
      'Expected a JSON object at top level, got ${json.runtimeType}',
    );
  }
  final stringMap = <String, Object?>{};
  for (final entry in json.entries) {
    stringMap[entry.key.toString()] = entry.value;
  }
  return _unmarshalFromMap(stringMap, descriptor, anyTypeResolver);
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
  List<Map<String, Object?>> descriptor, [
  AnyTypeResolver? resolver,
]) {
  final result = <String, Object?>{};

  for (final field in descriptor) {
    final name = field['name'] as String;
    final type = field['type'] as String;
    final typeName = field['typeName'] as String?;
    final label = field['label'] as String?;
    final value = message[name];
    final isMap = field['mapEntry'] == true;
    final features = field['features'] as Map<String, String>?;
    // JSON output key: the json_name (explicit or protoc-derived) if present,
    // else the lowerCamelCase of the proto field name.
    final camelName = field['jsonName'] as String? ?? toCamelCase(name);

    if (isMap) {
      // Map field: encode as JSON object.
      if (value == null || (value is Map && value.isEmpty)) continue;
      final mapValue = value as Map;
      final valueType = field['valueType'] as String? ?? 'TYPE_STRING';
      final valueTypeName = field['valueTypeName'] as String?;
      final msgDesc = field['messageDescriptor'] as List<Map<String, Object?>>?;
      final enumVals = field['enumValues'] as Map<int, String>?;
      final jsonMap = <String, Object?>{};
      for (final entry in mapValue.entries) {
        final keyStr = entry.key.toString();
        jsonMap[keyStr] = fieldToJson(
          entry.value,
          valueType,
          typeName: valueTypeName,
          enumValues: enumVals,
          messageDescriptor: msgDesc,
          features: features,
          resolver: resolver,
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
            typeName: typeName,
            enumValues: enumVals,
            messageDescriptor: msgDesc,
            features: features,
            resolver: resolver,
          ),
      ];
    } else {
      // Singular field. With EXPLICIT/LEGACY_REQUIRED presence a present value
      // is emitted even when it equals the type default; a present-but-null
      // (unset) field is omitted. With implicit (proto3) presence — or no
      // resolved features — defaults are omitted as before (regression
      // firewall).
      // A set oneof member is emitted even at its default value (presence
      // selects the case); same for EXPLICIT/LEGACY_REQUIRED presence.
      final explicitPresence =
          field['oneof'] != null ||
          (features != null && hasExplicitPresence(features));
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
        typeName: typeName,
        enumValues: enumVals,
        messageDescriptor: msgDesc,
        features: features,
        resolver: resolver,
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
    lookup[name] = field; // proto field name (snake_case)
    lookup[toCamelCase(name)] = field; // lowerCamelCase
    final jsonName = field['jsonName'] as String?;
    if (jsonName != null)
      lookup[jsonName] = field; // explicit/derived json_name
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
  List<Map<String, Object?>> descriptor, [
  AnyTypeResolver? resolver,
]) {
  final lookup = _buildFieldLookup(descriptor);
  final result = <String, Object?>{};
  final seenOneofs = <String>{};

  for (final entry in jsonMap.entries) {
    final jsonKey = entry.key;
    final jsonValue = entry.value;
    final field = lookup[jsonKey];

    if (field == null) {
      // Unknown field — skip (Proto3 JSON parsers should ignore unknown fields).
      continue;
    }

    // Reject two JSON keys that select the same oneof (a oneof has at most one
    // member set). A `null` member is treated as unset, so it neither claims
    // the oneof nor conflicts with a real member.
    final oneof = field['oneof'] as String?;
    if (oneof != null && jsonValue != null && !seenOneofs.add(oneof)) {
      throw FormatException('Multiple JSON fields set the same oneof "$oneof"');
    }

    final name = field['name'] as String;
    final type = field['type'] as String;
    final typeName = field['typeName'] as String?;
    final label = field['label'] as String?;
    final isMap = field['mapEntry'] == true;
    final msgDesc = field['messageDescriptor'] as List<Map<String, Object?>>?;
    final enumVals = field['enumValues'] as Map<int, String>?;
    final enumNames = field['enumNames'] as Map<String, int>?;
    final features = field['features'] as Map<String, String>?;

    if (isMap) {
      // Map field: JSON object -> Dart map.
      if (jsonValue is Map) {
        final valueType = field['valueType'] as String? ?? 'TYPE_STRING';
        final valueTypeName = field['valueTypeName'] as String?;
        final dartMap = <String, Object?>{};
        for (final mapEntry in jsonValue.entries) {
          final keyStr = mapEntry.key.toString();
          dartMap[keyStr] = fieldFromJson(
            mapEntry.value,
            valueType,
            typeName: valueTypeName,
            enumValues: enumVals,
            enumNames: enumNames,
            messageDescriptor: msgDesc,
            features: features,
            resolver: resolver,
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
              typeName: typeName,
              enumValues: enumVals,
              enumNames: enumNames,
              messageDescriptor: msgDesc,
              features: features,
              resolver: resolver,
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
        typeName: typeName,
        enumValues: enumVals,
        enumNames: enumNames,
        messageDescriptor: msgDesc,
        features: features,
        resolver: resolver,
      );
    }
  }

  return result;
}
