---
name: ball-compiler
description: >
  Build, modify, debug, or extend a Ball target-language compiler. USE FOR: adding new base
  function compilation, fixing expression generation, adding type emission, implementing control
  flow translation, or creating a new target language compiler. DO NOT USE FOR: engine/interpreter
  work, encoder/parser work, or proto schema changes. Always reference the Dart compiler as the
  reference implementation.
---

# Ball Compiler Skill

## What is a Ball Compiler?

A Ball compiler reads a `Program` protobuf message and generates source code for a target language. The Dart compiler (`dart/compiler/lib/compiler.dart`) is the reference implementation.

## Architecture

```
Program (protobuf)
  → Build lookup tables (types, functions by name)
  → Identify base modules (std, std_collections, std_io, dart_std)
  → Generate imports from module metadata
  → Generate types from typeDefs[] (preferred) or types[]
  → Generate functions (walk expression trees)
  → Generate entry point (main)
```

## Expression Compilation Rules

Every expression is one of 7 types. Compile recursively:

| Expression | Compilation Strategy |
|------------|---------------------|
| `literal` | Emit language literal (int, string, bool, etc.) |
| `reference` | Emit variable name; `"input"` = function parameter |
| `fieldAccess` | Compile `object`, emit `.field` |
| `messageCreation` | Compile as constructor call or struct literal |
| `call` (user function) | Emit function call with compiled input |
| `call` (base function) | Dispatch to native operator/function (see below) |
| `block` | Emit scoped block with let-bindings + result |
| `lambda` | Emit anonymous function / closure |

## Base Function Dispatch (Critical Path)

Base functions map to native operations. Extract fields from the input's `messageCreation`:

```
std.add       → left + right
std.if        → if (condition) { then } else { else }  [LAZY! Don't eval both branches]
std.for       → for (init; condition; update) { body }  [LAZY!]
std.while     → while (condition) { body }               [LAZY!]
std.print     → print(message)
std.equals    → left == right
std.index     → target[index]
std.assign    → target = value
```

## Adding a New Base Function

1. Define the function in `dart/shared/lib/std.dart` (or relevant module)
2. Run `dart run bin/gen_std.dart` to regenerate std.json/std.bin
3. Add compilation logic in the compiler's base function dispatcher
4. Add interpretation logic in the engine's std dispatcher
5. Add test in `dart/engine/test/engine_test.dart`
6. If C++: implement in both `cpp/compiler/` AND `cpp/engine/`

## Control Flow — MUST Use Lazy Evaluation

`std.if`, `std.for`, `std.while`, `std.try`, `std.switch` inputs contain Expression trees.
Do NOT compile them as regular function calls — extract fields and emit native control flow:

```
// WRONG: std.if compiled as function call
std_if(condition_result, then_result, else_result)  // evaluates everything!

// RIGHT: std.if compiled as native control flow
if (compile(condition)) { compile(then) } else { compile(else) }
```

## Type Emission Reference

Read `metadata.kind` on TypeDefinition to determine what to emit:

| kind | Dart | C++ | Python | TypeScript |
|------|------|-----|--------|------------|
| class | `class Foo` | `class Foo` | `class Foo` | `class Foo` |
| struct | N/A | `struct Foo` | `@dataclass` | `interface Foo` |
| enum | `enum Foo` | `enum class Foo` | `class Foo(Enum)` | `enum Foo` |
| mixin | `mixin Foo` | N/A | mixin class | N/A |
| extension | `extension on T` | N/A | N/A | N/A |

## Common Mistakes

1. Evaluating control flow eagerly (see above)
2. Forgetting that `module: ""` means current module
3. Not handling lambda (FunctionDefinition with name = "")
4. Not extracting fields from MessageCreation for base function inputs
5. Ignoring metadata — cosmetic but critical for output quality
