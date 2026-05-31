---
paths:
  - "proto/**"
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

## Wire-format conformance (upstream protobuf suite)

`ball_protobuf`'s codecs are validated against the **official protobuf
`conformance_test_runner`** (not just our own round-trips), covering the proto2,
proto3, and edition2023 `TestAllTypes` messages — all 2769 registered tests pass
(WKT incl. Any, oneof, message merge, unknown-field retention, full proto3-JSON
rules); the failure list is empty. Layout:

- `dart/ball_protobuf/tool/descriptor_bridge.dart` — turns a protoc
  `FileDescriptorSet` into our Map-based field descriptors, resolving each
  field's Editions `FeatureSet` and folding `extend` blocks into their extendee
  (extensions keyed by `[fully.qualified.name]` to avoid aliasing a sibling
  field's simple name).
- `dart/ball_protobuf/tool/conformance_main.dart` + `lib/conformance.dart` — the
  size-prefixed stdin/stdout request loop the runner drives. **The loop awaits
  each stdout flush** — an un-awaited flush in the synchronous read loop crashes
  the process after one response.
- `dart/ball_protobuf/conformance/{failure_list_ball.txt,README.md}` — expected
  failures (currently empty) + how-to.
- `tests/editions/descriptors/test_messages.fds.binpb` — the checked-in
  descriptor set; regenerate with `tools/gen_conformance_descriptors.{sh,ps1}`
  (pin protoc to a version supporting edition 2023; `--check`/`-Check` drift).

The runner is **POSIX-only** (`fork`/pipes) — build/run it on Linux/macOS/WSL,
not native Windows. CI: job *Upstream Conformance (Editions)* in `ci.yml`.
Text-format tests and unregistered message types are reported `skipped`. When a
codec change moves the numbers, regenerate `conformance/failure_list_ball.txt`
(bare test names, reasons stripped) — see that file's header.
