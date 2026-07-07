//! `std_memory` base module builder (issue #35).
//!
//! Ports `dart/shared/lib/std_memory.dart` to Rust. Provides a linear memory
//! simulation layer for languages that require low-level pointer arithmetic
//! and manual memory management (C, C++, Rust `unsafe` blocks, etc.).
//!
//! The memory model is a single contiguous byte array (heap) plus a stack
//! pointer for automatic allocations. All addresses are integer indices
//! into this array.
//!
//! High-level object-oriented code should NOT use this module — the hybrid
//! normalizer only lowers operations here when pointer arithmetic or raw
//! memory access is detected. Depends on `std`.

use crate::descriptor_builders::{base_fn, expr_field, int_field, string_field, type_def};
use crate::{FunctionDefinition, Module, TypeDefinition};

/// Build the `std_memory` base module.
pub fn build_std_memory_module() -> Module {
    Module {
        name: "std_memory".to_string(),
        description: "Linear memory simulation module. Provides heap allocation, \
            typed reads/writes, pointer arithmetic, and stack frame management. \
            Used by the hybrid normalizer when C/C++ code performs raw pointer \
            operations that cannot be safely projected to native references."
            .to_string(),
        type_defs: type_defs(),
        functions: functions(),
        ..Default::default()
    }
}

fn type_defs() -> Vec<TypeDefinition> {
    vec![
        // Allocation / deallocation
        type_def("AllocInput", vec![int_field("size", 1)]),
        type_def("FreeInput", vec![int_field("address", 1)]),
        type_def(
            "ReallocInput",
            vec![int_field("address", 1), int_field("new_size", 2)],
        ),
        // Typed read (address -> value)
        type_def("MemReadInput", vec![int_field("address", 1)]),
        // Typed write (address, value -> void)
        type_def(
            "MemWriteInput",
            vec![int_field("address", 1), expr_field("value", 2)],
        ),
        // Bulk memory operations
        type_def(
            "MemCopyInput",
            vec![
                int_field("dest", 1),
                int_field("src", 2),
                int_field("size", 3),
            ],
        ),
        type_def(
            "MemSetInput",
            vec![
                int_field("address", 1),
                int_field("value", 2),
                int_field("size", 3),
            ],
        ),
        type_def(
            "MemCompareInput",
            vec![int_field("a", 1), int_field("b", 2), int_field("size", 3)],
        ),
        // Pointer arithmetic
        type_def(
            "PtrArithInput",
            vec![
                int_field("address", 1),
                int_field("offset", 2),
                int_field("element_size", 3),
            ],
        ),
        // Stack frame management
        type_def("StackAllocInput", vec![int_field("size", 1)]),
        // Sizeof query
        type_def("SizeofInput", vec![string_field("type_name", 1)]),
        // Address-of / dereference (used before normalization decides safe vs unsafe)
        type_def("AddressOfInput", vec![expr_field("value", 1)]),
        type_def("DerefInput", vec![expr_field("pointer", 1)]),
    ]
}

