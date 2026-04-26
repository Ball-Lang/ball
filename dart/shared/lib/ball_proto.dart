/// `ball_proto` module builder — protobuf compatibility layer for Ball programs.
///
/// Provides deterministic protobuf-style access patterns over proto3 JSON
/// (plain maps/lists). When compiled to any target language, this module
/// ensures identical behavior for oneof discriminators, presence checks,
/// Struct field access, and proto3 defaults.
///
/// The engine imports this module instead of language-specific protobuf
/// libraries, enabling true self-hosting across all targets.
library;

import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart';

import 'gen/ball/v1/ball.pb.dart';

/// Builds the ball_proto base module.
Module buildBallProtoModule() {
  final module = Module()
    ..name = 'ball_proto'
    ..description =
        'Protobuf compatibility layer. Provides type-safe access patterns '
        'over proto3 JSON maps, ensuring identical behavior across all '
        'target languages. Base functions are implemented per-platform.';

  module.functions.addAll([
    // ── Oneof discriminators ──────────────────────────────────────
    _oneofDiscriminator('whichExpr', 'Expression', [
      'call', 'literal', 'reference', 'fieldAccess',
      'messageCreation', 'block', 'lambda',
    ]),
    _oneofDiscriminator('whichValue', 'Literal', [
      'intValue', 'doubleValue', 'stringValue', 'boolValue',
      'bytesValue', 'listValue',
    ]),
    _oneofDiscriminator('whichStmt', 'Statement', [
      'let', 'expression',
    ]),
    _oneofDiscriminator('whichKind', 'google.protobuf.Value', [
      'nullValue', 'numberValue', 'stringValue', 'boolValue',
      'structValue', 'listValue',
    ]),
    _oneofDiscriminator('whichSource', 'ModuleImport', [
      'http', 'file', 'git', 'registry', 'inline',
    ]),

    // ── Presence checks ──────────────────────────────────────────
    ..._presenceChecks([
      'body', 'metadata', 'input', 'descriptor', 'result',
      'call', 'literal', 'reference', 'fieldAccess',
      'messageCreation', 'block', 'lambda',
      'stringValue', 'boolValue', 'numberValue', 'listValue',
      'structValue', 'nullValue', 'intValue', 'doubleValue',
      'bytesValue', 'name', 'module', 'function',
    ]),

    // ── Struct field access ──────────────────────────────────────
    _baseFn('getStructField', ['struct', 'key'],
        doc: 'Get a field from a protobuf Struct. Returns Value-like map.'),
    _baseFn('getStringField', ['struct', 'key'],
        doc: 'Get string value from Struct field. Returns "" if missing.'),
    _baseFn('getBoolField', ['struct', 'key'],
        doc: 'Get bool value from Struct field. Returns false if missing.'),
    _baseFn('getListField', ['struct', 'key'],
        doc: 'Get list value from Struct field. Returns [] if missing.'),
    _baseFn('getNumberField', ['struct', 'key'],
        doc: 'Get number from Struct field. Returns 0 if missing.'),
    _baseFn('getStructFieldKeys', ['struct'],
        doc: 'Get all keys from a Struct/metadata map.'),

    // ── Proto3 defaults ──────────────────────────────────────────
    _baseFn('ensureDefaults', ['obj', 'messageType'],
        doc: 'Fill proto3 default values for the given message type.'),
    _baseFn('defaultString', [],
        doc: 'Returns "" (proto3 default for string fields).'),
    _baseFn('defaultList', [],
        doc: 'Returns [] (proto3 default for repeated fields).'),
    _baseFn('defaultBool', [],
        doc: 'Returns false (proto3 default for bool fields).'),
    _baseFn('defaultInt', [],
        doc: 'Returns 0 (proto3 default for int fields).'),

    // ── Safe field access ────────────────────────────────────────
    _baseFn('getField', ['obj', 'name'],
        doc: 'Get field from map. Returns null if missing.'),
    _baseFn('getFieldOr', ['obj', 'name', 'defaultValue'],
        doc: 'Get field from map. Returns default if missing.'),
    _baseFn('setField', ['obj', 'name', 'value'],
        doc: 'Set field on map. Returns the modified map.'),

    // ── Type enum constants ──────────────────────────────────────
    _baseFn('exprCase', ['name'],
        doc: 'Validate an Expression oneof case name.'),
    _baseFn('literalCase', ['name'],
        doc: 'Validate a Literal value case name.'),
    _baseFn('stmtCase', ['name'],
        doc: 'Validate a Statement oneof case name.'),
  ]);

  return module;
}

// ── Helpers ──────────────────────────────────────────────────────────

FunctionDefinition _oneofDiscriminator(
  String name,
  String messageType,
  List<String> variants,
) {
  return FunctionDefinition()
    ..name = name
    ..isBase = true
    ..inputType = 'Map'
    ..outputType = 'String'
    ..metadata = _meta({
      'params': variants.map((v) => <String, Object>{'name': 'obj'}).take(1).toList(),
      'doc': 'Returns which oneof field is set on a $messageType. '
          'Checks: ${variants.join(", ")}. Returns "notSet" if none.',
      'variants': variants,
      'messageType': messageType,
    });
}

List<FunctionDefinition> _presenceChecks(List<String> fields) {
  return fields.map((f) {
    final name = 'has${f[0].toUpperCase()}${f.substring(1)}';
    return FunctionDefinition()
      ..name = name
      ..isBase = true
      ..inputType = 'Map'
      ..outputType = 'bool'
      ..metadata = _meta({
        'params': [{'name': 'obj'}],
        'doc': 'Returns true if "$f" field is present and non-default.',
        'field': f,
      });
  }).toList();
}

FunctionDefinition _baseFn(
  String name,
  List<String> params, {
  required String doc,
}) {
  return FunctionDefinition()
    ..name = name
    ..isBase = true
    ..metadata = _meta({
      'params': params.map((p) => <String, Object>{'name': p}).toList(),
      'doc': doc,
    });
}

Struct _meta(Map<String, Object> map) {
  final struct = Struct();
  for (final entry in map.entries) {
    struct.fields[entry.key] = _toValue(entry.value);
  }
  return struct;
}

Value _toValue(Object value) {
  if (value is String) return Value()..stringValue = value;
  if (value is bool) return Value()..boolValue = value;
  if (value is num) return Value()..numberValue = value.toDouble();
  if (value is List) {
    return Value()
      ..listValue = (ListValue()
        ..values.addAll(value.map((v) => _toValue(v as Object))));
  }
  if (value is Map<String, Object>) {
    final struct = Struct();
    for (final e in value.entries) {
      struct.fields[e.key] = _toValue(e.value);
    }
    return Value()..structValue = struct;
  }
  return Value()..stringValue = value.toString();
}
