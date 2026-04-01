---
name: ball-encoder
description: >
  Build, modify, debug, or extend a Ball encoder that translates source code into Ball programs.
  USE FOR: adding new expression encoding, fixing AST-to-Ball translation, handling new language
  constructs, improving round-trip fidelity, or creating a new source language encoder. DO NOT USE
  FOR: compiler work, engine work, or proto schema changes. The Dart encoder is the reference
  implementation (uses analyzer package). The C++ encoder uses Clang JSON AST.
---

# Ball Encoder Skill

## What is a Ball Encoder?

An encoder reads source code in a target language and produces a Ball `Program` protobuf message. This is the inverse of a compiler. The Dart encoder (`dart/encoder/lib/encoder.dart`) is the reference implementation.

## Architecture

```
Source Code
  → Parse to language AST (analyzer for Dart, Clang for C++)
  → Walk AST nodes
  → Map each construct to Ball expressions
  → Collect base function references (std, dart_std, etc.)
  → Build module structure (types, functions, imports)
  → Output Program protobuf message
```

## Expression Mapping

| Source Construct | Ball Expression |
|-----------------|-----------------|
| Binary operator (`a + b`) | `call` to `std.add` with MessageCreation input |
| If statement | `call` to `std.if` with condition/then/else fields |
| Variable declaration | `LetBinding` in `Block` |
| Function call | `call` with module/function/input |
| Field access (`obj.field`) | `fieldAccess` with object and field |
| Object creation (`new Foo()`) | `messageCreation` with type and fields |
| Lambda/closure | `FunctionDefinition` with name = "" |
| Literals | `literal` with appropriate value type |

## Operator Mapping

| Operator | Ball Function | Module |
|----------|--------------|--------|
| `+` | `add` | std |
| `-` | `subtract` | std |
| `*` | `multiply` | std |
| `/` | `divide` | std |
| `%` | `modulo` | std |
| `==` | `equals` | std |
| `!=` | `not_equals` | std |
| `<` | `less_than` | std |
| `>` | `greater_than` | std |
| `<=` | `lte` | std |
| `>=` | `gte` | std |
| `&&` | `and` | std |
| `\|\|` | `or` | std |
| `!` | `not` | std |
| `?.` | `null_aware_access` | dart_std |
| `..` | `cascade` | dart_std |
| `...` | `spread` | dart_std |

## Metadata Preservation

Encoders must capture cosmetic information as metadata for round-trip fidelity:

- **FunctionDefinition.metadata**: `kind`, `params`, `visibility`, `is_async`, `is_static`, `annotations`, etc.
- **TypeDefinition.metadata**: `kind`, `superclass`, `interfaces`, `mixins`, `is_abstract`, `fields`, etc.
- **LetBinding.metadata**: `type`, `is_final`, `is_const`, `is_late`, `is_var`
- **Module.metadata**: `dart_imports`, `dart_exports`, platform-specific import info

## Language-Specific Modules

Language constructs that don't map to universal `std` go into language-specific modules:
- `dart_std` — Dart: cascade, null_aware_access, spread, invoke, record, switch_expr
- `cpp_std` — C++: deref, address_of, arrow, ptr_cast, cpp_new, cpp_delete, sizeof

## C++ Encoder Special: Normalizer

The C++ encoder has a normalizer phase (`cpp/encoder/src/normalizer.cpp`) that converts `cpp_std` pointer operations into either:
- **Safe projections**: variable references, field access (when pointer usage is safe)
- **Unsafe lowerings**: `std_memory` operations (when actual pointer arithmetic is needed)

## Common Mistakes

1. Not preserving enough metadata for round-trip (imports, visibility, type annotations)
2. Not handling all operator precedence correctly
3. Missing language-specific constructs (results in incomplete encoding)
4. Not building std modules from accumulated function references
5. Not handling default parameter values in function signatures
