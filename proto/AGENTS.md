<!-- Parent: ../AGENTS.md -->

# Proto Schema Agents

`proto/ball/v1/ball.proto` is the **single source of truth** for the Ball language. All implementations deserialize from this schema.

The Core Invariants (one input/output, cosmetic metadata, bodiless base functions, lazy control flow, never edit generated files) are defined once in CLAUDE.md → Core Invariants — Never Violate. This file covers only the proto-specific consequences of those invariants.

## Semantic vs Cosmetic

- **Semantic** content lives in the schema: the expression tree, function signatures (input/output type), type descriptors, and module structure. Changing it changes what a program computes.
- **Cosmetic** content lives in `google.protobuf.Struct metadata` fields: visibility, mutability, syntax sugar, import URIs, annotations. Stripping all metadata must not change what a program computes.
- 7 expression variants (the `Expression` oneof): `call`, `literal`, `reference`, `fieldAccess`, `messageCreation`, `block`, `lambda`.

## Buf Configuration

| File | Purpose |
|------|---------|
| `proto/buf.yaml` | Module `buf.build/ball-lang/ball`, STANDARD lint, FILE breaking |
| `buf.gen.yaml` | Multi-language codegen (Dart, Go, Python, TS, Java, C++, C#) |
| `cpp/buf.gen.cpp.yaml` | C++-only generation template |

## When Editing the Schema

1. Edit `proto/ball/v1/ball.proto`
2. Run `buf lint` — must pass
3. Run `buf generate` — regenerates ALL language bindings
4. NEVER edit generated files (`*/shared/gen/`)
5. After schema changes, update all implementations (Dart compiler/engine first, then C++, then TS)
6. Update `docs/METADATA_SPEC.md` if new metadata keys are introduced

## Backward Compatibility

- Version: `v1` package in proto namespace
- Breaking changes use `FILE` detection in `buf.yaml`
- Always prefer additive changes (new fields, new messages) over modifying existing fields
- Reserved field numbers for removed fields
