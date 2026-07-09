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

The lists below are a non-exhaustive orientation aid — `proto/ball/v1/ball.proto`
is the authoritative, machine-checked catalog. When in doubt, read the proto
(grep its `message`/`oneof` declarations) rather than trusting this prose, which
can drift.

Core messages: `Program`, `Module`, `FunctionDefinition`, `Expression`, `TypeDefinition`
Expression variants (the 7 `oneof expr` arms): `FunctionCall`, `Literal`, `Reference`,
`FieldAccess`, `MessageCreation`, `Block`, `lambda` (a `FunctionDefinition` with empty name)
Support messages: `Statement`, `LetBinding`, `FieldValuePair`, `ListLiteral`, `TypeRef`
Module system (`oneof source` arms): `ModuleImport`, `HttpSource`, `FileSource`,
`InlineSource`, `GitSource`, `RegistrySource`
Type system: `TypeParameter`, `TypeAlias`, `Constant`, `ModuleAsset`

### Design Constraints

- **Semantic** content: expression tree, function signatures, type descriptors, module structure
- **Cosmetic** content: everything in `google.protobuf.Struct metadata` fields
- Adding new Expression variants requires updating ALL compilers and engines
- Adding new metadata keys only requires updating documentation (METADATA_SPEC.md)

### Code Generation

`buf.gen.yaml` generates bindings for: Dart, Go, Python, TypeScript, C++, Java, C#
Output directories are language-specific (e.g., `dart/shared/lib/gen/`, `ts/shared/gen/`). The C++ target has no generated bindings — it is libprotobuf-free (#18 Stage 5)

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
- `dart/ball_protobuf/conformance/README.md` — how-to + scope. There is no
  tolerated-failure list: every registered conformance test must pass.
- `tests/editions/descriptors/test_messages.fds.binpb` — the checked-in
  descriptor set; regenerate with `tools/gen_conformance_descriptors.{sh,ps1}`
  (pin protoc to a version supporting edition 2023; `--check`/`-Check` drift).

The runner is **POSIX-only** (`fork`/pipes) — build/run it on Linux/macOS/WSL,
not native Windows. CI: job *Upstream Conformance (Editions)* in `ci.yml`.
Text-format tests and unregistered message types are reported `skipped`. There
is no tolerated-failure list — the runner exits non-zero on ANY conformance
failure, so every registered test must pass.

## Consumer codegen (`ball_protobuf_gen` + `ball_rpc`)

Two Dart packages turn a *user's* `.proto` into typed models + service stubs
bound to the `ball_protobuf` runtime (this is **separate** from Ball's own
`buf generate` bindings — do NOT wire it into the root `buf.gen.yaml`, which the
"Proto Checks" CI job guards):

- `dart/ball_protobuf_gen` — the protoc/buf plugins `protoc-gen-ball`
  (messages/enums/extensions → `.pb.dart`), `protoc-gen-ball-connect`
  (`.connect.dart`), `protoc-gen-ball-grpc` (`.grpc.dart`). The descriptor bridge
  lives here now (it imports `ball_base`, so it is not Ball-portable);
  `ball_protobuf/tool/` keeps its own conformance copy.
- `dart/ball_rpc` — the Dart-target transport runtime (Connect / gRPC /
  Fake transports + the shared `RpcCode`/`RpcException` model) generated clients
  delegate to.

**Dart is the shipped target; C++/TS library targets are roadmap.** Full design
+ verified multi-target findings: `docs/PROTOBUF_CODEGEN_PLAN.md`.
