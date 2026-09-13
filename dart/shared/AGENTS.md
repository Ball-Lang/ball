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
- **The audit's known surface is what `buildCapabilityTable()` MODELS, not a
  list of module names.** A base function a program declares that the table does
  not model is the host-extension seam (`BallModuleHandler`) — the audit cannot
  know what it does, so every call into one is classified `custom` (risk
  `unknown`, never `pure`, summary escalated to `REVIEW REQUIRED`, `--deny
  custom` enforceable) and the termination analyzer emits an
  `unknown_termination` info naming it (issues #609, #683). Classification keys
  on the DECLARATION, never on the spoofable `call.module` string — see
  `_collectCustomBaseFns`. **It also resolves by function IDENTITY, not by
  the call-site module**: the engine's own `_resolveAndCallFunction` falls back
  to a bare-name scan across every module when the exact `<module>.<function>`
  key misses, so an unqualified call (`call.module` empty) or one naming a
  benign-looking module reaches the very same host handler and must audit the
  same way — `_resolveCustomBaseFn` does exact-first, then bare-name, the
  sibling of #402's `lookupCapabilityByName`. Both directions fail closed: an
  undeclared name stays an ordinary user call, and a bare name a non-base user
  function also declares is never resolved (the engine refuses to dispatch that
  case at all — the #420 `sawBase && sawUser` guard throws). When the resolution
  differs from the call site, the DECLARING module leads in the report and the
  `--deny` violation (`mymodule.exec_shell (call site: main.exec_shell)`) and is
  carried in `ball.v1.CallSite.resolved_module` for `--output` JSON. #609 keyed it on the module NAME instead, which let a
  program-supplied module *squatting* a std name (a module called `std`
  declaring `exec_shell`) read as pure; #683 closed that. The #402 bare-name
  resolution stays scoped to the eight std module names, because the corpus
  labels real base functions loosely (`std.list_push` for
  `std_collections.list_push`) while a host module declaring `mutex_create` must
  NOT be blessed by the same coincidence.
- **The table is a CLOSED SET, gated on every PR.**
  `test/capability_table_closed_set_test.dart` asserts (a) every base function
  the eight `buildStd*Module()` builders declare is keyed, (b) every base
  function an executed conformance fixture declares resolves, and (c)
  `ball.proto`'s `CapabilityEntry` doc comment enumerates exactly the categories
  and risk levels the analyzer emits. Adding a std base function without a
  capability now fails CI. If you cannot state what a new base function does,
  leave it OUT of the table — `custom`/`unknown` is the honest classification,
  and a guessed `pure` is the #609 bug.
- **`Summary:` precedence is pinned (#682).** `REVIEW REQUIRED — calls into
  custom base modules` outranks `HIGH RISK`: an unbounded effect outranks a
  ranked one. The full arm order and the consumer contract (never grep the
  summary for `HIGH RISK`; use `--deny` or `capabilities[]`) are in
  `formatCapabilityReport`'s doc comment.
- Core invariants: `../../CLAUDE.md`; Dart patterns: `.claude/rules/dart.md`.

## Dependencies
- Internal: `ball_protobuf` (re-exported).
- External: `protobuf`, `fixnum`.