fn functions() -> Vec<FunctionDefinition> {
    vec![
        // --- Heap allocation ---
        base_fn(
            "memory_alloc",
            "AllocInput",
            "",
            "Allocate size bytes on the heap. Returns base address (int).",
        ),
        base_fn(
            "memory_free",
            "FreeInput",
            "",
            "Free a previously allocated block at address.",
        ),
        base_fn(
            "memory_realloc",
            "ReallocInput",
            "",
            "Resize a previously allocated block. Returns new base address.",
        ),
        // --- Typed reads (little-endian) ---
        base_fn(
            "memory_read_i8",
            "MemReadInput",
            "",
            "Read signed 8-bit integer at address.",
        ),
        base_fn(
            "memory_read_u8",
            "MemReadInput",
            "",
            "Read unsigned 8-bit integer at address.",
        ),
        base_fn(
            "memory_read_i16",
            "MemReadInput",
            "",
            "Read signed 16-bit integer at address.",
        ),
        base_fn(
            "memory_read_u16",
            "MemReadInput",
            "",
            "Read unsigned 16-bit integer at address.",
        ),
        base_fn(
            "memory_read_i32",
            "MemReadInput",
            "",
            "Read signed 32-bit integer at address.",
        ),
        base_fn(
            "memory_read_u32",
            "MemReadInput",
            "",
            "Read unsigned 32-bit integer at address.",
        ),
        base_fn(
            "memory_read_i64",
            "MemReadInput",
            "",
            "Read signed 64-bit integer at address.",
        ),
        base_fn(
            "memory_read_u64",
            "MemReadInput",
            "",
            "Read unsigned 64-bit integer at address.",
        ),
        base_fn(
            "memory_read_f32",
            "MemReadInput",
            "",
            "Read 32-bit float at address.",
        ),
        base_fn(
            "memory_read_f64",
            "MemReadInput",
            "",
            "Read 64-bit float (double) at address.",
        ),
        // --- Typed writes (little-endian) ---
        base_fn(
            "memory_write_i8",
            "MemWriteInput",
            "",
            "Write signed 8-bit integer at address.",
        ),
        base_fn(
            "memory_write_u8",
            "MemWriteInput",
            "",
            "Write unsigned 8-bit integer at address.",
        ),
        base_fn(
            "memory_write_i16",
            "MemWriteInput",
            "",
            "Write signed 16-bit integer at address.",
        ),
        base_fn(
            "memory_write_u16",
            "MemWriteInput",
            "",
            "Write unsigned 16-bit integer at address.",
        ),
        base_fn(
            "memory_write_i32",
            "MemWriteInput",
            "",
            "Write signed 32-bit integer at address.",
        ),
        base_fn(
            "memory_write_u32",
            "MemWriteInput",
            "",
            "Write unsigned 32-bit integer at address.",
        ),
        base_fn(
            "memory_write_i64",
            "MemWriteInput",
            "",
            "Write signed 64-bit integer at address.",
        ),
        base_fn(
            "memory_write_u64",
            "MemWriteInput",
            "",
            "Write unsigned 64-bit integer at address.",
        ),
        base_fn(
            "memory_write_f32",
            "MemWriteInput",
            "",
            "Write 32-bit float at address.",
        ),
        base_fn(
            "memory_write_f64",
            "MemWriteInput",
            "",
            "Write 64-bit float (double) at address.",
        ),
        // --- Bulk operations ---
        base_fn(
            "memory_copy",
            "MemCopyInput",
            "",
            "Copy size bytes from src to dest (memmove-safe).",
        ),
        base_fn(
            "memory_set",
            "MemSetInput",
            "",
            "Fill size bytes at address with value (memset).",
        ),
        base_fn(
            "memory_compare",
            "MemCompareInput",
            "",
            "Compare size bytes at a and b. Returns <0, 0, or >0 (memcmp).",
        ),
        // --- Pointer arithmetic ---
        base_fn(
            "ptr_add",
            "PtrArithInput",
            "",
            "Pointer add: address + offset * element_size.",
        ),
        base_fn(
            "ptr_sub",
            "PtrArithInput",
            "",
            "Pointer subtract: address - offset * element_size.",
        ),
        base_fn(
            "ptr_diff",
            "PtrArithInput",
            "",
            "Pointer difference: (a - b) / element_size.",
        ),
        // --- Stack frame ---
        base_fn(
            "stack_alloc",
            "StackAllocInput",
            "",
            "Allocate size bytes on the stack frame. Returns base address.",
        ),
        base_fn(
            "stack_push_frame",
            "",
            "",
            "Push a new stack frame (function entry).",
        ),
        base_fn(
            "stack_pop_frame",
            "",
            "",
            "Pop the current stack frame (function exit). Frees all stack_alloc in this frame.",
        ),
        // --- Sizeof ---
        base_fn(
            "memory_sizeof",
            "SizeofInput",
            "",
            "Return the byte size of a named type (e.g. \"int32\" -> 4).",
        ),
        // --- Address-of / dereference (pre-normalization) ---
        base_fn(
            "address_of",
            "AddressOfInput",
            "",
            "Take the address of a value. Pre-normalization placeholder.",
        ),
        base_fn(
            "deref",
            "DerefInput",
            "",
            "Dereference a pointer. Pre-normalization placeholder.",
        ),
        // --- Null pointer ---
        base_fn("nullptr", "", "", "Null pointer constant (address 0)."),
        // --- Memory info ---
        base_fn(
            "memory_heap_size",
            "",
            "",
            "Current total heap size in bytes.",
        ),
        base_fn("memory_stack_size", "", "", "Current stack usage in bytes."),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_function_is_base_with_no_body() {
        let module = build_std_memory_module();
        assert_eq!(module.name, "std_memory");
        for function in &module.functions {
            assert!(function.is_base, "{} must be is_base", function.name);
            assert!(
                function.body.is_none(),
                "{} must have no body",
                function.name
            );
        }
    }

    #[test]
    fn function_count_matches_std_json() {
        let module = build_std_memory_module();
        assert_eq!(module.functions.len(), 38);
    }
}
