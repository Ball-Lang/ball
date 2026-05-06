# Proto Schema Agents

**Generated:** 2026-05-05 | **Commit:** e9d2668 | **Branch:** main

`proto/ball/v1/ball.proto` is the **single source of truth** for the Ball language. All implementations deserialize from this schema.

## Schema Rules

- One input, one output per function (gRPC-style)
- Base functions have no body — implementation is per-platform
- Control flow (`if`, `for`, `while`, `for_each`) is lazy: implemented as base function calls with lazy-evaluated bodies
- Metadata fields are **cosmetic** — stripping all metadata must not change what a program computes
- 7 expression types: `call`, `literal`, `reference`, `fieldAccess`, `messageCreation`, `block`, `lambda`

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
