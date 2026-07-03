<!-- Parent: ../AGENTS.md -->

# cpp/shared

## Purpose
The `ball_shared` CMake library — common types, runtime helpers, and generated protobuf bindings used by every C++ Ball tool (compiler, encoder, test harness, self-hosted engine).

## Key Files
| File | Description |
|------|-------------|
| `include/ball_shared.h` | Umbrella header: `BallValue`/`BallList`/`BallMap`/`BallFunction` type aliases, std module builders, pulls in `ball_emit_runtime.h` and generated protos |
| `include/ball_emit_runtime.h` | Runtime helpers (exception type, `ball_to_string`, `std_time` helpers) embedded verbatim into every compiler-emitted program — single source of truth for both interpreter and emitted code |
| `include/ball_file.h` | Header-only `ball::LoadProgram` / `LoadModule` / `DecodeProgram`; reads `.ball.json` / `.ball.bin` / `.ball.pb` `google.protobuf.Any` envelopes |
| `include/ball_ir.h` | Protobuf-free IR (`ball::ir` namespace) loaded via nlohmann/json; supports both camelCase and snake_case field names |
| `include/ball_dyn.h` | Dynamic value helpers used by the self-hosted engine harness |
| `include/ball_ordered_map.h` / `ball_ordered_map_impl.h` | Ordered-map interface and implementation |
| `src/ball_shared.cpp` | `ball_shared` implementation (std module builders) |
| `ball_protobuf_rt.cpp` | Ball's own `ball_protobuf` runtime, compiled Ball→C++ (self-contained: only `<std>` headers, NO libprotobuf/abseil/nlohmann). Regenerate via `dart/compiler/tool/compile_ball_protobuf_cpp.dart`. Built only behind `-DBALL_BUILD_PROTOBUF_RT=ON` (the #18 canary — see below). |
| `gen/ball/v1/ball.pb.h` | **Generated — NEVER edit.** Regenerate via `buf generate`. |
| `gen/ball/v1/ball.pb.cc` | **Generated — NEVER edit.** |

## For AI Agents
- `BallMap` is `std::map<std::string, BallValue>` (ORDERED). **Never** substitute `std::unordered_map` — field insertion order is observable.
- `ball_emit_runtime.h` is slurped at CMake configure time into a `_embed.h` constant that the compiler splices into emitted programs. Edit it in-place; do not copy or inline its content elsewhere.
- Use `ball::LoadProgram(path)` / `LoadModule(path)` from `ball_file.h` — never parse a `.ball.json` directly into a `Program` proto; the `@type` envelope must be stripped first (the loader does this).
- `ball_ir.h` exists to avoid a libprotobuf dependency in lightweight tools. The self-hosted engine uses `BallDyn` (from `ball_dyn.h`), not `ball::ir`.
- `gen/` is checked in as a fallback when buf CLI is not on PATH. Regenerate with `buf generate --template cpp/buf.gen.cpp.yaml -o cpp/shared/gen proto/` from repo root.
- Reference `.claude/rules/cpp.md` for full type system details and `CLAUDE.md` for buf regeneration workflow.

## #18/#25 — dropping Google protobuf (status)
Goal: replace the FetchContent Google protobuf (v34.1, ~90% of C++ build time,
abseil-mutex deadlock #25) with Ball's own runtime + nlohmann/json for Ball-IR
loading.

**Landed:**
- `include/ball_ir.h` — protobuf-free IR + proto3-JSON loader (nlohmann only).
  `test_ball_ir` (CTest `ball_ir_loader`) parses the WHOLE conformance corpus
  through it with zero libprotobuf. This is the real replacement for JSON IR
  loading.
- `ball_protobuf_rt.cpp` builds behind `-DBALL_BUILD_PROTOBUF_RT=ON` as the
  standalone, dependency-free proof target `ball_protobuf_rt_smoke` (CTest
  `protobuf_rt_smoke`). CI enables the flag so the Ball-compiled runtime is
  guarded against silent rot. It links nothing — proving it stands alone.

**Deferred (full cutover):**
- The compiler (`compiler/`) and encoder (`encoder/`) still consume the
  generated `ball::v1::` protobuf types throughout their ~600 KB emission code
  (accessor calls like `.functions()`, `.has_body()`). Migrating them to the
  `ball::ir` field-access shape (and swapping `main.cpp`'s `ball_file.h`
  `DecodeProgram` for `ball::ir::parseProgramString`) is the remaining work.
  Only after that can `target_link_libraries(ball_shared … protobuf::libprotobuf)`
  and the FetchContent block above be removed. The binary `.ball.pb`/`.ball.bin`
  path (Google `Any` wire decode in `ball_file.h`) also needs a protobuf-free
  replacement (candidate: `ball_protobuf_rt.cpp`'s wire codecs) before the pin
  drops.

## Dependencies
- Internal: generated protos in `gen/`.
- External: protobuf (`google/protobuf`), nlohmann/json (for `ball_ir.h`).
