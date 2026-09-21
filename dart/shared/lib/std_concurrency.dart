/// `std_concurrency` base module builder for the ball programming language.
///
/// Provides threading, mutex, and atomic primitives.
///
/// Every resource in this module is addressed by an OPAQUE INTEGER HANDLE:
/// `thread_spawn`, `mutex_create` and `atomic_create` mint one, and every other
/// function takes one back. A handle's numeric value is an implementation
/// detail — a portable program may compare handles, never depend on their
/// numbering.
///
/// Engines can choose single-threaded simulation or real threading, but the
/// OBSERVABLE contract is the same either way: a spawned body runs, a joined
/// handle is a handle that was spawned, a locked mutex is unlocked before it is
/// locked again, an `atomic_load` answers the last `atomic_store`, and an
/// `atomic_compare_exchange` exchanges only when the cell holds `expected`.
/// Every Ball engine today implements the single-threaded end of that contract
/// (`thread_spawn` runs the body eagerly); see `docs/TESTING_STRATEGY.md` and
/// conformance fixture `476_std_concurrency_handles`, which pins it on every
/// engine and every compiled target.
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

  module.typeDefs.addAll(
    <google.DescriptorProto>[
      _type('ThreadInput', [_exprField('body', 1)]),
      _type('MutexInput', []),
      _type('LockInput', [_exprField('mutex', 1), _exprField('body', 2)]),
      // `atomic_create`'s initial value.
      _type('AtomicInput', [_exprField('value', 1)]),
      // `atomic_store` reads {atomic, value}; `atomic_compare_exchange` reads
      // all three — `expected` is the value the cell must currently hold for
      // the exchange to happen, `value` is the one it is exchanged FOR.
      //
      // Field 2 held a `string op` until the #607/#608 pass: nothing in any
      // engine, compiler or encoder ever read it, and without an `expected`
      // field a compare-and-exchange could not be EXPRESSED at all — which is
      // precisely why every engine's CAS returned an unconditional `true`.
      _type('AtomicOpInput', [
        _exprField('atomic', 1),
        _exprField('expected', 2),
        _exprField('value', 3),
      ]),
    ].map(
      (d) => TypeDefinition()
        ..name = d.name
        ..descriptor = d,
    ),
  );

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
    // "release on exit" means release when the body RETURNS: every
    // implementation (the Dart engine, and the Dart/TS/C++ compiler preambles)
    // unlocks with a plain statement after the body call, so a body that THROWS
    // propagates with the mutex still held and the next lock on that handle
    // fails loud. Consistent across all four, never a silent wrong answer, and
    // tracked by issue #769 — which is what will make the declaration and the
    // implementations agree, with a fixture pinning whichever answer wins.
    _fn(
      'scoped_lock',
      'LockInput',
      '',
      'Acquire mutex, run body, release on exit',
    ),

    // Atomics
    _fn(
      'atomic_create',
      'AtomicInput',
      'int',
      'Create an atomic cell holding the given value, return handle',
    ),
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
// Helpers (same shape as std.dart's field builders)
// ================================================================

google.DescriptorProto _type(
  String name,
  List<google.FieldDescriptorProto> fields,
) {
  return google.DescriptorProto()
    ..name = name
    ..field.addAll(fields);
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
