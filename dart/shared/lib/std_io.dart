/// `std_io` base module builder for the ball programming language.
///
/// Import explicitly — not available in browser JS, WASM sandboxes,
/// embedded targets, or serverless functions without a TTY.
///
/// Depends on `std`.
library;

import 'gen/google/protobuf/descriptor.pb.dart' as google;
import 'gen/ball/v1/ball.pb.dart';

/// Builds the std_io base module.
Module buildStdIoModule() {
  final module = Module()
    ..name = 'std_io'
    ..description =
        'Standard I/O module. Console, process, time, random, environment. '
        'Not available in all runtimes (browser, WASM, embedded).';

  // ============================================================
  // Types
  // ============================================================

  module.types.addAll([
    _type('PrintErrorInput', [_stringField('message', 1)]),
    _type('ExitInput', [_intField('code', 1)]),
    _type('PanicInput', [_stringField('message', 1)]),
    _type('SleepInput', [_intField('milliseconds', 1)]),
    _type('RandomIntInput', [_intField('min', 1), _intField('max', 2)]),
    _type('EnvGetInput', [_stringField('name', 1)]),
  ]);

  // ============================================================
  // Functions
  // ============================================================

  module.functions.addAll([
    // Console
    _fn('print_error', 'PrintErrorInput', '',
        'Write to stderr: stderr.writeln(message)'),

    // Standard input
    _fn('read_line', '', '', 'Read one line from stdin'),

    // Process control
    _fn('exit', 'ExitInput', '', 'Terminate with exit code'),
    _fn('panic', 'PanicInput', '',
        'Hard abort with message (Rust panic!, C++ terminate, Java RuntimeException)'),

    // Time
    _fn('sleep_ms', 'SleepInput', '',
        'Pause execution N milliseconds'),
    _fn('timestamp_ms', '', '',
        'Wall clock milliseconds since epoch'),

    // Randomness
    _fn('random_int', 'RandomIntInput', '',
        'Random integer in range [min, max]'),
    _fn('random_double', '', '',
        'Random double in [0.0, 1.0)'),

    // Environment
    _fn('env_get', 'EnvGetInput', '',
        'Read environment variable by name'),
    _fn('args_get', '', '',
        'Command-line arguments as list of strings'),
  ]);

  return module;
}

// ============================================================
// Helpers
// ============================================================

google.DescriptorProto _type(
  String name,
  List<google.FieldDescriptorProto> fields,
) => google.DescriptorProto()
  ..name = name
  ..field.addAll(fields);

google.FieldDescriptorProto _stringField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_STRING
      ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL;

google.FieldDescriptorProto _intField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_INT64
      ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL;

FunctionDefinition _fn(
  String name,
  String inputType,
  String outputType,
  String description,
) => FunctionDefinition()
  ..name = name
  ..inputType = inputType
  ..outputType = outputType
  ..isBase = true
  ..description = description;
