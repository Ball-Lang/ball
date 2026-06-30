<!-- Parent: ../AGENTS.md -->

# ball_protobuf (`ball_protobuf`)

## Purpose
Pure-Dart, descriptor-driven Protocol Buffers runtime: wire codecs, binary marshal/unmarshal, proto3-JSON, well-known types, gRPC framing — and the full protobuf **Editions** feature-resolution model. Authored in Ball-portable Dart so it encodes to a Ball library and runs on every target; zero package deps.

## Key Files
| File | Description |
|------|-------------|
| `lib/ball_protobuf.dart` | Public library entry |
| `lib/marshal.dart` / `unmarshal.dart` | Binary serialize / deserialize (feature-aware) |
| `lib/json_codec.dart` | proto3-JSON codec |
| `lib/edition.dart` / `editions.dart` | FeatureSet model + protoc resolution algorithm |
| `lib/wire_*.dart` / `field_*.dart` | Wire-format primitives, per-type field codecs |
| `lib/well_known.dart` | Well-known types |
| `lib/grpc_frame.dart` / `service.dart` | gRPC length-prefixed framing, service model |
| `tool/conformance_main.dart` | Upstream conformance runner entry (POSIX-only) |
| `tool/editions_conformance.dart` | Legacy↔editions parity harness (CI step) |

## For AI Agents
- This code is **Ball-portable** — it gets encoded and run on the Dart/TS/C++ engines. Heed the syntactic-encoder gotchas in `.claude/rules/dart.md` (e.g. `addAll`, `.keys`, constructor-vs-call). When in doubt diff the encoded program.
- Compiled artifact `dart/shared/ball_protobuf.{json,bin}` is generated via `cd dart/encoder && dart run bin/gen_ball_protobuf.dart` — never hand-edit.
- Editions defaults are golden-tested against `tests/editions/featureset_defaults.binpb`. Spec: `docs/EDITIONS_SPEC.md`; proto rules: `.claude/rules/proto.md`.
- Upstream conformance is POSIX-only (Linux/macOS/WSL) — see `conformance/README.md`.

## Dependencies
- Internal: none at runtime (`ball_base` is dev-only, for tests). Re-exported by `ball_base`.
- External: none — `dart:core`/`convert`/`typed_data` only.
