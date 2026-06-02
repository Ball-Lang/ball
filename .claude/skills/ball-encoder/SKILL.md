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
  → Collect base function references (std, std_collections, etc.)
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
| `?.` | `null_aware_access` | std |
| `..` | `cascade` | std |
| `...` | `spread` | std |

## Metadata Preservation

Encoders must capture cosmetic information as metadata for round-trip fidelity:

- **FunctionDefinition.metadata**: `kind`, `params`, `visibility`, `is_async`, `is_static`, `annotations`, etc.
- **TypeDefinition.metadata**: `kind`, `superclass`, `interfaces`, `mixins`, `is_abstract`, `fields`, etc.
- **LetBinding.metadata**: `type`, `is_final`, `is_const`, `is_late`, `is_var`
- **Module.metadata**: `dart_imports`, `dart_exports`, platform-specific import info

## Universal Module Architecture

All language constructs route through universal modules (`std`, `std_collections`, `std_io`,
`std_memory`). Language-specific base modules (`dart_std`, `cpp_std`) have been eliminated.

Encoders expand language-specific constructs into universal `std` operations at encoding time:
- Dart cascade (`..`) encodes as `std.cascade` (block expansion with target variable)
- Dart null-aware access (`?.`) encodes as `std.null_aware_access` (conditional with null check)
- Dart spread (`...`) encodes as `std.spread`
- C++ pointer/reference ops inline into `std`/`std_memory` calls (field access, `std.as` for casts)

## Creating a New Encoder for a New Language

If you're building a Ball encoder for an entirely new source language (not modifying Dart/C++),
follow the **new-ball-language** skill (`.claude/skills/new-ball-language/SKILL.md`), Phase 3.
That playbook covers parser selection, AST mapping strategy, language-specific module creation,
and round-trip testing. This skill focuses on the encoding internals once you're ready to
implement.

## Common Mistakes

1. Not preserving enough metadata for round-trip (imports, visibility, type annotations)
2. Not handling all operator precedence correctly
3. Missing language-specific constructs (results in incomplete encoding)
4. Not building std modules from accumulated function references
5. Not handling default parameter values in function signatures
