<!-- Parent: ../AGENTS.md -->

# shared (`ball_base`)

## Purpose
Cross-language foundation: protobuf-generated Ball types, the universal std module builders, capability/termination analysis, and a re-export of the `ball_protobuf` runtime. Dependency of every other Dart package.

## Key Files
| File | Description |
|------|-------------|
| `lib/ball_base.dart` | Public library; re-exports gen types + `ball_protobuf` |
| `lib/std.dart` | Universal `std` module builder (~118 base fns) |
| `lib/std_collections.dart` / `std_memory.dart` / `std_io.dart` / `std_convert.dart` / `std_fs.dart` / `std_time.dart` / `std_concurrency.dart` | Per-domain std module builders |
| `lib/capability_analyzer.dart` / `capability_table.dart` | Capability (permissions) analysis |
| `lib/termination_analyzer.dart` | Static termination checks |
| `lib/ball_file.dart` | `Any`-envelope Ball file wrap/unwrap helpers |
| `bin/gen_std.dart` | Regenerates `std.json` + `std.bin` from `std.dart` |
| `bin/gen_ball_proto.dart` | Regenerates `ball_proto.{json,bin}` |

## For AI Agents
- Entry: edit `std.dart` (or a `std_*.dart`) then run `dart run bin/gen_std.dart` from this dir.
- **NEVER edit generated files:** `lib/gen/**` (protobuf), `std.json`, `std.bin`, `ball_proto.{json,bin}`, `ball_protobuf.{json,bin}` — these are build outputs (regen commands in `../../CLAUDE.md`).
- Lang-specific std modules are banned: all functions route through universal `std` (no `dart_std`).
- Core invariants: `../../CLAUDE.md`; Dart patterns: `.claude/rules/dart.md`.

## Dependencies
- Internal: `ball_protobuf` (re-exported).
- External: `protobuf`, `fixnum`.
