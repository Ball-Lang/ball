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
| `ball_protobuf_rt.h` | **Generated — regenerate, don't hand-edit.** Ball's own `ball_protobuf` runtime, compiled Ball→C++ in `--library` mode (header-only, self-contained: only `<std>` headers, NO libprotobuf/abseil/nlohmann). Regenerate via `dart/compiler/tool/compile_ball_protobuf_cpp.dart`, or directly: `ball_cpp_compile dart/shared/ball_protobuf.json --library --ns ball_protobuf --out cpp/shared/ball_protobuf_rt.h`. |
| `ball_protobuf_rt_smoke.cpp` | Hand-written smoke driver: `#include`s `ball_protobuf_rt.h` and round-trips real values through `encodeVarint`/`decodeVarint`, `encodeZigZag64`/`decodeZigZag`, and `encodeFixed32`/`decodeFixed32`. Built only behind `-DBALL_BUILD_PROTOBUF_RT=ON` (the #18 canary — see below). |
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
- `ball_protobuf_rt.h` (+ `ball_protobuf_rt_smoke.cpp`) builds behind
  `-DBALL_BUILD_PROTOBUF_RT=ON` as the standalone, dependency-free proof target
  `ball_protobuf_rt_smoke` (CTest `protobuf_rt_smoke`). CI enables the flag on
  Linux so the Ball-compiled runtime is guarded against silent rot. The smoke
  driver actually **calls** the compiled codecs (varint/zigzag/fixed32
  round-trips), not just compiles them, and links nothing else — proving the
  runtime stands alone AND works.
  - Note: the file checked in before this fix was generated (June 2026, commit
    `98e5664`) predates the C++ compiler's `--library` mode (added a few days
    later in `29e3d4b`), so it silently fell back to a Program-wrapping path
    that dead-code-eliminated all 213 `ball_protobuf` functions down to an
    empty `main()` — the "canary" compiled but proved nothing. Regenerating
    with the now-available `--library` mode produces the real ~9k-line header
    with all functions present; verified via a manual varint round-trip
    (`encodeVarint(buf, 300)` → `decodeVarint` → `{value: 300, bytesRead: 2}`)
    before wiring it into the smoke target.

**Deferred (full cutover):**
- The compiler (`compiler/`) and encoder (`encoder/`) still consume the
  generated `ball::v1::` protobuf types throughout their ~600 KB emission code
  (accessor calls like `.functions()`, `.has_body()`). Migrating them to the
  `ball::ir` field-access shape (and swapping `main.cpp`'s `ball_file.h`
  `DecodeProgram` for `ball::ir::parseProgramString`) is the remaining work.
  Only after that can `target_link_libraries(ball_shared … protobuf::libprotobuf)`
  and the FetchContent block above be removed. The binary `.ball.pb`/`.ball.bin`
  path (Google `Any` wire decode in `ball_file.h`) also needs a protobuf-free
  replacement (candidate: `ball_protobuf_rt.h`'s wire codecs) before the pin
  drops.

## Dependencies
- Internal: generated protos in `gen/`.
- External: protobuf (`google/protobuf`), nlohmann/json (for `ball_ir.h`).
