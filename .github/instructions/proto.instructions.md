---
applyTo: "proto/**"
---

# Proto Schema Instructions

## Ball Proto Schema

The canonical language definition lives at `proto/ball/v1/ball.proto`.

### Editing Rules

1. Run `buf lint` before committing ANY proto changes
2. Run `buf breaking --against ".git#subdir=proto"` to check backward compatibility
3. After editing, run `buf generate` to regenerate ALL language bindings
4. The proto file is the SINGLE SOURCE OF TRUTH for the Ball language structure
5. All message types, fields, and enums must be documented with comments

### Message Types

Core messages: `Program`, `Module`, `FunctionDefinition`, `Expression`, `TypeDefinition`
Expression variants: `FunctionCall`, `Literal`, `Reference`, `FieldAccess`, `MessageCreation`, `Block`
Support messages: `Statement`, `LetBinding`, `FieldValuePair`, `ListLiteral`
Module system: `ModuleImport`, `HttpSource`, `FileSource`, `InlineSource`, `GitSource`
Type system: `TypeParameter`, `TypeAlias`, `Constant`, `ModuleAsset`

### Design Constraints

- **Semantic** content: expression tree, function signatures, type descriptors, module structure
- **Cosmetic** content: everything in `google.protobuf.Struct metadata` fields
- Adding new Expression variants requires updating ALL compilers and engines
- Adding new metadata keys only requires updating documentation (METADATA_SPEC.md)

### Code Generation

`buf.gen.yaml` generates bindings for: Dart, Go, Python, TypeScript, C++, Java, C#
Output directories are language-specific (e.g., `dart/shared/lib/gen/`, `cpp/shared/gen/`)
