/// `std_concurrency` base module builder for the ball programming language.
///
/// Provides threading, mutex, and atomic primitives.
/// Engines can choose single-threaded simulation or real threading.
library;

import 'gen/google/protobuf/descriptor.pb.dart' as google;
import 'gen/ball/v1/ball.pb.dart';

/// Builds the std_concurrency base module.
Module buildStdConcurrencyModule() {
  final module = Module()
    ..name = 'std_concurrency'
    ..description =
        'Concurrency primitives: threads, mutexes, atomics. '
        'Engines may simulate single-threaded or use real threads.';

  // ============================================================
  // Types
  // ============================================================

  module.types.addAll([
    _type('ThreadInput', [_exprField('body', 1)]),
    _type('MutexInput', []),
    _type('LockInput', [_exprField('mutex', 1), _exprField('body', 2)]),
    _type('AtomicInput', [_exprField('value', 1)]),
    _type('AtomicOpInput', [
      _exprField('atomic', 1),
      _stringField('op', 2),
      _exprField('value', 3),
    ]),
  ]);

  // ============================================================
  // Functions
  // ============================================================

  module.functions.addAll([
    // Threading
    _fn(
      'thread_spawn',
      'ThreadInput',
      'int',
      'Spawn a new thread, return thread handle',
    ),
    _fn('thread_join', 'UnaryInput', 'void', 'Wait for thread to complete'),

    // Mutex
    _fn('mutex_create', 'MutexInput', 'int', 'Create a mutex, return handle'),
    _fn('mutex_lock', 'UnaryInput', 'void', 'Acquire mutex'),
    _fn('mutex_unlock', 'UnaryInput', 'void', 'Release mutex'),
    _fn(
      'scoped_lock',
      'LockInput',
      '',
      'Acquire mutex, run body, release on exit',
    ),

    // Atomics
    _fn('atomic_load', 'UnaryInput', '', 'Atomic read of value'),
    _fn('atomic_store', 'AtomicOpInput', 'void', 'Atomic write of value'),
    _fn(
      'atomic_compare_exchange',
      'AtomicOpInput',
      'bool',
      'Atomic compare-and-swap',
    ),
  ]);

  return module;
}

// ================================================================
// Helpers (identical to std.dart pattern)
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

google.FieldDescriptorProto _exprField(String name, int number) {
  return google.FieldDescriptorProto()
    ..name = name
    ..number = number
    ..type = google.FieldDescriptorProto_Type.TYPE_MESSAGE
    ..typeName = '.ball.v1.Expression';
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
