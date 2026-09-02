<!-- Parent: ../AGENTS.md -->

# cpp/compiler

## Purpose
Ball → C++ code generator. Walks a protobuf-free `ball::ir::Program` tree (loaded via nlohmann/json — #18 Stage 4/5) and emits self-contained C++ source (single-TU or split multi-TU for the self-hosted engine).

## Key Files
| File | Description |
|------|-------------|
| `src/compiler.cpp` | `CppCompiler` implementation — expression dispatch, base-function dispatch, block→lambda emission |
| `src/main.cpp` | CLI entry point (`ball_cpp_compile` binary) |
| `include/compiler.h` | `CppCompiler` class declaration; `CompileSplitResult` (multi-TU) and `CompileLibraryResult` structs |
| `include/code_builder.h` | Line-oriented string builder used throughout emission |

## For AI Agents
- Entry point: `CppCompiler::compile()` (single TU) or `compile_split()` (sharded for engine_rt). Read `compiler.h` first.
- Base-function dispatch is in `_compileBaseCall` (large switch in `compiler.cpp`). Unknown base functions silently emit `/* std.fn */ 0` — a known silent-correctness gap; see `../AGENTS.md` § Known Broken/Stubbed Features.
- Blocks compile to immediately-invoked lambdas; `for`/`while` in expression context with `return` inside are partially stubbed — see `../AGENTS.md`.
- `ball_emit_runtime.h` (in `../shared/include/`) is slurped at CMake configure time and spliced verbatim into every emitted program's preamble. Changes there propagate automatically — do not duplicate its content.
- **Accessor resolution is RUNTIME, never static (#501).** `compile_field_access` decides `obj.x()` vs `obj.x` with a whole-program, receiver-agnostic name lookup, and that is deliberate: the receiver's compile-time type is not what Dart resolves an instance member by. When a subclass declares a plain field that shadows an inherited getter, the emitter does NOT special-case the call site — it changes the CLASS instead. `shadowed_getter_names_` / `class_shadowed_fields_` (built at the end of the indexing pass) make `emit_struct` store such a field in a private renamed backing member (`_ball_shadow_<name>`, see `shadow_backing_name`) and re-expose the field's own name as a public `virtual` getter/setter pair, over an ancestor getter that the same pass forces virtual via `overridden_methods_`. C++'s vtable then answers by the receiver's runtime type, matching Dart. Never "fix" this by resolving against the receiver's static class: that compiles `406_subclass_field_over_getter` and silently prints the base value for `431_shadowed_getter_dynamic_dispatch`.
- **A method-LOCAL shadows every class member — check `declared_locals_` FIRST.** Any branch in `compile_reference` that turns a bare name into `this`-relative member syntax (`x` -> `x()` for a getter or a shadowed field, `x` -> a sibling-method lambda) must yield when `declared_locals_` holds that name; Dart resolves a local ahead of any member. Getting this wrong is not a build error and therefore worse than one: `BallDyn` defines `operator()`, so `return x();` on a local BUILDS and yields an empty `BallDyn` — `null` instead of the local's value (`433_shadowed_field_self_write_and_local`, both halves).
- **A base-typed local must never be declared with the base type when its initialiser is a subclass value.** C++ locals of class type have VALUE semantics, so `A v = b;` where `b` is a `B` SLICES — the derived part and the vtable pointer are dropped and every virtual call answers with the base implementation. Dart never slices. `local_class_types_` records the concrete class each user-class local was emitted with, and a let whose initialiser is a bare Reference to one of them declares itself with that class (`class_is_or_descends_from` gates it to a real inheritance edge). Watch for the same trap in any new binding site: it is a SILENT wrong answer, and it only becomes visible once the class has an override to lose (`433_shadowed_field_self_write_and_local`'s `viaBase.x`).
- **A write to a shadowed field goes through the SETTER, never through the name.** Because the field is emitted as an accessor pair, `compile_reference` gives the assign handler an rvalue (`x()`), and every lvalue branch there — `ball_assign(target, v)`, `target += v`, `target = v` — is then either a hard g++ error ("cannot bind non-const lvalue reference of type 'BallDyn&' to an rvalue") or nonsense. Route a `Reference` target naming a shadowed field of the current class through the emitted setter, binding the value exactly once (a re-evaluated RHS is the #18 stage-5 double-evaluation bug). The explicit-receiver path in the `assign` handler does the same for `obj.x = v`.
- Coverage floors for this target live in `../build-cov-floor.sh` and are **gated** by `coverage.yml`'s cpp job (#63/#59). They are a regression ratchet derived from CI's own measurement minus a ~2pt buffer — raise them as tests land; never lower one to make a red go away.
- CMake target: `ball_cpp_compile`. Stack size: 128 MB (set in `cpp/CMakeLists.txt`).
- Tests live in `cpp/test/test_compiler.cpp`. Reference `.claude/rules/cpp.md` for build commands and `CLAUDE.md` for the full workflow.

## Dependencies
- Internal: `ball_shared` (shared types + generated protos), `ball_emit_runtime.h` (runtime preamble).
- External: nlohmann/json (via `ball_shared` → `ball_ir.h`). No libprotobuf (#18 Stage 5).
