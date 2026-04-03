/// `std_fs` base module builder for the ball programming language.
///
/// File system operations: read, write, append, delete, directory listing.
/// Not available in browser/WASM runtimes.
library;

import 'gen/google/protobuf/descriptor.pb.dart' as google;
import 'gen/ball/v1/ball.pb.dart';

/// Builds the std_fs base module.
Module buildStdFsModule() {
  final module = Module()
    ..name = 'std_fs'
    ..description =
        'Standard file system module. File and directory operations. '
        'Not available in browser, WASM, or sandboxed runtimes.';

  // ============================================================
  // Types
  // ============================================================

  module.types.addAll([
    _type('FilePathInput', [_stringField('path', 1)]),
    _type('FileWriteInput', [
      _stringField('path', 1),
      _stringField('content', 2),
    ]),
    _type('FileWriteBytesInput', [
      _stringField('path', 1),
      _bytesField('content', 2),
    ]),
    _type('FileAppendInput', [
      _stringField('path', 1),
      _stringField('content', 2),
    ]),
  ]);

  // ============================================================
  // Functions
  // ============================================================

  module.functions.addAll([
    // File operations
    _fn('file_read', 'FilePathInput', 'string', 'Read file contents as string'),
    _fn(
      'file_read_bytes',
      'FilePathInput',
      'bytes',
      'Read file contents as bytes',
    ),
    _fn(
      'file_write',
      'FileWriteInput',
      '',
      'Write string to file (creates or overwrites)',
    ),
    _fn(
      'file_write_bytes',
      'FileWriteBytesInput',
      '',
      'Write bytes to file (creates or overwrites)',
    ),
    _fn('file_append', 'FileAppendInput', '', 'Append string to file'),
    _fn('file_exists', 'FilePathInput', 'bool', 'Check if file exists'),
    _fn('file_delete', 'FilePathInput', '', 'Delete file'),

    // Directory operations
    _fn(
      'dir_list',
      'FilePathInput',
      '',
      'List directory contents (returns list of strings)',
    ),
    _fn('dir_create', 'FilePathInput', '', 'Create directory (recursive)'),
    _fn('dir_exists', 'FilePathInput', 'bool', 'Check if directory exists'),
  ]);

  return module;
}

// ================================================================
// Helpers
// ================================================================

google.DescriptorProto _type(
  String name,
  List<google.FieldDescriptorProto> fields,
) {
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

FunctionDefinition _fn(
  String name,
  String inputType,
  String returnType,
  String description,
) {
  return FunctionDefinition()
    ..name = name
    ..inputType = inputType
    ..outputType = returnType
    ..isBase = true
    ..description = description;
}
