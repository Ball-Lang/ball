/// `std_time` base module builder for the ball programming language.
///
/// Time operations: current time, formatting, parsing, duration arithmetic.
library;

import 'gen/google/protobuf/descriptor.pb.dart' as google;
import 'gen/ball/v1/ball.pb.dart';

/// Builds the std_time base module.
Module buildStdTimeModule() {
  final module = Module()
    ..name = 'std_time'
    ..description =
        'Standard time module. Current time, formatting, parsing, durations.';

  // ============================================================
  // Types
  // ============================================================

  module.types.addAll([
    _type('FormatTimestampInput', [
      _intField('timestamp_ms', 1),
      _stringField('format', 2),
    ]),
    _type('ParseTimestampInput', [
      _stringField('value', 1),
      _stringField('format', 2),
    ]),
    _type('DurationInput', [
      _intField('left', 1),
      _intField('right', 2),
    ]),
  ]);

  // ============================================================
  // Functions
  // ============================================================

  module.functions.addAll([
    // Current time
    _fn('now', '', 'int',
        'Current time in milliseconds since epoch'),
    _fn('now_micros', '', 'int',
        'Current time in microseconds since epoch'),

    // Formatting / parsing
    _fn('format_timestamp', 'FormatTimestampInput', 'string',
        'Format ms-since-epoch to ISO 8601 or custom format string'),
    _fn('parse_timestamp', 'ParseTimestampInput', 'int',
        'Parse timestamp string to ms-since-epoch'),

    // Duration arithmetic
    _fn('duration_add', 'DurationInput', 'int',
        'Add two durations (ms + ms)'),
    _fn('duration_subtract', 'DurationInput', 'int',
        'Subtract two durations (ms - ms)'),

    // Components
    _fn('year', '', 'int', 'Year component of current UTC time'),
    _fn('month', '', 'int', 'Month component of current UTC time (1-12)'),
    _fn('day', '', 'int', 'Day component of current UTC time (1-31)'),
    _fn('hour', '', 'int', 'Hour component of current UTC time (0-23)'),
    _fn('minute', '', 'int', 'Minute component of current UTC time (0-59)'),
    _fn('second', '', 'int', 'Second component of current UTC time (0-59)'),
  ]);

  return module;
}

// ================================================================
// Helpers
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

google.FieldDescriptorProto _intField(String name, int number) {
  return google.FieldDescriptorProto()
    ..name = name
    ..number = number
    ..type = google.FieldDescriptorProto_Type.TYPE_INT64;
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
