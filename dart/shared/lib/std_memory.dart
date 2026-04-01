/// `std_memory` base module builder for the ball programming language.
///
/// Provides a linear memory simulation layer for languages that require
/// low-level pointer arithmetic and manual memory management (C, C++, Rust
/// unsafe blocks, etc.).
///
/// The memory model is a single contiguous byte array (heap) plus a stack
/// pointer for automatic allocations. All addresses are integer indices
/// into this array.
///
/// High-level object-oriented code should NOT use this module — the hybrid
/// normalizer will only lower operations here when pointer arithmetic or
/// raw memory access is detected.
///
/// Depends on `std`.
library;

import 'gen/google/protobuf/descriptor.pb.dart' as google;
import 'gen/ball/v1/ball.pb.dart';

/// Builds the std_memory base module.
Module buildStdMemoryModule() {
  final module = Module()
    ..name = 'std_memory'
    ..description =
        'Linear memory simulation module. Provides heap allocation, '
        'typed reads/writes, pointer arithmetic, and stack frame management. '
        'Used by the hybrid normalizer when C/C++ code performs raw pointer '
        'operations that cannot be safely projected to native references.';

  // ============================================================
  // Types
  // ============================================================

  module.types.addAll([
    // Allocation / deallocation
    _type('AllocInput', [_intField('size', 1)]),
    _type('FreeInput', [_intField('address', 1)]),
    _type('ReallocInput', [
      _intField('address', 1),
      _intField('new_size', 2),
    ]),

    // Typed read (address → value)
    _type('MemReadInput', [_intField('address', 1)]),

    // Typed write (address, value → void)
    _type('MemWriteInput', [
      _intField('address', 1),
      _exprField('value', 2),
    ]),

    // Bulk memory operations
    _type('MemCopyInput', [
      _intField('dest', 1),
      _intField('src', 2),
      _intField('size', 3),
    ]),
    _type('MemSetInput', [
      _intField('address', 1),
      _intField('value', 2),
      _intField('size', 3),
    ]),
    _type('MemCompareInput', [
      _intField('a', 1),
      _intField('b', 2),
      _intField('size', 3),
    ]),

    // Pointer arithmetic
    _type('PtrArithInput', [
      _intField('address', 1),
      _intField('offset', 2),
      _intField('element_size', 3),
    ]),

    // Stack frame management
    _type('StackAllocInput', [_intField('size', 1)]),

    // Sizeof query
    _type('SizeofInput', [_stringField('type_name', 1)]),

    // Address-of / dereference (used before normalization decides safe vs unsafe)
    _type('AddressOfInput', [_exprField('value', 1)]),
    _type('DerefInput', [_exprField('pointer', 1)]),
  ]);

  // ============================================================
  // Functions
  // ============================================================

  module.functions.addAll([
    // --- Heap allocation ---
    _fn('memory_alloc', 'AllocInput', '',
        'Allocate size bytes on the heap. Returns base address (int).'),
    _fn('memory_free', 'FreeInput', '',
        'Free a previously allocated block at address.'),
    _fn('memory_realloc', 'ReallocInput', '',
        'Resize a previously allocated block. Returns new base address.'),

    // --- Typed reads (little-endian) ---
    _fn('memory_read_i8', 'MemReadInput', '',
        'Read signed 8-bit integer at address.'),
    _fn('memory_read_u8', 'MemReadInput', '',
        'Read unsigned 8-bit integer at address.'),
    _fn('memory_read_i16', 'MemReadInput', '',
        'Read signed 16-bit integer at address.'),
    _fn('memory_read_u16', 'MemReadInput', '',
        'Read unsigned 16-bit integer at address.'),
    _fn('memory_read_i32', 'MemReadInput', '',
        'Read signed 32-bit integer at address.'),
    _fn('memory_read_u32', 'MemReadInput', '',
        'Read unsigned 32-bit integer at address.'),
    _fn('memory_read_i64', 'MemReadInput', '',
        'Read signed 64-bit integer at address.'),
    _fn('memory_read_u64', 'MemReadInput', '',
        'Read unsigned 64-bit integer at address.'),
    _fn('memory_read_f32', 'MemReadInput', '',
        'Read 32-bit float at address.'),
    _fn('memory_read_f64', 'MemReadInput', '',
        'Read 64-bit float (double) at address.'),

    // --- Typed writes (little-endian) ---
    _fn('memory_write_i8', 'MemWriteInput', '',
        'Write signed 8-bit integer at address.'),
    _fn('memory_write_u8', 'MemWriteInput', '',
        'Write unsigned 8-bit integer at address.'),
    _fn('memory_write_i16', 'MemWriteInput', '',
        'Write signed 16-bit integer at address.'),
    _fn('memory_write_u16', 'MemWriteInput', '',
        'Write unsigned 16-bit integer at address.'),
    _fn('memory_write_i32', 'MemWriteInput', '',
        'Write signed 32-bit integer at address.'),
    _fn('memory_write_u32', 'MemWriteInput', '',
        'Write unsigned 32-bit integer at address.'),
    _fn('memory_write_i64', 'MemWriteInput', '',
        'Write signed 64-bit integer at address.'),
    _fn('memory_write_u64', 'MemWriteInput', '',
        'Write unsigned 64-bit integer at address.'),
    _fn('memory_write_f32', 'MemWriteInput', '',
        'Write 32-bit float at address.'),
    _fn('memory_write_f64', 'MemWriteInput', '',
        'Write 64-bit float (double) at address.'),

    // --- Bulk operations ---
    _fn('memory_copy', 'MemCopyInput', '',
        'Copy size bytes from src to dest (memmove-safe).'),
    _fn('memory_set', 'MemSetInput', '',
        'Fill size bytes at address with value (memset).'),
    _fn('memory_compare', 'MemCompareInput', '',
        'Compare size bytes at a and b. Returns <0, 0, or >0 (memcmp).'),

    // --- Pointer arithmetic ---
    _fn('ptr_add', 'PtrArithInput', '',
        'Pointer add: address + offset * element_size.'),
    _fn('ptr_sub', 'PtrArithInput', '',
        'Pointer subtract: address - offset * element_size.'),
    _fn('ptr_diff', 'PtrArithInput', '',
        'Pointer difference: (a - b) / element_size.'),

    // --- Stack frame ---
    _fn('stack_alloc', 'StackAllocInput', '',
        'Allocate size bytes on the stack frame. Returns base address.'),
    _fn('stack_push_frame', '', '',
        'Push a new stack frame (function entry).'),
    _fn('stack_pop_frame', '', '',
        'Pop the current stack frame (function exit). Frees all stack_alloc in this frame.'),

    // --- Sizeof ---
    _fn('memory_sizeof', 'SizeofInput', '',
        'Return the byte size of a named type (e.g. "int32" → 4).'),

    // --- Address-of / dereference (pre-normalization) ---
    _fn('address_of', 'AddressOfInput', '',
        'Take the address of a value. Pre-normalization placeholder.'),
    _fn('deref', 'DerefInput', '',
        'Dereference a pointer. Pre-normalization placeholder.'),

    // --- Null pointer ---
    _fn('nullptr', '', '',
        'Null pointer constant (address 0).'),

    // --- Memory info ---
    _fn('memory_heap_size', '', '',
        'Current total heap size in bytes.'),
    _fn('memory_stack_size', '', '',
        'Current stack usage in bytes.'),
  ]);

  return module;
}

// ============================================================
// Helpers
// ============================================================

const _exprTypeName = '.ball.v1.Expression';

google.DescriptorProto _type(
  String name,
  List<google.FieldDescriptorProto> fields,
) => google.DescriptorProto()
  ..name = name
  ..field.addAll(fields);

google.FieldDescriptorProto _exprField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_MESSAGE
      ..typeName = _exprTypeName
      ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL;

google.FieldDescriptorProto _intField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_INT64
      ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL;

google.FieldDescriptorProto _stringField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_STRING
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
