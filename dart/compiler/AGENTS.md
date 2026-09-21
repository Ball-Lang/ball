<!-- Parent: ../AGENTS.md -->

# compiler (`ball_compiler`)

## Purpose
Ball → Dart code generator. Translates a Ball `Program` (protobuf expression tree) into formatted Dart source, with multi-module package compilation.

## Key Files
| File | Description |
|------|-------------|
| `lib/compiler.dart` | `DartCompiler.compile(Program)` → formatted Dart source |
| `lib/package_compiler.dart` | `PackageCompiler` — multi-module Program → Dart package |
| `lib/ball_compiler.dart` | Public library; re-exports compiler + encoder + engine facade |
| `bin/compile_ts.dart` | Helper that drives the TS compiler from Dart |
| `tool/gen_engine_json.dart` | Regenerate self-hosted engine JSON from the Dart engine |
| `tool/compile_engine_cpp.dart` | Compile self-hosted engine to C++ (`dart/self_host/`) |
| `tool/compile_ball_protobuf_cpp.dart` | Compile `ball_protobuf` facade to C++ |

## For AI Agents
- Entry point: `DartCompiler.compile`. Base-function dispatch is in `_compileBaseCall` — extract fields from the `MessageCreation` input.
- Every per-module base-call switch ends in `_unimplementedBaseCall(module, function)`, which THROWS (#654). Never re-introduce a `/* unsupported: … */` default arm: a comment spliced where an expression belongs is broken output, not a diagnostic. `test/base_call_dispatch_completeness_test.dart` is the closed-set gate — it builds the population from the eight `buildStd*Module()` builders and COMPILES a probe call for every declared name, so adding a `_fn(...)` in `dart/shared/lib/std*.dart` without a lowering here fails with no test edit.
- A `std_collections` lowering that needs a top-level helper registers it in `_collectionsHelperSources`, keyed by the base function; the preamble is emitted per DECLARED function (an unused private top-level function is an analyzer warning in the compiled output), and its semantics must match `dart/engine/lib/engine_std.dart` exactly.
- That match is PROVEN, not asserted: `test/declared_base_call_equivalence_test.dart` runs one hand-authored Ball program on the reference engine and through `dart run` over its compiled Dart, both against one expected transcript. Encoder-unreachable base functions can have no conformance fixture, so this is their equivalent.
- Control flow (`if`/`for`/`while`) MUST compile lazily — extract expression trees, never eval branches eagerly (see Core Invariants in `../../CLAUDE.md`).
- Types are emitted from `typeDefs[]` only; the legacy `types[]`/`_meta_*` path is gone.
- A value-position `Block` compiles to `(() { … })()`, EXCEPT the encoder's cascade lowering, which `_tryCompileCascadeBlock` recognizes back into native `..` / `?..` syntax (#573). Keep that recognizer keyed on `LetBinding.metadata['kind'] == 'cascade'`, never on the Block's shape alone: an IIFE is a function boundary, and Dart drops a local's type promotion across one, so a Block that merely LOOKS cascade-shaped must keep the generic lowering.
- `late` on an instance field is a DECISION READ OUT OF THE IR, never inferred from the field declaration alone (#651). `_definitelyAssignedFields(methods)` intersects, across every generative constructor, the fields proved assigned by that constructor's own initializer list (`metadata['initializers']` `{kind: field}`) or by an always-supplied initializing formal (`metadata['params']` `is_this` that is required, or optional WITH a `default`); `_addInstanceFields` skips `fb.late` for those. Emitting a stray `late final` is not cosmetic — it hands the field an implicit setter that collides with a user-declared one (`DUPLICATE_DEFINITION`).
- Compiler-specific patterns and gotchas: `.claude/rules/dart.md`.
- Tests in `test/`; cross-language matrix tests tagged `slow` (`-x slow` to skip).

## Dependencies
- Internal: `ball_base`, `ball_encoder`, `ball_engine`, `ball_resolver`.
- External: `code_builder` (Dart AST), `dart_style` (formatter), `protobuf`/`fixnum`.
