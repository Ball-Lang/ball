/// `std_convert` base module builder for the ball programming language.
///
/// Provides JSON, UTF-8, and base64 encoding/decoding.
/// Every target language has built-in or standard library support for these.
library;

import 'gen/google/protobuf/descriptor.pb.dart' as google;
import 'gen/ball/v1/ball.pb.dart';

/// Builds the std_convert base module.
Module buildStdConvertModule() {
  final module = Module()
    ..name = 'std_convert'
    ..description =
        'Standard conversion module. JSON, UTF-8, base64 encoding/decoding.';

  // ============================================================
  // Types
  // ============================================================

  module.types.addAll([
    _type('JsonEncodeInput', [_exprField('value', 1)]),
    _type('JsonDecodeInput', [_stringField('value', 1)]),
    _type('Utf8EncodeInput', [_stringField('value', 1)]),
    _type('Utf8DecodeInput', [_bytesField('value', 1)]),
    _type('Base64EncodeInput', [_bytesField('value', 1)]),
    _type('Base64DecodeInput', [_stringField('value', 1)]),
  ]);

  // ============================================================
  // Functions
  // ============================================================

  module.functions.addAll([
    // JSON
    _fn('json_encode', 'JsonEncodeInput', 'string',
        'Encode value to JSON string'),
    _fn('json_decode', 'JsonDecodeInput', '',
        'Decode JSON string to value (map/list/scalar)'),

    // UTF-8
    _fn('utf8_encode', 'Utf8EncodeInput', 'bytes',
        'Encode string to UTF-8 bytes'),
    _fn('utf8_decode', 'Utf8DecodeInput', 'string',
        'Decode UTF-8 bytes to string'),

    // Base64
    _fn('base64_encode', 'Base64EncodeInput', 'string',
        'Encode bytes to base64 string'),
    _fn('base64_decode', 'Base64DecodeInput', 'bytes',
        'Decode base64 string to bytes'),
  ]);

  return module;
}

// ================================================================
// Helpers (identical to std.dart pattern)
// ================================================================

google.DescriptorProto _type(String name, List<google.FieldDescriptorProto> fields) {
  return google.DescriptorProto()
    ..name = name
    ..field.addAll(fields);
}

google.FieldDescriptorProto _stringField(String name, int number) {
  return google.FieldDescriptorProto()
    ..name = name
    ..number = number
    ..type = google.FieldDescriptorProto_Type.TYPE_STRING;
}

google.FieldDescriptorProto _bytesField(String name, int number) {
  return google.FieldDescriptorProto()
    ..name = name
    ..number = number
    ..type = google.FieldDescriptorProto_Type.TYPE_BYTES;
}

google.FieldDescriptorProto _exprField(String name, int number) {
  return google.FieldDescriptorProto()
    ..name = name
    ..number = number
    ..type = google.FieldDescriptorProto_Type.TYPE_MESSAGE
    ..typeName = '.ball.v1.Expression';
}

FunctionDefinition _fn(String name, String inputType, String returnType, String description) {
  return FunctionDefinition()
    ..name = name
    ..inputType = inputType
    ..outputType = returnType
    ..isBase = true
    ..description = description;
}
