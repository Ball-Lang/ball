---
paths:
  - "rust/**"
---

# Rust-Specific Instructions

Rust is a **full pipeline** — compiler, encoder, self-hosted engine, and CLI are all in place
and tested. The self-hosted engine runs the whole conformance corpus at **Dart parity**
(`Results: 348 passed, 0 failed, 348 total`; the 4 golden-less resource-limit/sandbox fixtures
are carve-outs skipped like the Dart runner — #39/#300 closed, #40/#41 landed). Always verify
maturity against CI (`.github/workflows/ci.yml`'s `rust` job — build/test/fmt/clippy plus the
self-host run-acceptance and full conformance sweep) and `rust/AGENTS.md`, not stale prose.

## Build System

- `cargo` is not on native Windows in this dev environment — run all `cargo` commands via WSL,
  e.g. `wsl.exe -e bash -lc "cd /mnt/d/packages/ball/rust && cargo build --workspace"`.
- `rust-toolchain.toml` (`rust/rust-toolchain.toml`) pins `channel = "stable"` with `rustfmt` +
  `clippy` components — a bare `cargo` inside `rust/` auto-selects it via `rustup`.
- Cargo workspace root is `rust/Cargo.toml` (`resolver = "3"`), members:
  `shared`, `compiler`, `encoder`, `engine`, `engine/tool`, `cli`, `cli/tool`. Shared
  version/edition/license/dependency versions live in `[workspace.package]` /
  `[workspace.dependencies]` — member crates reference them with `{ workspace = true }`, never a
  repeated version string.

```bash
cd rust
cargo build --workspace
cargo test --workspace
cargo fmt --check && cargo clippy --workspace
```

## Package Structure

- `ball-lang-shared` (`rust/shared/`) — protobuf bindings (`prost`/`prost-reflect`, generated into
  `rust/shared/gen/`) + runtime value model (`BallValue`/`BallList`/`BallMap`/`BallFunction`/
  `BallMessage`, `rust/shared/src/value.rs`) + std/std_collections/std_io/std_memory module
  builders + `runtime::*` base-op helpers consumed by the compiler.
- `ball-lang-compiler` (`rust/compiler/`) — Ball → Rust compiler. `compile_expression` handles all 7
  expression node types; `base_call.rs` is the base-function dispatch table (delegates to
  `ball_lang_shared::runtime`); `lvalue.rs` handles assignment/mutation; `type_emit.rs` handles
  `typeDefs[]` → struct/trait/enum + multi-module output.
- `ball-lang-encoder` (`rust/encoder/`) — Rust → Ball via `syn` 2.x (`features = ["full",
  "extra-traits"]`). Routes every construct through universal `std`/`std_collections` — **no
  `rust_std` base module**, ever.
- `ball-lang-engine` (`rust/engine/`) — self-hosted engine wrapper (`loader.rs`/`scope.rs`/
  `ball_proto.rs`) + generated, gitignored `src/compiled_engine.rs`. See
  `rust/engine/AGENTS.md` for the full self-host gap list; the compiled-engine driver is behind
  the off-by-default `self_host` cargo feature.
- `ball-engine-regen` (`rust/engine/tool/`) — `cargo run -p ball-engine-regen` regenerates
  `compiled_engine.rs` from `dart/self_host/engine.ball.json`.
- `ball-lang-cli` (`rust/cli/`) — the `ball` CLI (#41/#304): `run`/`compile`/`encode`/`check`
  plus the cli-core verbs. `encode` takes `--lib` (library mode, #491) and `--crate` (walk a whole
  crate's `mod` graph, #491).

## Key Patterns

### Compiler

- `Compiler::compile` / `compile_library` (library mode has no runnable entry point — used for
  the self-host regen tool) emit Rust source **as strings**, closest in spirit to the C++
  compiler's string-concatenation approach (not Dart's `code_builder`/TS's `ts-morph`).
- Every compiled expression evaluates to a `ball_lang_shared::BallValue` — there are no "void"
  expressions; side-effecting calls like `print` compile to `{ ...; BallValue::Null }` so every
  expression position (block tail, `if`/`else` arms, function bodies) stays type-uniform.
- `Block` compiles to a **native Rust block expression** (Rust blocks are already
  tail-expression-valued) — unlike C++'s immediately-invoked lambda pattern for blocks.
- Control flow (`if`/`and`/`or`/`for`/`for_in`/`while`/`do_while`) compiles to native Rust
  control flow, never a function call — lazy evaluation per invariant #4.
- **`switch` vs. `switch_expr` are two different lowerings, and the difference is load-bearing.**
  `base_call.rs` dispatches the two literal call names to `compile_switch(call, is_expr)`, and
  `is_expr` must be threaded all the way through `parse_switch_cases`:
  - The fall-through/empty-body heuristic (`is_empty_switch_body`) is **statement mode only**. Ball
    encodes `null` as a value-less `Literal` — the exact shape that heuristic reads as "empty" — so
    in expression mode it would delete every `=> null` arm and leak its condition (issue #470; it
    silently ate the self-hosted engine's own `Literal_Value.notSet` arm). Mirrors
    `go/compiler/base_call.go:514-522`.
  - A defaultless switch **expression** that matches nothing throws
    `Non-exhaustive switch expression` via `ball_throw` (issue #467, aligning with Go/C#/Dart); a
    statement `switch` still legally falls through to `BallValue::Null`. That throw is only safe
    *because* the arm-dropping fix landed first — restoring it alone regresses the self-host sweep
    320 → 315.
- Arithmetic semantics must match the Dart reference engine, not "whatever Rust's operator
  does": `modulo` is Euclidean (sign of divisor, via `ball_lang_shared::runtime`), int ops use
  wrapping arithmetic (Dart's fixed-width 64-bit `int`, no overflow panics), `equals`/
  `not_equals` promote `Int`/`Double` cross-type.
- **Reference-semantic collections (Dart parity, #298/#39/#300).** `BallValue::List` and
  `BallValue::Message` share their backing (`Arc<Mutex<Vec>>` / `Arc<Mutex<Map>>`,
  `rust/shared/src/value.rs`), so a `.clone()`-on-read *aliases* — a `list.add(x)` /
  `this.field = y` through any clone is observed by the caller, exactly like Dart's reference
  types. Only `Map` stays value-semantic. **Copy points must snapshot**, matching Dart: a list
  *literal* `[…]` emits `BallValue::List(BallList::from(vec![…]))` (fresh backing), and
  `toList()`/`List.from`/spread/`Set` + the `+` concat operator go through `as_list()` (a
  snapshot `Vec`) — never `.extend()` on a shared list, which would mutate an operand. A
  `list[i] = x` / `obj.field = x` write can't borrow `&mut` through the `Mutex`, so it routes
  through `ball_index_get`+`ball_index_set` / `ball_field_get`+`ball_field_set` read-modify-write
  (`lvalue.rs::emit_mutation`).
- Documented scope gaps live in `rust/compiler/src/lib.rs`'s module doc comment (a handful of
  base functions, constructors/methods with a real mutating body, class-hierarchy/`is`/`as`
  subtyping, multi-parameter lambdas) — read it before assuming something is a bug vs. a known,
  documented boundary.

- **`std_collections.list_find` THROWS when nothing matches (#597).** It is Dart's
  `Iterable.firstWhere` WITHOUT `orElse` — what its own declaration in
  `dart/shared/lib/std_collections.dart` says ("Find first:
  list.firstWhere(callback)") and what the Dart reference engine does
  (`engine_std.dart`: `throw StateError('No element')`). Never a `null`/
  `undefined`/empty placeholder, and never an untyped throw: the thrown value
  must carry the type name `StateError` so the program's own `on StateError
  catch` sees it. `tests/conformance/463_list_find_no_match` is the cross-target
  guard; `rust/shared/src/runtime.rs`'s `list_find_no_match_throws_a_typed_state_error` (`ball_list_find` uses `ball_throw_typed`, like its `.first`/`list_reduce` neighbours — a bare `panic!(&str)` is recoverable only by an UNTYPED catch) is this target's half. See `docs/TESTING_STRATEGY.md` §5b.

### Encoder

- `encode(&str) -> Program` parses with `syn` and walks items → fns → statements → expressions.
- **Invariant, not optional: no `rust_std` base module.** Every Rust construct (operators,
  control flow, iterator-chain sugar, `?`, `if let`) expands into a tree of `std`/
  `std_collections` calls — mirrors the Dart encoder's cascade/null-aware-access/spread
  expansion. A conformant engine that has never heard of Rust must still run the result.
  See `rust/encoder/src/lib.rs`'s module doc comment.
- Std modules are accumulated from actual usage (`collect_used_functions`) — encoded programs
  declare only the base functions the source actually calls (`std` itself is always present,
  even empty), mirroring `dart/encoder/lib/encoder.dart`'s `_buildStdModule`.
- The "one input" convention (invariant #1) for N-parameter Rust fns/closures: 0 params → no
  input; 1 param → kept as a plain `reference(name)` driven by `metadata.params` (compiler's
  `param_alias_prologue` turns it into a real local binding); 2+ params → packed into one
  anonymous `MessageCreation`, each param read via `field_access(reference("input"), name)`.
- Documented gaps (see `rust/encoder/src/lib.rs` / `types.rs` / `methods.rs`): data-carrying enum
  variants, **signature-only** receiver-less `trait` associated functions (a *default-bodied* one
  encodes — see below; the guard keys on the missing BODY, not the missing receiver), a
  `receiver.method(args)` whose method is declared in another file (`methods.rs`' own panic — the
  largest remaining bucket), an `impl` whose **self type** is not a plain named type
  (`impl<I> Trait for (I::Item,)` — `types.rs::type_short_name`, 8 of the 110 scored Tier A
  files), destructuring patterns (`let Pair(a, b) = p;`), a *reference* to a skipped module-scope
  `const`/`static`/`type` alias (the declaration itself is skipped — see below),
  unmapped macros (`write!` — the measured largest *next* bucket, 9 of the 110 files). Each is
  pinned by a `#[should_panic]` characterization test in `rust/encoder/tests/documented_gaps.rs`
  (#491) — flip it to a positive assertion in the same PR that closes the gap. **Count the
  flipped ones with `grep -c should_panic rust/encoder/tests/documented_gaps.rs`, never from
  prose**: this line read "Five are flipped" while eight were, because a tally in a rule file
  goes stale the moment a slice lands. **A pin is owed the moment a gate exists, not the moment
  it closes** — the 24-file cross-file METHOD-call bucket went three merged #491 PRs with a live
  gate and no test observing it before `cross_file_method_call_is_a_documented_gap` pinned it. It
  is CLOSED now by the crate-aware `encode_crate` (below), and that test is flipped positive.
- **Tuple + unit structs (#491).** All three `struct` shapes encode to the same class-shaped
  `TypeDefinition`; only the field names differ. A tuple element is declared under its
  **positional index as a decimal string** (`"0"`, `"1"`) — the very name
  `types.rs::member_name` has always produced for the matching `p.0` *read*, and an opaque map key
  to the compiler (`is_positional_arg_name` matches only `arg<digits>`). A unit struct declares
  zero fields. **Declaration alone would be a regression**, so two `lib.rs` interceptions ship with
  it: `encode_call` turns `Pair(3, 4)` into a `message_creation` *before* its same-file-function
  branch (the two are the same syntax), and `encode_path_expr` turns a bare `Marker` into an
  empty-field `message_creation` *before* its `reference(name)` fallback — but *after*
  `is_current_multi_param`, so a same-named parameter still wins; that name-only bias is inherited
  from the `.fuse()`/`.is_empty()` precedent and deliberately not widened. Proof:
  `rust/encoder/tests/tuple_and_unit_structs.rs` (encode → compile → `cargo build` → run).
  **Closing this category did NOT move the Tier A aggregate** — measured before *and* after:
  `Results: 0 passed, 110 failed, 110 total`; all 14 files simply land on their next gap (7 on
  `write!`). See `rust/AGENTS.md`'s histogram; never let a green `documented_gaps.rs` be read as a
  moved floor. *Destructuring* a tuple struct remains a separate, still-open pattern gap.
- **Non-`Fn` items inside an `impl` block are SKIPPED, not thrown on (#491 slice 5).** An
  associated `const`/`type` (or an item-position macro) beside real methods no longer aborts the
  whole file — `types.rs::encode_item_impl` skips it and keeps encoding the block's methods, the
  same tolerance the sibling pre-pass `collect_impl_method_params` always had. Safe because a real
  *reference* to the dropped item (`Self::CAP`) still fails loud at `lib.rs`'s "unsupported path
  expression" panic. Proof: `rust/encoder/tests/mixed_impl_items.rs` (encode → compile →
  `cargo build` → run). This is a DIFFERENT gap from the still-open `impl` self-type one above;
  do not conflate their file counts.
- **Module-scope `const`/`static`/`type` alias and non-`Fn` `trait` items are SKIPPED too
  (#491).** `lib.rs`'s top-level item match and `types.rs::encode_item_trait` no longer abort a
  file on a declaration Ball models nothing for — 7 and 3 of the 110 scored Tier A files
  respectively. **The module-scope skip needs a guard the `impl` one does not, and copying the
  precedent without it would be a silent-degradation bug:** a skipped `impl` item is referenced as
  `Self::CAP` (a two-segment path `encode_path_expr` already refuses), but a skipped module-scope
  `const` is referenced as a bare `LIMIT` — a single-segment path the same function would pass
  through its `reference(name)` fallback, emitting a read of a binding nobody declared. So pass 1
  records the names in `Encoder::skipped_item_names` and `encode_path_expr` panics at the USE
  site, naming the declaration. A top-level **macro invocation** stays a loud panic on purpose: it
  can be the thing that DEFINES a type the file references (`bitflags!` → `TestFlags`, 28 of the
  110 files), so skipping it would orphan the references into a worse error; that needs macro
  expansion. Proof: `rust/encoder/tests/mixed_module_items.rs`. Like every #491 slice, the Tier A
  **aggregate did not move** (`0 passed, 110 failed, 110 total`, `encoded 0/110` before and
  after) — only the first-blocker histogram did; `baseline.json`'s Rust row is unchanged.
- **`.fuse()`/`.is_empty()` (#491 slice 6), and the permanent carve-outs beside them.** `.fuse()`
  is an identity passthrough (a Ball `List` has no exhausted state); `.is_empty()` lowers to
  `std.equals(std.length(receiver), 0)`, reusing `.len()`'s own universal dispatch, so it needs no
  type inference. Everything else in `methods.rs`' catch-all bucket is a **permanent** carve-out
  named in that file's module doc comment — `.next()`, `.unwrap_or_default()`, `.spilled()`,
  `.iter_names()`, `.serialize_seq()`, `.is_human_readable()`, `.ok_or()`, `.value()`,
  `.multiunzip()`. Each needs stateful-iterator semantics Ball lacks, or a type-specific default
  no syntactic encoder can supply; guessing produces silently wrong output, not a loud failure.
  **Both new arms defer to a same-file user method of that name** (a `!method_params.contains_key`
  guard) — unlike every older arm, which matches on the name alone. That older bias is inherent to
  a syntactic encoder (a user's `fn len(&self)` has always become `std.length`), but a `Vec`-backed
  struct's own `is_empty` lowered to `std.length(struct) == 0` would be silently wrong output, so
  slice 6 deliberately does not widen it.
- **Receiver-less associated functions + cross-file calls (#491 slice 3).**
  `impl Point { fn new(x, y) … }` now encodes as a `metadata.is_static` class member (the shape
  `type_emit.rs::method_prologue` has supported since #288), and `Point::new(3, 4)` emits
  `FunctionCall{module: "", function: "new"}` with the callee's real parameter names and no
  `"self"` field — proven end to end (encode → compile → `cargo build` → run) by
  `rust/encoder/tests/static_methods.rs`. A call into a module this file does not declare
  (`other_file::helper(1)`) emits `FunctionCall{module: "other_file", …}` plus a **source-less
  `ModuleImport`** ("ref only") instead of panicking, with arguments packed **positionally**
  since an external callee's parameter names are unknown; `rust/encoder/tests/cross_module_calls.rs`
  pins the shape. That fallback is **module-only** — it applies when the segment immediately
  owning the function is `snake_case`, so `Vec::new()`/`std::vec::Vec::new()` (an associated fn on
  a foreign TYPE, which no import could supply) still fail loud. **Verified contract**, not assumed: a source-less import is structurally legal
  and deliberately unresolved — `ball check` accepts the program
  (`rust/cli/tests/cli_check.rs::encoded_cross_file_call_is_structurally_valid_but_unresolved`),
  matching the Dart reference (`cli_core.dart`'s `validationErrors` never inspects imports;
  `runner.dart`'s `ball build` treats only a source-BEARING import as needing the resolver), and
  the program is not runnable until the module is supplied — the same boundary library mode set
  for an empty `entry_function`. Keep this decision consistent with the C# encoder's eventual
  cross-file slice (#492 bucket d). That known limitation - a `crate::`/`self::`-qualified call
  treated as external - applies to the SINGLE-FILE entry points only; `encode_crate` resolves
  both (next bullet).
- **Crate-aware encoding - `encode_crate` / `ball encode --crate` (#491, owner decision
  2026-09-13).** `rust/encoder/src/crate_graph.rs` walks a crate's `mod` graph from its root (the
  `Cargo.toml` directory, the `src` directory, or the root `.rs` file) and encodes every file
  against ONE crate-wide symbol table - the Rust sibling of
  `dart/encoder/lib/package_encoder.dart`. That is what closes the largest #491 bucket: a
  `receiver.method(args)` whose method is declared in another file. Resolution follows the Rust
  reference (`foo.rs` XOR `foo/mod.rs`; the declaring file's own directory for a mod-rs file and
  `<dir>/<stem>/` otherwise; `#[path]` relative to the declaring FILE's directory outside an
  inline block and to the nested directory inside one; an inline `mod` block is its own module);
  `#[cfg(test)]` modules are not walked, because `cargo build` does not compile them either.
  **Output is multi-module and needed NO compiler change** - a cross-file call carries
  `FunctionCall.module`, which `type_emit.rs::resolve_user_call_name` (issue #38's multi-module
  output) already turns into the `<mod>::` qualifier onto that module's dispatcher. What it
  narrows rather than removes, each pinned in `rust/encoder/tests/crate_encoding.rs`: a method no
  file in the crate declares still fails loud; so does a method short name declared in two
  modules when the call site's own module declares neither (the compiler's dispatcher resolves by
  short name WITHIN a module, so picking one would silently dispatch to the wrong body); a
  cross-module enum-variant read is refused by name; a `mod` with no file is a loud panic, never
  a dropped module. **Indexing must not fail loud where encoding must**: the walk catalogues the
  whole crate before encoding anything, so it reads parameter names with its own non-panicking
  `simple_param_names` - reaching for `param_names_and_types`/`method_non_self_params` there
  turned `itertools`' one `fn cmp(&self, (c, t): ...)` into "no crate-aware measurement for the
  entire crate". Measured before/after with ONE binary over one checkout (`rq1-study
  --single-file` reproduces the per-file measurement): stage-1 `1 encoded` **0/110 -> 1/110**,
  clean unchanged at **0/110**, histogram conserved (`unsupported method call` 18 -> 11,
  `unsupported call target` 35 -> 32). `tools/coverage-study/baseline.json`'s Rust row is raised
  to `encoded: 1` and nothing else.
- **Default-bodied receiver-less `trait` functions (#491).** `trait Maker { fn make(n, m) -> i64
  { n + m } }` encodes as the same `metadata.is_static` class member an `impl`-declared associated
  fn does, and `Maker::make(3, 4)` resolves through the same short-name dispatcher — the compiler
  needed **zero** change, because `compile_struct_def`/`compile_method_dispatchers` filter members
  by `is_abstract` **alone** and never look at whether the owner is a `trait`. So the guard in
  `types.rs::encode_item_trait` keys on the missing *body*, not the missing *receiver*; a
  signature-only one still fails loud and keeps its `#[should_panic]` pin. A new pre-pass,
  `collect_trait_static_params`, registers each such member into `static_method_params` under the
  same owner-qualified `(owner, method)` key `collect_impl_method_params` uses.
  **Gotcha worth remembering:** a receiver-less member's `metadata.params` must come from
  `param_names_and_types`, never `method_non_self_params` — the latter unconditionally `.skip(1)`s
  a `self` that isn't there and silently drops the FIRST real parameter. A 0-/1-parameter example
  cannot expose that, so the proof test declares two. Proof: `rust/encoder/tests/static_methods.rs::
  default_bodied_trait_fn_without_receiver_encodes_and_round_trips` (encode → compile →
  `cargo build` → run, prints `12`). Like every #491 slice so far, this did **not** move the Tier A
  aggregate (`0 passed, 110 failed, 110 total`) — a default-bodied *receiver-less* trait fn is a
  narrow idiom; state that plainly rather than implying a moved floor.
- **Library mode (#491 slice 2).** `encode` requires a `fn main()`; `encode_library` (CLI:
  `ball encode --lib`) drops **only** that requirement — every other documented gap still panics.
  A library-mode `Program` carries `entry_module = "main"` (needed by `compile_library`, which
  looks that module up) and an **empty `entry_function`**, so it is deliberately NOT runnable:
  `ball check` reports `missing entry_function`, and that is the correct, documented boundary —
  never synthesise a fake entry function to silence it. The C# encoder's `EncodeLibrary` makes the
  identical call; keep the two consistent. Proof: `rust/encoder/tests/library_mode.rs` compiles the
  encoded program through `compile_library` and asserts `cargo build` accepts it as a real `[lib]`.

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++: compile
  `dart/self_host/engine.ball.json` through `ball-lang-compiler` into `src/compiled_engine.rs`.
- **Status: complete, runs at Dart parity** (#39/#300). The compiled engine builds and runs the
  whole corpus with Dart-identical output: `Results: 348 passed, 0 failed, 348 total` (the 4
  golden-less resource-limit/sandbox fixtures 196/197/201/202 are behavioral carve-outs skipped
  like the Dart runner). The `self_host` cargo feature gates the compiled-engine driver (the
  generated `compiled_engine.rs` is a gitignored build artifact); a default build without it
  stays green on the wrapper foundation. Regenerate + run: `cargo run -p ball-engine-regen` then
  `cargo test -p ball-lang-engine --features self_host --test self_host_conformance -- --ignored`.
- Fixes to engine behavior belong in `rust/compiler/` or `ball_lang_shared::runtime` (or the Dart
  self-host source, then regenerate) — **never** hand-patch `compiled_engine.rs`. When a fixture
  diverges from Dart, check whether the divergence is in the compiler's emitted code (a compiler
  fix + regen) or in a runtime helper the emitted code calls (a `ball_lang_shared::runtime` fix, no
  regen) — the final-24 close-out was split roughly evenly between the two.

## Generated Files — NEVER Edit

- `rust/shared/gen/*.rs` — protobuf bindings from the `buf.build/community/neoeinstein-prost`
  plugin (root `buf.gen.yaml`; there is no official `protocolbuffers/rust` plugin). Regenerate
  via `buf generate`.
- `rust/engine/src/compiled_engine.rs` — gitignored (like C++'s `engine_rt.cpp`), regenerated
  via `cargo run -p ball-engine-regen`.

## Testing

- **Third-party coverage study, Tier A (#493).** `rust/tools/rq1-study` (crate
  `ball-rq1-study`, `publish = false`, a workspace member so it is built/formatted/
  linted with everything else) runs real pinned crates through
  `encode_library` -> `compile_library` -> `encode_library`, diffs the declaration
  inventory with **`syn` directly** (never the encoder's own walk) and checks a
  second-generation fixpoint. It is CRATE-AWARE since #491's `encode_crate`
  slice: each package's `mod` graph is walked once and every file it reached is
  encoded with the crate's symbol table in hand (`rq1-study --single-file`
  turns that off and reproduces the older per-file measurement, so a
  before/after is one binary over one checkout; each JSON row's `crateModule`
  says which way that file was measured). Honest baseline, **0/110 clean,
  1/110 encoded** — the encoders' documented gaps (item-level macro
  invocations, unmapped macros like `write!`, `impl` self types that are not a
  plain named type) are in essentially every real crate file, and a file that
  clears one lands on the next. A closed gap category usually moves the
  histogram, not the aggregate; the crate-aware slice is the first one to move
  the aggregate at all, and it moved it by one file. The 5 pinned crates are `itertools`, `smallvec`, `bitflags`, `heck`,
  `strsim` (`tools/coverage-study/packages/rust.json`), not the original 10-crate
  #491 set. **Always point `CARGO_TARGET_DIR` at a path inside the current
  worktree** — a target dir shared with another lane serves a stale `rlib` and
  produces a false red that reproduces nowhere in your own diff. `cargo test -p
  ball-rq1-study` (the harness's own self-test) IS gated on every PR in the `rust`
  job; the RUN is the `rust-tier-a` job in `coverage-study.yml`, which
  has **no `pull_request:` trigger** (its row is floored by ratchet in that
  workflow's `publish` job). Methodology:
  `tests/conformance/COVERAGE_STUDY.md`.

- **The std module builders are a PORT of Dart's and are gated name-for-name** (#505).
  `rust/shared/src/std_dart_parity.rs` (a `#[cfg(test)]` module) scans
  `dart/shared/lib/<module>.dart` for `_fn('name'` registrations and each
  `std_*_module.rs`'s `function_names_match_dart_source` test asserts the Rust builder declares
  exactly that set. These used to be bare `assert_eq!(module.functions.len(), N)` counts, which
  can only notice a change made in Rust — that is how this crate silently fell thirteen functions
  behind when Dart declared its routed-but-undeclared std functions. **When you add or remove a
  `_fn(...)` in `dart/shared/lib/std*.dart`, port it here in the same PR**; a hardcoded count is
  never an acceptable substitute for the name-for-name check. C# has the same contract
  (`csharp/shared/test/StdModuleBuilderTests.cs`); Go/Python/TS/C++ have no std module builders.
  Since #557 each module ALSO has a `function_output_types_match_dart_source` test:
  the name gate cannot see a declared-TYPE drift, and that is exactly how
  `set_add`/`set_remove` kept `outputType: ""` here after #545 declared `'bool'`
  in Dart — both sides green, the cross-target contract split. Port the
  `outputType` too, not just the name.
- **`is BallRawMap` is the engine's own raw-map probe, and this crate answers it
  (#557).** `ball_is_type`'s `"Map"` arm deliberately EXCLUDES a tagged set so a
  user program's `{1,2} is Map` is `false` (#528/#553) — but the self-hosted
  engine's `_ballValueIsSet` needs the opposite answer for its OWN
  representation, and with only `is Map` to ask with it was permanently `false`
  here, so every in-place set mutation the engine performed went to a throwaway
  copy. `BallRawMap` (a typedef in `dart/engine/lib/engine_types.dart`) is that
  second question, answered structurally: `matches!(value, BallValue::Map(_))`,
  no exclusion. Conformance fixture `462_set_mutation_in_place` is the guard.
- `cargo test --workspace` from `rust/` (via WSL). `ball-lang-engine`'s compiled-engine driver is
  feature-gated off by default, so this stays green without depending on #39.
- `rust/engine/tests/roundtrip_conformance.rs` is a **measurement-only** whole-corpus sweep
  (#452 item 3): Ball → Rust → Ball → the **Dart** reference engine → golden diff, all in-process
  except the Dart run (no per-fixture `rustc`, ~7 s for 321 fixtures). Honest baseline **0/321**,
  like the C# leg it mirrors. `#[ignore]` so `cargo test --workspace` never picks it up; run it with
  `cargo test -p ball-lang-engine --test roundtrip_conformance -- --ignored --nocapture`. Its CI
  home is the `rust-roundtrip` row in `conformance-matrix.yml`, which has **no `pull_request`
  trigger** — the row is absent, not green, on a PR; dispatch the workflow and read the run.
- `cargo test -p ball-lang-compiler` / `cargo test -p ball-lang-encoder` include `tests/end_to_end.rs`
  suites that compile emitted Rust with the **real `cargo run`/`rustc`** and assert on actual
  stdout — prefer extending these (or, once #40 lands, `tests/conformance/` fixtures) over
  Rust-only unit tests, per the repo-wide "prefer conformance tests" rule.
- No `tests/conformance/*.ball.json` runner exists for Rust yet (#40) — do not claim conformance
  parity in commit messages or docs until it does.

## Dependencies

- `prost = "0.14.4"` + `prost-reflect = "0.16.4"` — pinned exact versions; `prost-reflect`'s
  `DescriptorPool`/`DynamicMessage` are required for descriptor-driven `MessageCreation`/
  `google.protobuf.Struct` metadata work. Google's upb-based `protobuf` v4 crate has no
  reflection API and was rejected.
- `indexmap = "2"` — backs `BallMap`; insertion-ordered like every other engine's map type
  (Dart's `LinkedHashMap`, C++'s `BallOrderedMap`). Never substitute `HashMap` for Ball-value
  maps.
- `syn = "2"` (`features = ["full", "extra-traits"]`) + `proc-macro2` + `quote` — encoder's Rust
  parser.
