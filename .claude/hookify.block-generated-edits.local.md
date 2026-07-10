---
name: block-generated-edits
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: (dart[/\\]shared[/\\]lib[/\\]gen[/\\]|cpp[/\\]shared[/\\]gen[/\\]|ts[/\\]shared[/\\]gen[/\\]|rust[/\\]shared[/\\]gen[/\\]|compiled_engine\.(ts|rs)$|engine_rt\.cpp$|ball_protobuf_rt\.(h|cpp)$|ball_program_descriptor\.h$|_embed\.h$|dart[/\\]shared[/\\](std|ball_proto|ball_protobuf)\.(json|bin)$)
action: block
---

⛔ **This file is GENERATED — never hand-edit it** (Ball core invariant #5).

Regenerate instead:
- `dart/shared/lib/gen/**`, `cpp/shared/gen/**`, `ts/shared/gen/**`, `rust/shared/gen/**` → `buf generate`
- `dart/shared/std.json|std.bin` → `cd dart/shared && dart run bin/gen_std.dart`
- `dart/shared/ball_proto.*` / `ball_protobuf.*` → their `gen_*` tools (see CLAUDE.md Build & Test)
- `ts/engine/src/compiled_engine.ts` / `rust/engine/src/compiled_engine.rs` / `dart/self_host/lib/engine_rt.cpp` → the self-host regen commands in CLAUDE.md
- `cpp/shared/ball_protobuf_rt.*` / `ball_program_descriptor.h` / `*_embed.h` → their generator tools (see cpp/shared/AGENTS.md)

If the generated output is wrong, fix the *generator or source* and regenerate.
