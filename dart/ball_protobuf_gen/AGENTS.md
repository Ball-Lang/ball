<!-- Parent: ../AGENTS.md -->

# ball_protobuf_gen (`ball_protobuf_gen`)

## Purpose
Consumer-model code generator: the `protoc`/`buf` plugins that turn a user's `.proto` into typed models + service stubs bound to the `ball_protobuf` runtime. Generated models are thin typed views over a `Map<String,Object?>` + embedded resolved-Editions descriptor; all wire/JSON work delegates to `ball_protobuf` (no serialization code is generated). NOT Ball-portable.

## Key Files
| File | Description |
|------|-------------|
| `bin/protoc_gen_ball.dart` | `protoc-gen-ball` — messages/enums/extensions → `.pb.dart` |
| `bin/protoc_gen_ball_connect.dart` | `protoc-gen-ball-connect` → `.connect.dart` |
| `bin/protoc_gen_ball_grpc.dart` | `protoc-gen-ball-grpc` → `.grpc.dart` |
| `lib/src/plugin.dart` / `generator.dart` | CodeGeneratorRequest handling, codegen driver |
| `lib/src/dart_emitter.dart` / `connect_emitter.dart` / `grpc_emitter.dart` | Per-output emitters |
| `lib/src/descriptor_bridge.dart` | FileDescriptorSet → resolved Editions Map descriptors |
| `tool/gen_golden.dart` | Regenerate golden outputs for tests |

## For AI Agents
- These are plugin binaries (read CodeGeneratorRequest on stdin, write response on stdout) — invoked by `protoc`/`buf`, not directly.
- This package is **independent of** the repo's own `buf generate` bindings — do NOT wire it into root `buf.gen.yaml`. Full design + status: `docs/PROTOBUF_CODEGEN_PLAN.md`; proto rules: `.claude/rules/proto.md`.
- Dart is the shipped target; C++/TS are roadmap. `example/` holds a sample; `tool/golden_format.dart` formats golden fixtures.

## Dependencies
- Internal: `ball_base` (descriptor types), `ball_protobuf` (runtime). `ball_rpc` is dev-only (the generated `.connect.dart` import target).
- External: `dart_style` (dev, golden formatting).
