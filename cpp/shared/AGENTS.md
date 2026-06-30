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
| `src/ball_protobuf_rt.cpp` | Protobuf runtime helpers |
| `gen/ball/v1/ball.pb.h` | **Generated — NEVER edit.** Regenerate via `buf generate`. |
| `gen/ball/v1/ball.pb.cc` | **Generated — NEVER edit.** |

## For AI Agents
- `BallMap` is `std::map<std::string, BallValue>` (ORDERED). **Never** substitute `std::unordered_map` — field insertion order is observable.
- `ball_emit_runtime.h` is slurped at CMake configure time into a `_embed.h` constant that the compiler splices into emitted programs. Edit it in-place; do not copy or inline its content elsewhere.
- Use `ball::LoadProgram(path)` / `LoadModule(path)` from `ball_file.h` — never parse a `.ball.json` directly into a `Program` proto; the `@type` envelope must be stripped first (the loader does this).
- `ball_ir.h` exists to avoid a libprotobuf dependency in lightweight tools. The self-hosted engine uses `BallDyn` (from `ball_dyn.h`), not `ball::ir`.
- `gen/` is checked in as a fallback when buf CLI is not on PATH. Regenerate with `buf generate --template cpp/buf.gen.cpp.yaml -o cpp/shared/gen proto/` from repo root.
- Reference `.claude/rules/cpp.md` for full type system details and `CLAUDE.md` for buf regeneration workflow.

## Dependencies
- Internal: generated protos in `gen/`.
- External: protobuf (`google/protobuf`), nlohmann/json (for `ball_ir.h`).
