<!-- Parent: ../AGENTS.md -->

# cpp/shared

## Purpose
The `ball_shared` CMake library — common types, runtime helpers, the protobuf-free `ball::ir` loader, and Ball's own compiled protobuf runtime, used by every C++ Ball tool (compiler, encoder, test harness, self-hosted engine). **libprotobuf-free** (#18 Stage 5).

## Key Files
| File | Description |
|------|-------------|
| `include/ball_shared.h` | Umbrella header: `BallValue`/`BallList`/`BallMap`/`BallFunction` type aliases, std module builders (return `ball::ir::Module`), pulls in `ball_emit_runtime.h` + `ball_ir.h` (nlohmann) — no libprotobuf |
| `include/ball_emit_runtime.h` | Runtime helpers (exception type, `ball_to_string`, `std_time` helpers) embedded verbatim into every compiler-emitted program — single source of truth for both interpreter and emitted code |
| `include/ball_file.h` | Header-only `ball::LoadProgram` / `LoadModule` / `DecodeProgram`; reads `.ball.json` / `.ball.bin` / `.ball.pb` `google.protobuf.Any` envelopes. **Returns `ball::ir` — libprotobuf-free** (#18 Stage 5): JSON via nlohmann, binary via `ball_rt_decode.cpp` |
| `ball_rt_decode.{h,cpp}` | The sole binary `.ball.pb`/`.ball.bin` decoder. Confines Ball's compiled protobuf runtime (`ball_protobuf_rt.h` + `ball_program_descriptor.h`, a second global `BallDyn` universe) to ONE TU; `DecodeAnyPayloadJson` unmarshals the Any + payload and serialises to proto3-JSON for `ball::ir` |
| `include/ball_ir.h` | Protobuf-free IR (`ball::ir` namespace) loaded via nlohmann/json; supports both camelCase and snake_case field names on read, and serializes back to proto3-JSON (camelCase, canonical) via `toJson`/`programToJsonString` |
| `include/ball_dyn.h` | Dynamic value helpers used by the self-hosted engine harness |
| `include/ball_ordered_map.h` / `ball_ordered_map_impl.h` | Ordered-map interface and implementation |
| `src/ball_shared.cpp` | `ball_shared` implementation (std module builders) |
| `ball_protobuf_rt.h` | **Generated — regenerate, don't hand-edit.** Ball's own `ball_protobuf` runtime, compiled Ball→C++ in `--library` mode (header-only, self-contained: only `<std>` headers, NO libprotobuf/abseil/nlohmann). Regenerate via `dart/compiler/tool/compile_ball_protobuf_cpp.dart`, or directly: `ball_cpp_compile dart/shared/ball_protobuf.json --library --ns ball_protobuf --out cpp/shared/ball_protobuf_rt.h`. |
| `ball_protobuf_rt_smoke.cpp` | Hand-written smoke driver: `#include`s `ball_protobuf_rt.h` and round-trips real values through `encodeVarint`/`decodeVarint`, `encodeZigZag64`/`decodeZigZag`, `encodeFixed32`/`decodeFixed32`, AND a full descriptor-driven `marshal`→`unmarshal` round-trip on a nested message (int32 + string + sub-message). Built only behind `-DBALL_BUILD_PROTOBUF_RT=ON` (the #18 canary — see below). |

## For AI Agents
- `BallMap` is `std::map<std::string, BallValue>` (ORDERED). **Never** substitute `std::unordered_map` — field insertion order is observable.
- `ball_emit_runtime.h` is slurped at CMake configure time into a `_embed.h` constant that the compiler splices into emitted programs. Edit it in-place; do not copy or inline its content elsewhere.
- Use `ball::LoadProgram(path)` / `LoadModule(path)` from `ball_file.h` — never parse a `.ball.json` directly into a `Program` proto; the `@type` envelope must be stripped first (the loader does this).
- `ball_ir.h` exists to avoid a libprotobuf dependency in lightweight tools. The self-hosted engine uses `BallDyn` (from `ball_dyn.h`), not `ball::ir`.
- **No libprotobuf.** The C++ build is protobuf-free (#18 Stage 5): there is no `gen/ball.pb.*`, no FetchContent protobuf, and no `google.protobuf` in any TU. Ball programs load via `ball::ir` (nlohmann/json) + `ball_rt_decode.cpp` (Ball's own compiled runtime).
- Reference `.claude/rules/cpp.md` for full type system details and `CLAUDE.md` for buf regeneration workflow.

## #18 — Google protobuf DROPPED (Stage 5 complete — closes #18/#25/#330/#333)
The C++ build no longer FetchContents Google's libprotobuf/abseil. That block
was ~90% of C++ build time and carried the abseil-mutex deadlock (#25) and the
gencode↔runtime version skew that broke buf-less local builds (#330/#333).
Measured on this box (WSL g++ 14.2, cold): clean configure **985s → 58s**, and
the former libprotobuf build (~249s) is gone entirely.

**How ball files load now (libprotobuf-free, end to end):**
- **JSON `.ball.json`** → `ball_file.h` extracts the `@type` with its own
  google-free scanner, then `ball::ir::parseProgram`/`parseModule` (nlohmann)
  materialise a protobuf-free `ball::ir::Program`/`Module`.
- **Binary `.ball.pb`/`.ball.bin`** → `ball_file.h` calls
  `ball::rt::DecodeAnyPayloadJson` (`ball_rt_decode.cpp`), which unmarshals the
  `google.protobuf.Any` + payload with Ball's OWN compiled protobuf runtime
  (`ball_protobuf_rt.h`, descriptors from `ball_program_descriptor.h`) and
  serialises to proto3-JSON via `marshalJson` → `ball::ir`. The full semantic
  tree round-trips exactly; the opaque `google.protobuf.*` payloads (Struct
  metadata, DescriptorProto/EnumDescriptorProto) are TYPE_BYTES passthroughs in
  the runtime descriptor, so `marshalJson` emits them as base64 and `ball_file.h`
  strips those cosmetic remnants (metadata is cosmetic per Core Invariant 2, and
  proto3-JSON — not the binary form — is the canonical full-fidelity input).
- `ball_shared`'s std-module builders return `ball::ir::Module` (descriptors as
  proto3-JSON), and the Struct↔BallMap helpers operate on `nlohmann::json`.
- The self-host conformance harness parses fixtures straight into the engine's
  `BallDyn` map tree with a nlohmann converter (`program_json_to_any`) that
  reproduces the exact tree the old google-reflection path built.

**Tests:** `test_shared` / `test_ball_file` / `test_compiler` / `test_e2e` /
`test_snapshot` / `test_selfhost_conformance` are all protobuf-free.
`test_ball_ir_descriptor` retired its google oracle for GOLDEN proto3-JSON
assertions; the corpus-wide byte-equivalence harness (`test_ball_rt_equivalence`)
retired WITH the google path (its purpose WAS the google comparison) — the rt
binary path's regression value survives as golden Any-wire vectors in
`test_ball_file`.

**Carve-out — upstream protobuf conformance (opt-in):** the Dart `ball_protobuf`
package's upstream-conformance harness still drives Ball's codecs through the
REAL protobuf `conformance_test_runner`. Building that one binary needs a
protobuf source, so it is FetchContent'd ONLY behind the default-OFF
`BALL_BUILD_UPSTREAM_CONFORMANCE` option (`cpp/CMakeLists.txt`); the
`editions-conformance-upstream` CI job enables it. It tests
ball_protobuf-the-Dart-package, not the C++ ball target.

## #18 canary (`ball_protobuf_rt.h`)
`ball_protobuf_rt.h` (+ `ball_protobuf_rt_smoke.cpp`) still builds standalone
behind `-DBALL_BUILD_PROTOBUF_RT=ON` as the dependency-free proof target
`ball_protobuf_rt_smoke` (CTest `protobuf_rt_smoke`, CI-enabled on Linux). It is
ALSO now compiled unconditionally as part of `ball_shared` (via
`ball_rt_decode.cpp`), since it is the real binary decoder.

## Dependencies
- External: **nlohmann/json only** (`ball_ir.h`, `ball_file.h`, `ball_shared`).
  No libprotobuf / abseil (#18 Stage 5). The opt-in
  `BALL_BUILD_UPSTREAM_CONFORMANCE` option FetchContents protobuf solely to build
  the upstream `conformance_test_runner` for the Dart ball_protobuf harness.
