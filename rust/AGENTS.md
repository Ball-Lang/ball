<!-- Parent: ../AGENTS.md -->

# Rust Implementation Agents

Rust implementation of Ball tools (epic #32). The full pipeline is in place —
compiler, encoder, self-hosted engine, and CLI — and the self-hosted engine now
**runs the whole conformance corpus at Dart parity** (`Results: 363 passed, 0
failed, 363 total`; the 4 golden-less resource-limit/sandbox fixtures are
carve-outs, skipped exactly as the Dart runner skips them — #39/#300 closed).
Always reference the Dart implementation (`dart/compiler/lib/compiler.dart`,
`dart/encoder/lib/encoder.dart`, `dart/engine/lib/engine.dart`) as the canonical
behavior; the C++ prototype (`cpp/compiler/`, `cpp/encoder/`) is the closest
sibling for compiler/encoder patterns since both emit target source via string
concatenation. **Verify maturity against CI, not this prose** — the `rust` job in
`.github/workflows/ci.yml` gates build/test/fmt/clippy plus the self-host
run-acceptance and the full conformance sweep.

## Third-party coverage study — Tier A (`rust/tools/rq1-study`, issue #493)

`ball-rq1-study` (a `publish = false` workspace member, so `cargo build/fmt/clippy
--workspace` cover it) runs pinned third-party crates through
`encode_library` → `compile_library` → `encode_library`, diffs the declaration
inventory using **`syn` directly** — never `ball-lang-encoder`'s own walk, so an
encoder bookkeeping bug cannot hide from the instrument measuring it — and
checks a second-generation fixpoint.

Honest baseline, **0/77 clean and 9/77 encoded** (the 5 crates pinned in
`tools/coverage-study/packages/rust.json` — **`itertools`, `smallvec`, `bitflags`, `heck`,
`strsim`**, not the original 10-crate set the #491 prose below narrates). The first encoded file
arrived with the crate-aware slice below — every #491 slice before it left the aggregate at
`0 clean, 0 encoded` — then #630's `write!` slice took it 1 → 7 and #767's tuple +
reference-`impl`-self-type slice 7 → 9. `clean` has never moved: stage 3 is where every arriving
file now stops, on `ball_arg_get` (**#790**).

**The denominator was 110 until 2026-09-14, and the #491 prose below is all written against
that number — read those histograms as history, not as today's totals.** Per the owner's
methodology decision on #491, Tier A now scores LIBRARY code only: 34 of the 119 `.rs` files
under the pinned subtrees are `bitflags`' own tests and are excluded, so `scored` is **77** and
the harness prints `excluded (test-only): 34`. Rust's rule has two halves, and on the real pins
all 34 come from the second one: a file the crate's `mod` graph reaches *only* through a
`#[cfg(test)]` module. The path half covers the PACKAGE-ROOT `tests/`, `benches/` and `examples/`
Cargo targets — siblings of `src/`, which the pins (`lib` = `src`) never even walk — and
deliberately not `src/tests/`, which is an ordinary module directory whose contents can be public
library code (#637). `bitflags/src/tests.rs` and its 33 `src/tests/*.rs` children are all declared
by `src/lib.rs`'s `#[cfg(test)] mod tests;`, so reachability is what reports them. That second half
is `classify_rust_files`' own `syn` walk, deliberately not
a call into `CrateGraph` — that walk skips `#[cfg(test)]` modules outright (#621), so it cannot
tell "test-only" from "not reached at all", and an unreferenced *library* leftover must stay
scored. Neither `clean` nor `encoded` moved in absolute terms; both ratios rose because the
denominator shrank. See `tests/conformance/COVERAGE_STUDY.md`.

**That reachability walk is anchored on a CRATE ROOT, and a missing anchor is now FATAL (#648).**
`crate_root()` looks for `lib.rs` / `main.rs` / `src/lib.rs` / `src/main.rs` under the studied
subtree; until #648, not finding one returned an empty exclusion set and the run carried on, so a
pin whose `lib` pointed one level too deep, a crate whose root moved, or a refactor of that
resolver switched the only working half of the rule OFF — all 34 files re-entered the denominator
and `coverage_table.py` read the jump in `scored` as an improvement to ratchet UP. It is now an
error naming every path searched, the package root it did find, and the opt-in. A subtree that
genuinely has no crate root (a bare directory of `.rs` files) is declared, per pin, with
`"crateRoot": "none"` — or `--no-crate-root` for the ad-hoc `--package/--source-dir` invocation;
any other value of that key is itself an error. No pin needs it today. The second line of defence
is in `coverage_table.py`: an `excluded` that drops to 0 while `scored` rises by at least that many
files is a BREACH naming the readmitted population, not a raise.
Every other scored file is an `encode-error`: the encoder's documented gaps
(proc-macro / `#[derive]` item invocations, the unmapped `assert!` family,
`impl` self types that are not a plain named type) are present in essentially
every real crate
file, and a file that clears one gap lands on the next. That is the honest
number, not a cherry-picked one — do not "improve" it by changing the pin list,
and **do not expect a closed gap category to move it** (see "Tuple + unit
structs" below for the measured before/after histogram that proves it usually
does not).

The study is **crate-aware** since #491's `encode_crate` slice: `study_directory` walks each
package's `mod` graph once and encodes every file it reached with the crate's symbol table in
hand. `rq1-study --single-file` turns that off and reproduces the older, per-file measurement, so
a before/after is one binary over one checkout. Each file's JSON row carries `crateModule` —
`null` means the walk never reached that file (a `#[cfg(test)]` module, an unreferenced leftover)
or could not run at all, which is a materially different outcome from "measured crate-aware and
still failed" and is never folded into the crate-aware count.

**Run it from a per-worktree `CARGO_TARGET_DIR`, never a shared one.** Two concurrent lanes (or a
worktree plus the main checkout) pointed at the same target directory will serve each other a
stale `rlib` from an in-flight edit, producing a red that reproduces nowhere in the affected
lane's own diff — a false red that cost a day on 2026-09-13. `export
CARGO_TARGET_DIR="$PWD/.cargo-target"` inside the worktree before any `cargo` command, and keep
that path gitignored.

**Re-measuring Tier A: quote THIS invocation, verbatim, in the PR body** (advisory 3 of #634's
review). A reported number that does not say which binary produced it, over which pins, at which
checkout, cannot be reproduced or challenged — and a Tier A figure is exactly the kind of claim a
reader has no other way to check:

```bash
bash tools/coverage-study/clone_pins.sh tools/coverage-study/packages/rust.json "$CHECKOUTS"
cd rust
export CARGO_TARGET_DIR="$PWD/../.cargo-target"   # per-worktree, never shared — see above
cargo run -p ball-rq1-study --bin rq1-study -- \
  --pins ../tools/coverage-study/packages/rust.json \
  --checkouts "$CHECKOUTS" \
  --json "$CHECKOUTS/tier_a.json" | tee "$CHECKOUTS/tier_a.log"
```

Those are the same two commands `coverage-study.yml`'s `rust-tier-a` job runs, so a local number
and a CI number are comparable. Quote the harness's own `Results:` and `excluded (test-only):`
lines verbatim, never a paraphrase, and state the head SHA they were taken at. Add `--single-file`
only to reproduce the pre-crate-aware per-file measurement — and say so in the same breath, since
the two are different populations.

`cargo test -p ball-rq1-study` is the harness's own self-test and **is gated on
every PR** in ci.yml's `rust` job. The RUN is the `rust-tier-a` job
in `coverage-study.yml`, which has **no `pull_request:` trigger** — the row is
absent, not green, on a PR; it is floored by ratchet in that workflow's
`publish` job. Methodology and the funnel's meaning:
`tests/conformance/COVERAGE_STUDY.md`.

## Package Layout

| Crate | Path | Purpose | Status |
|-------|------|---------|--------|
| `ball-lang-shared` | `rust/shared/` | Protobuf bindings (`prost`/`prost-reflect`) + runtime value types (`BallValue`/`BallList`/`BallMap`/`BallFunction`/`BallMessage`) + universal std module builders (a PORT of `dart/shared/lib/std*.dart`, gated name-for-name AND `outputType`-for-`outputType` by `src/std_dart_parity.rs` — port every `_fn(...)` change in the same PR, #505/#557) + `runtime::*` base-op helpers | Complete (#34, #35) |
| `ball-lang-compiler` | `rust/compiler/` | Ball → Rust compiler | Complete (#36-38) |
| `ball-lang-encoder` | `rust/encoder/` | Rust (`syn` AST) → Ball encoder | Complete (#42-43) |
| `ball-lang-macro-expand` | `rust/macro-expand/` | `macro_rules!` expansion for the encoder, quarantining rust-analyzer's `ra_ap_mbe` behind a four-item API | Complete (#629) — see "`macro_rules!` expansion" below |
| `ball-lang-engine` | `rust/engine/` | Self-hosted Ball engine (compiled from `dart/self_host/engine.ball.json`) | **Complete** (#39/#300) — runs the corpus at Dart parity (319/319), see below |
| `ball-engine-regen` | `rust/engine/tool/` | Internal helper crate: regenerates `rust/engine/src/compiled_engine.rs` | Complete, run manually |
| `ball-lang-cli` | `rust/cli/` | `ball run`/`compile`/`encode`/`check`/`info`/`validate`/`tree`/`version` CLI | Complete (#41/#304, #365) — clap subcommands; `run` behind `self_host`, `info`/`validate`/`tree` behind `cli_core` (no `audit` — #362 residual) |
| `ball-cli-regen` | `rust/cli/tool/` | Internal helper crate: regenerates `rust/cli/src/compiled_cli.rs` | Complete, run manually |

The conformance harness (#40) is `rust/engine/tests/self_host_conformance.rs` — it
prints the canonical `Results: N passed, M failed, T total` line and is run in CI
(the `rust` job). CI/CD wiring is in `.github/workflows/ci.yml`.

A second, **measurement-only** sweep lives beside it:
`rust/engine/tests/roundtrip_conformance.rs` (issue #452 item 3) drives every fixture
Ball → Rust (`ball-lang-compiler`) → Ball (`ball-lang-encoder`) → the **Dart reference engine**
→ golden diff. Both the compile and the re-encode step are in-process on the emitted Rust as
*text*, so `rustc` is never invoked per fixture — the whole 321-fixture sweep is ~7 s. It
measured a flat **0/321** from the day it shipped until issue #642: the compiler emits a flat
program dispatching through `ball_lang_shared::runtime::*` over `BallValue`, which the syntactic
`syn` encoder was never built to re-parse — and its row had no floor on `passed`, so that zero
read green on every run. #642 closed the three shapes that blocked EVERY fixture (the
unconditional oneof `LazyLock` statics, the entry IIFE, the `BallValue::*` constructors) and put a
positive floor + ratchet on the row (`RUST_ROUNDTRIP_FLOOR` via `tools/ci/roundtrip_floor.sh`).
#693 (the `&mut` alias hang) took it to 99, #692 — the runtime's COLLECTION constructors and
the `__ball_register_types` class prologue, see "Conventions" below — to **109 of 360**
(run 35550645549; 109 of 358 when it was measured at 34803611448, before two fixtures joined the
corpus and neither round-tripped — the denominator moves on its own, the floor does not), and
#712 to **121 of 361** (run 35557346693): the spliced collection-literal lowering stopped
emitting `Vec::new()`/`matches!`, and `ball_iterate`/`ball_spread_iter` gained their
universal-`std` inverses, so every fixture whose compiled output carries a `for-in` loop or a
spliced literal re-encodes now.
#692's 124 and #712's 121 are two INDEPENDENT measurements of the same row, each taken on its own
branch against the same 109 baseline; neither is the merged total and they must never be added.
The merged tree MEASURES **138 of 362** (run 35561847017, job 106216902719), and
`RUST_ROUNDTRIP_FLOOR` is 138 — the number a run printed, not one derived from two. The leader at
138 is still `ball_message_type_name` (#718), which is what the row's own "first still-failing
fixture" line names (`101_simple_class`).
The leader is `ball_message_type_name` (#718's dispatcher scrutinee), which is what the row's
own "first still-failing fixture" line named at 121 (`101_simple_class`); re-measure
`ball_arg_get` and `BallFlow::Normal` from a run's artifact before quoting their counts — the
pre-#712 figures (59 and 25) were taken at 109 and the population moved under them.
It is `#[ignore]`, so `cargo test --workspace` in the PR-gated `Rust` job never runs it:

```bash
cd rust && cargo test -p ball-lang-engine --test roundtrip_conformance -- --ignored --nocapture
```

Its CI home is the `rust-roundtrip` row in `.github/workflows/conformance-matrix.yml`.
**That workflow is a PR gate since #619** — it has a path-filtered `pull_request:` trigger sharing
its `push` filter, and `rust/**` is in that filter, so the row runs on any PR touching this
directory with no `gh workflow run` dispatch. It gates harness health, the positive floor and the
ratchet — plus, since #693, **no fixture may HANG**.

### The launcher path, and the per-fixture budget — both self-tested (#692/#693)

Two things about this harness are proven rather than assumed, and both were found by a
measurement that looked plausible and was wrong.

**The root handed to the Dart CLI must be a path the Dart CLI accepts (#692).** `repo_root()`
used `Path::canonicalize`, which on Windows always returns a `\\?\` VERBATIM path — and
`dart run \\?\…\ball.dart` prints `\\?\ prefix is not supported` on stderr and **exits 0**. So
the sweep's `code != 0` arm never fired, every fixture came back as a golden MISMATCH
(`expected(5): 1 | actual(0): <none>`), and the leg reported a confident `Results: 0 passed` that
was entirely a launcher artifact. CI runs the row on `ubuntu-latest`, where `canonicalize` adds
no prefix, so the row was never wrong — every local Windows run of it was, which is exactly the
kind of defect a measurement-only row cannot afford.
`the_repo_root_handed_to_the_dart_cli_is_not_a_verbatim_path` asserts the stripping AND that the
launcher still resolves under the result: a prefix check alone would pass on a root pointing
nowhere.

**A fixture must not be able to hang (#693).**
The leg shells out to the Dart CLI per fixture, so a re-encoded program that never terminates
would wedge the row's 90-minute job rather than report anything. That is not hypothetical: the
`&mut` alias bug below made **28 loop fixtures** re-encode "clean" and then hang, and the
60-second per-fixture kill is the only reason the row reported them instead of timing the job out.

- The budget is `BALL_TIMEOUT_MS` (default 60 000) — the same spelling
  `go/engine/conformance/roundtrip.go` uses. A non-integer value is a hard error, never a silent
  fallback. It is configurable *so that it is testable*: a hard-coded constant is a budget nobody
  has measured.
- `a_runaway_fixture_is_killed_at_the_budget_and_reported_as_a_timeout` is the self-test. It
  builds a **fabricated runaway** with `rustc` at test time (a program that ignores its arguments
  and never exits), drives it through the real `run_dart` path, and asserts it comes back as the
  `__timeout__` sentinel inside the configured budget. The sweep is `#[ignore]`d, so
  `cargo test --workspace` runs this on every PR and `-- --ignored` runs the sweep alone; the
  non-ignored tests that write the environment serialize their write-then-spawn window on
  `ENV_LOCK`, which is what makes their `set_var` sound (a `Command::spawn` reads the
  environment, and edition 2024 makes a concurrent write UB).
- **The kill reaches the whole process TREE, not just `dart` (#791).** `dart run` is a launcher:
  it forks the Dart VM, and the VM is what runs the program and holds the inherited stdout pipe.
  Killing the launcher alone left one orphaned VM per timed-out fixture alive in the runner —
  invisible to the self-test above, which only ever asserted the HARNESS came back. `run_dart`
  spawns the child as its own process-group leader (`CommandExt::process_group(0)`) and
  `kill_process_tree` kills the GROUP (`libc::kill(-pid, SIGKILL)`; `taskkill /T /F /PID` on
  Windows), matching `RoundTripLeg.cs`'s `Kill(entireProcessTree: true)`.
  `a_timed_out_fixture_leaves_no_orphaned_descendant_process` is the negative control: a
  fabricated stand-in that forks a grandchild inheriting its stdout, asserting the GRANDCHILD is
  gone through a heartbeat file it appends to every 50 ms (with a positive floor on that file, so
  a control that failed to fork anything cannot pass while proving nothing).
- A `timeout` outcome is a **hard error** in `tools/ci/roundtrip_floor.sh`, not one more increment
  of `failed`. Folded into the failure count it is indistinguishable from a golden mismatch, and
  the ratchet can only notice it once enough fixtures hang to push `passed` under the floor. All
  four round-trip rows measured **zero** timeouts before that gate was switched on (run
  34791323674, main).

## Build & Test

**`cargo` is not on native Windows in this environment — build/test via WSL.** From a
Windows shell, wrap commands like `wsl.exe -e bash -lc "cd /mnt/d/packages/ball/rust && cargo build --workspace"`.
`rust-toolchain.toml` pins `channel = "stable"` with `rustfmt`/`clippy` components, so a bare
`cargo` in the repo picks up the right toolchain automatically once `rustup` has it installed.

```bash
cd rust
cargo build --workspace
cargo test --workspace              # ball-lang-engine's self-hosted driver is feature-gated off by
                                     # default (see "Self-hosted engine status" below), so this
                                     # stays green on the wrapper foundation, not the compiled engine
cargo test -p ball-lang-shared           # proto round-trip + std module builder tests
cargo test -p ball-lang-compiler         # expression/base-call/type-emit tests + end-to-end (compiles
                                     # emitted Rust with `cargo run` and asserts on stdout)
cargo test -p ball-lang-encoder          # syn AST -> Ball tests + end-to-end (encode -> compile -> run)
cargo test -p ball-lang-engine           # loader/scope/ball_proto wrapper-foundation tests
cargo fmt --check
cargo clippy --workspace
```

**Prefer conformance tests over unit tests where they exist.** `ball-lang-compiler` and
`ball-lang-encoder` both have `tests/end_to_end.rs` suites that compile emitted Rust with the real
`cargo`/`rustc` toolchain and assert on actual stdout — this is the same "compile → execute
with the native toolchain → compare" idiom `ts/compiler/test/` uses. The whole-corpus
conformance runner is `rust/engine/tests/self_host_conformance.rs` (`--features self_host`,
`#[ignore]` by default) — it drives every `tests/conformance/*.ball.json` through the
self-hosted engine and prints `Results: N passed, M failed, T total` (#40).

## Generated Files — NEVER Edit

- `rust/shared/gen/*.rs` — protobuf bindings generated by the
  `buf.build/community/neoeinstein-prost:v0.4.0` plugin (there is no official
  `protocolbuffers/rust` plugin) via the root `buf.gen.yaml`. Regenerate with `buf generate`.
- `rust/engine/src/compiled_engine.rs` — the self-hosted engine compiled from
  `dart/self_host/engine.ball.json`. **Gitignored** (like C++'s `engine_rt.cpp`, unlike TS's
  committed `compiled_engine.ts`) because it does not yet build. Regenerate with
  `cargo run -p ball-engine-regen`; never hand-patch it — fix `rust/compiler/` or the Dart
  self-host source instead.
- `rust/cli/src/compiled_cli.rs` — the self-hosted cli-core report functions
  (`info`/`validate`/`tree`/`version`) compiled from `dart/self_host/cli.ball.json`. **Gitignored**,
  same reasoning as `compiled_engine.rs`. Regenerate with `cargo run -p ball-cli-regen` (which
  itself needs `dart/self_host/cli.ball.json` — `cd dart && dart run
  compiler/tool/gen_cli_json.dart`); never hand-patch it — fix `dart/shared/lib/cli_core.dart` or
  `rust/compiler/` instead. See `rust/cli/AGENTS.md`.

## Key Dependencies

- `prost = "0.14.4"` + `prost-reflect = "0.16.4"` (pinned exact versions) — `prost-reflect`'s
  `DescriptorPool`/`DynamicMessage` give the descriptor-driven reflection later phases need
  (`MessageCreation`, `google.protobuf.Struct` metadata). Google's upb-based `protobuf` v4 crate
  was rejected — it exposes no reflection API.
- `indexmap = "2"` — backs `BallMap` (`IndexMap<String, BallValue>`) so map iteration order
  matches every other engine's insertion-ordered map (Dart's `LinkedHashMap`-backed `Map`, C++'s
  `BallOrderedMap`). Do NOT use `HashMap` for anything Ball-value-shaped.
- `syn = "2"` (`features = ["full", "extra-traits", "visit-mut"]`) + `proc-macro2` + `quote` —
  the encoder's Rust source parser, the Rust analog of Dart's `analyzer` / TS's
  TS-Compiler-API. `visit-mut` is what `ball-lang-macro-expand`'s hygiene pass and the
  encoder's expansion driver walk the tree with.
- `ra_ap_mbe` / `ra_ap_tt` / `ra_ap_span` / `ra_ap_intern`, all `= "=0.0.351"`, plus
  `salsa = "0.28"` and `serde_json = "1"` — **only** in `ball-lang-macro-expand`. The `=` pins
  are mandatory, not cautious: `ra_ap_mbe` pins its own siblings with `=`, so a mixed set does
  not resolve at all. **Dependabot's `cargo-minor-patch` group will file no-op PRs against
  these**; bump all four together, deliberately, when rust-analyzer's weekly release is worth
  taking. See "`macro_rules!` expansion" below.

## `macro_rules!` expansion (issue #629)

### The design of record, in one paragraph

`rust/encoder` used to refuse an item-level macro loudly, because a macro at item position can
be the very thing that DEFINES a type the rest of a file calls into — skipping it orphans those
references. Closing that needs real expansion, and the owner's 2026-09-14 decision was to use
**rust-analyzer's own macro-by-example engine**, published for stable toolchains as
`ra_ap_mbe`, rather than a per-macro desugaring (there is no `bitflags`-shaped special case
anywhere — grep for it) or a hand-written matcher/transcriber. The engine and its
`ra_ap_*`/salsa stack are confined to **`rust/macro-expand/`**, so `ball-lang-encoder` names no
`ra_ap_*` type and a later engine swap is a one-crate change.

### What was MEASURED, and what it is worth

Against the pinned Tier A corpus (`tools/coverage-study/packages/rust.json`, 5 crates, 119
files, 110 scored), by macro class over the scored files:

| class | invocations | scored files touched |
|---|---:|---:|
| builtin / std-prelude family (`assert_eq!`, `write!`, `vec!`, …) | 401 | 71 |
| local `macro_rules!` (same crate) | 225 | 22 |
| dependency-defined `macro_rules!` | 2 | 1 |
| proc-macro (function-like or attribute) | **0** | 0 |

Restricted to what `EncodeCrate` actually walks, **only 4 of the 110 scored files are
first-blocked by a `macro_rules!` invocation** (`itertools/cons_tuples_impl.rs`,
`itertools/unziptuple.rs`, `bitflags/tests/bitflags_match.rs`,
`bitflags/tests/iter_equal_names.rs`). The 28-file `TestFlags` bucket #629's prose attributes to
macros is **not** a macro bucket: `TestFlags` comes from a `bitflags!` invocation inside
`#[cfg(test)] mod tests`, which `crate_graph.rs` deliberately does not walk (#621), and those
files then need generic bounds, associated-type paths and `impl Trait` parameters as well. So
expansion moves first blockers; on its own it converts no additional file to clean. Say that
plainly rather than implying a moved floor.

Zero non-builtin attribute macros and zero function-like proc-macros occur in the corpus, so
keeping proc-macros out of scope and loud costs it nothing.

### How it works

- **Token bridge, never text** (`macro-expand/src/bridge.rs`). `syn` already holds the tokens,
  so the bridge walks `ItemMacro.mac.tokens` / `Macro.tokens` straight into `ra_ap_tt` and back.
  Measured reasons not to go through text: `ra_ap_syntax_bridge::parse_to_token_tree` **panics**
  on a doc comment, and `SyntaxNode::to_string()` on an expansion emits no whitespace at all.
  Two pitfalls are encoded there: a `LitKind::Str`'s `text()` is unquoted-but-still-escaped (so
  `Literal::string(text)` double-escapes), and `Spacing::JointHidden` maps to `Joint`.
- **Two fixed span anchors**: file 0 for every token of a DEFINITION, file 1 for every token of
  an INVOCATION. That is all the engine needs, and it makes every output token's origin
  recoverable — the only reason a hygiene approximation is possible.
- **One `salsa::DatabaseImpl` per `MacroTable`**, created once and reused, exactly as
  rust-analyzer's own `crates/mbe` tests do.
- **Resolution** (`macro-expand/src/table.rs`): a 2+-segment path names a crate and requires an
  `#[macro_export]`ed definition; a builtin name is routed away untouched; an alias recorded from
  `use dep::{mac as alias};` is followed; a single segment is looked up crate-wide, and two
  definitions of one name with **differing rules** are a loud ambiguity rather than a silent
  first-wins (identical redefinitions — `heck` defines `t!` once per test module — are not).
- **Dependency definitions** (`macro-expand/src/deps.rs`): `cargo metadata --format-version 1`
  gives `resolve.nodes[].deps[]` (with `deps[].name` being the alias the code writes) and
  `packages[].targets[].src_path`. Every `.rs` file under a direct dependency's lib source
  directory is parsed and its `#[macro_export] macro_rules!` items collected — the whole
  directory rather than the `mod` graph, because `#[macro_export]` hoists to the crate root
  whatever module declares it. `proc-macro` targets are skipped by design. **A path the walk
  cannot LOOK at is recorded, never skipped** (#678): a subdirectory whose `read_dir` fails, an
  entry that cannot be read out of its directory, a path whose metadata cannot be stat'ed (a
  dangling symlink) each go through the same `note_unreadable_source` an unparseable file uses,
  and both `Unresolved` and the `<krate>::<name>!` `DependenciesUnavailable` then name it. "Not
  found" and "could not look" are different answers, and only one of them is evidence that a
  definition does not exist.
  **The same holds one step earlier, for the dependency EDGES** (#705).
  `direct_dependency_sources` resolves each `deps[]` entry through its `name`, its `pkg`, the
  `packages[]` entry that id names, that package's `lib`/`rlib`/`dylib` target and that target's
  `src_path` — five lookups, and each used to be a bare `else { continue }`, so a malformed
  `cargo metadata` document made a whole crate's macros unresolvable while the diagnostic claimed
  the crate had no such macro. Each is now a `note_unresolvable_dependency` riding the same list
  into the same two diagnostics. The ONE deliberate silence is a `proc-macro`-only package: that
  skip is a documented answer, and noting it would put every ordinary `#[derive]` dependency into
  the diagnostic of every failing resolution. `MacroTable::seed_from_cargo_metadata_json` exists so
  those shapes are testable at all — `cargo` only ever emits well-formed output, so they are
  unreachable through the `cargo`-running entry point (`tests/deps_metadata_shapes.rs`).
- **The driver** (`encoder/src/macro_expand.rs`) runs as a **pre-pass**, before the encoder's own
  `fn_params`/`enum_names`/`method_params` collection and before `collect_symbols`, because an
  expansion introduces declarations those passes must see. It iterates to a **fixed point** (a
  self-recursive macro comes back partly expanded — measured), with a **depth limit of 128**
  matching rustc's default `recursion_limit`. Item, `impl`-item, `trait`-item, statement and
  expression positions are all handled; `macro_rules!` definitions are removed from the item list.
- **Hygiene is approximated, and says so** (`macro-expand/src/hygiene.rs`). `ra_ap_mbe` is not
  hygienic on its own: `($e:expr) => {{ let x = 1; $e + x }}` invoked with `x` expands to
  `{ let x = 1 ; x + x }`. Definition-origin identifiers are marked in the token stream on the
  way out, then every marked identifier in a binding/variable/label position whose name is bound
  by the expansion is α-renamed to `<name>__ball_mbe<N>`; call-origin identifiers are never
  touched. Keywords are left unmarked (marking `let` would make the expansion unparseable) and
  raw identifiers keep their raw-ness through a second prefix.
- **`$crate`** is rewritten to `crate` for a local definition and to the dependency's name for a
  dependency one. Never dropped.

### Deviations, each deliberate

- **Editions**: `Edition::CURRENT` is used uniformly for both the definition's context edition
  and the expansion. `ra_ap_mbe`'s edition sensitivity is confined to `expr` fragment handling
  and raw-ident rules, and this is what rust-analyzer's own tests do.
- **Textual scope is approximated by a crate-wide lookup.** The ambiguity check above is what
  keeps that honest.
- **Mixed-site hygiene is approximated, not implemented.** Real mixed-site hygiene lives in
  rust-analyzer's `hir-expand` `SyntaxContext` transparency chain, which needs a populated salsa
  database of `MacroCallLoc`s the expander alone does not give you. A definition-origin binding
  whose name also appears inside a nested, not-yet-expanded macro invocation's opaque token soup
  is a loud `UnclassifiedHygiene`, never a guess.
- **Every call into the engine sits behind `catch_unwind`** and re-raises as a named
  `MacroError::EnginePanic`. These are rust-analyzer's internal crates, published for reuse but
  written to `unwrap()` — a bare panic reaching the Tier A harness would be scored as a Ball
  encode error with an inscrutable message.

### Failure modes — all loud, each named

| situation | behaviour |
|---|---|
| name not resolvable | left in place for the encoder's own loud refusal (the proc-macro boundary) |
| definition fails to parse | `DefinitionNotParseable`, naming the module |
| invocation matches no rule / leftover tokens | `NoExpansion`, quoting the arguments |
| expansion does not re-parse as `syn` | `NotParseable`, quoting the emitted tokens |
| depth > 128 | `DepthLimit`, naming the chain |
| same name, differing rules | `Ambiguous`, listing the origins |
| dependency graph unreadable | `DependenciesUnavailable`, naming the crate and the reason |
| a dependency source `syn` cannot parse | recorded, and named in the diagnostic of any macro that then fails to resolve |
| a dependency DIRECTORY or entry that cannot be read (#678) | recorded the same way — an unreadable subdirectory or dangling symlink is never mistaken for "no definition there" |
| a `cargo metadata` dependency EDGE that cannot be followed (#705) | recorded the same way — a `deps[]` entry with no `name` or no `pkg`, a `pkg` id with no `packages[]` entry, a package with no library target, a library target with no `src_path`. A `proc-macro`-only package stays silent BY DESIGN |
| engine panic | `EnginePanic`, with the payload |
| proc-macro / `#[derive]` / attribute macro | unchanged — the encoder's existing loud panic |
| builtin the encoder does not model | unchanged — keeps issue #630 separately trackable |

### Publishing

`ball-lang-macro-expand` is **published** like the other members. `cargo publish --workspace`
refuses a `publish = false` dependency of a published crate, so a `publish = false` quarantine
was not an option; it carries `version.workspace = true` and sits in the publish DAG ahead of
`ball-lang-encoder`.

## Self-Hosted Engine Status (#39/#300) — Complete, at Dart parity

The self-hosted engine compiles through `ball-lang-compiler` **and runs the whole
conformance corpus with Dart-identical output**: `Results: 363 passed, 0 failed,
363 total` (the 4 golden-less resource-limit/sandbox fixtures — 196/197/201/202 —
are documented behavioral carve-outs, skipped like the Dart runner skips them).
The compiled-engine driver is behind the `self_host` cargo feature (the generated
`compiled_engine.rs` is a gitignored build artifact, so a default build without it
stays green on the wrapper foundation); regenerate + run with:

```bash
cd dart && dart run compiler/tool/gen_engine_json.dart   # regen engine.ball.json
cd ../rust && cargo run -p ball-engine-regen             # regen compiled_engine.rs
cargo test -p ball-lang-engine --features self_host --test self_host_run          # acceptance
cargo test -p ball-lang-engine --features self_host --test self_host_conformance \
  -- --ignored --nocapture                               # whole-corpus sweep (Results: line)
```

See `rust/engine/AGENTS.md` for the resolved-bucket history and regeneration
instructions.

## Conventions

- Compiler and encoder both emit/parse as strings/AST via `syn`, mirroring the C++ prototype's
  string-concatenation style more than Dart's `code_builder`/`analyzer` structural approach.
- Every compiled Ball expression evaluates to a `ball_lang_shared::BallValue` — there are no "void"
  expressions in the compiler's output (even `print` compiles to a block ending in
  `BallValue::Null`), so every expression position (block tail, `if`/`else` branches, function
  bodies) is uniformly type-correct.
- The encoder has **no `rust_std` base module** — every Rust construct (operators, control flow,
  iterator sugar, `?`, `if let`, `while let`) expands into universal `std`/`std_collections`
  calls, exactly like the Dart encoder's cascade/null-aware-access/spread expansion. This is
  invariant, not optional — see `ball-lang-encoder`'s module doc comment
  (`rust/encoder/src/lib.rs`).
- **`try` dispatches EVERY catch clause, in source order** (issue #615). `compile_try` emits an
  `if`/`else if` chain over the recovered payload: an `on <Type> catch` clause runs only when
  `ball_catch_matches(&__err, "<Type>")` accepts the thrown value's type tag (a
  `BallValue::Message`'s `type_name` or a `BallValue::Map`'s `__type__`, matched by FULL
  `main:StateError` or BARE `StateError` spelling, as `_evalLazyTry` does in
  `dart/engine/lib/engine_control_flow.dart`); the first untyped `catch (e)` is the `else`; and a
  clause list where every typed clause misses runs `finally` then `ball_throw(__err)`, so an
  enclosing `try` sees the original value. Before #615 only `catches.first()` was compiled, as an
  unconditional catch-all, so `throw StateError(...)` ran an `on ArgumentError catch` body —
  silently wrong output, never an error. `ball_throw` also mirrors `std.throw`'s
  `arg0` -> `message` rename (`engine_std.dart`), so a caught `e.message` reads the constructor
  argument rather than null; `_ball_rethrow_err` still binds the ORIGINALLY caught value, bound
  once before any clause binds its own variable. Guards:
  `tests/conformance/464_typed_catch_clause_dispatch` and `146_nested_try_catch_types`
  cross-target, plus the PR-gated `rust/compiler/tests/catch_clause_dispatch.rs` and
  `runtime.rs`'s `catch_matches_*`/`throw_aliases_arg0_as_message`. Those are what gate the SHAPE:
  the `rust-compiler` leg that compiles the whole corpus is a PR gate since #619, but it is a
  RATCHET on a passing count (`RUST_COMPILER_FLOOR`), and 146 had been failing there — inside the
  floor, so green — since that leg came online.
- **Compiler ↔ encoder round trip is an INVARIANT (#632).** Every construct `ball-lang-compiler`
  emits must be one `ball-lang-encoder` can read back — Tier A's stage 3 re-encodes this repo's
  own compiler output, so a mismatch caps that column however good either half is alone. The
  measured instance: `type_emit.rs::compile_method_dispatchers` emitted its fallback arm as a bare
  `panic!` while `methods.rs::encode_macro` refused `panic!`, so every library whose compiled
  output carries a method dispatcher — every library with a struct and a method — failed stage 3
  with ``unsupported macro invocation `panic!` ``. Neither crate's own tests could see it:
  `rust/compiler`'s assert on emitted Rust, `rust/encoder`'s start from hand-written Rust. The
  gate is `rust/encoder/tests/compile_reencode_roundtrip.rs`, which runs Tier A's three
  library-mode stages. Stage 3 is an **encode** gate for every program but one: the compiler's
  output names runtime helpers (`ball_message_type_name`, …) that are not user functions, so
  **re-compiling stage 3's output is not a fixpoint at large** — measured, and neither Tier A nor
  that test pretends otherwise. The exception is #692's
  `re_compiling_the_re_encoded_program_still_computes_the_same_answer`, which builds and RUNS both
  compiles of a program made of the collection/class constructs that slice taught the encoder; it
  became possible only once `__ball_register_types` stopped coming back as a user function (a
  second compile emitted it twice, `error[E0428]`). Since #646 reading those helpers is fail-loud: `runtime_helpers.rs` maps the
  ones with a universal-`std` inverse and an UNMAPPED `ball_*` aborts the file instead of becoming
  a same-file call to a function nobody declared. That table is the universal-`std` subset only,
  so a compiled library naming any other helper stops at the first one; never read a green run of
  that gate as "stage 3 is green for libraries at large". Sweep the difference, never quote it:
  `grep -ohrE '\bball_[a-z0-9_]+' rust/compiler/src/*.rs | sort -u` against the quoted names in
  `runtime_helpers.rs`. The behavioural half sits beside
  it: three cases compile the compiler's own output, link it against a hand-written `main`, and
  RUN it, asserting the thrown message as bytes. Extend that test when you add a compiler emission
  shape; never add a second, weaker round trip.
  **Enumerate what the compiler emits — the issue named one instance and the sweep found more.**
  Sweeping `rust/compiler/src` for constructs inside EMITTED string literals found, besides the
  `panic!` #632 closed: `unreachable!` (`flow_propagation` — a `break`/`continue` in a `try` with
  no enclosing loop), and, in `compile_list_literal`'s imperative lowering as it stood then,
  `let mut __lit: Vec<BallValue> = Vec::new();` together with the null-spread guard
  `if !matches!(__sp, BallValue::Null)`.
  `unreachable!` is now MAPPED: it encodes as the same `std.throw`, carrying Rust's own
  `internal error: entered unreachable code[: …]` message — **prefix included**, since that
  prefix is part of what a `catch` binds (`library/core/src/panic.rs`'s `unreachable_2021`), and an
  encode-only assertion could not have seen it dropped.
  The list-literal pair was **#712**, and is **CLOSED** — it was the broader of the two open
  instances, because that lowering is used by EVERY spliced collection literal (`std.spread`,
  `null_spread`, `collection_if`, `collection_for`) plus the map comprehension, so any library
  whose compiled output held one failed stage 3 — measured at `Vec::new()` first, with `matches!`
  behind it. Neither could be closed by widening the encoder: `matches!` is a pattern match over a
  runtime-crate enum variant and `Vec::new()` an associated fn on a foreign type, so an arm for
  either would encode a compiler-internal spelling while still refusing every real-world one —
  which is what Tier A measures. So the fix is **compiler-side**, in the plain-call style the
  neighbouring `ball_truthy`/`ball_iterate`/`ball_spread_iter` already use: the accumulator is a
  `BallList` built with `.push()` (`runtime_ctors.rs` inverts `BallList::new()` to an empty list
  literal, `methods.rs` maps `.push()` to `std_collections.list_push`), and the null guard is
  `ball_truthy(ball_not_equals(__sp.clone(), BallValue::Null))`, two helpers already in the table
  which compose to exactly what it means. That style no longer re-encodes *soft* — since #646 an
  unmapped `ball_*` is a hard refusal — so #712 also owed `runtime_helpers.rs` the inverses of the
  two helpers the loops themselves name: **`ball_iterate` joins `ball_truthy` as an identity
  passthrough** (it is the iteration coercion `std.for_in` performs implicitly, emitted at four
  sites, all for-loop iterables — so this widened re-encodability well past #712: every compiled
  `for-in` loop named it), and **`ball_spread_iter` maps to `std.spread`**, the exact inverse of
  the line that emits it. The two are deliberately NOT the same mapping: they differ on a portable
  set (`ball_iterate` yields `[key, value]` entry pairs, `ball_spread_iter` the backing items), so
  collapsing them would be silently wrong rather than loud. Gated by
  `compile_reencode_roundtrip.rs::spliced_collection_literal_compiler_output_re_encodes` (all four
  spliceable element kinds in one literal, driven encode → compile → encode) and its run-proof
  `a_spliced_collection_literal_still_splices_after_the_lowering_change` (compiles and RUNS it,
  diffing `[1, 2, 3, 4, 5, 6]` as bytes — an element that nested instead of splicing re-encodes
  just as cleanly and prints a different answer). `documented_gaps.rs`'s pin is flipped to
  `compiled_spliced_list_literal_re_encodes`; `the_matches_macro_is_a_documented_gap` KEEPS its
  `#[should_panic]` and is now a pin on the encoder's permanent boundary for hand-written Rust,
  not on a compiler emission. The **map** comprehension went through the same lowering and got the
  same fix, but its tail — `ball_map_create` over the local accumulator — is still refused. #692
  (#796) gave that helper a table arm AFTER #712 was written, so the refusal is now a SHAPE one
  raised by the arm, not the unmapped-helper fallthrough: the arm inverts a LITERAL
  `[[key, value], …]` pair list to the `entry`-shaped `std.map_create` it compiled from, and the
  comprehension's Ball node is a larger `map_create` carrying `element` fields. Pinned as
  `compiled_spliced_map_literal_stops_at_ball_map_create`, the compiler-output half of #692's
  hand-written-Rust pin `a_map_create_over_a_spliced_list_fails_loud`.
  The script-mode entry-point IIFE is
  **CLOSED**, and so is **#687**. #646's `lib.rs::as_zero_arg_closure` INLINES the closure body
  rather than emitting the `std.invoke`-over-`lambda` shape #687 proposed, and for the entry
  wrapper that is sound in both directions — a Ball `return` returns from the enclosing FUNCTION
  and the entry body IS the function body. Its pin is flipped to
  `compiled_entry_point_iife_encodes`, which asserts the entry body's `std.print` SURVIVES (a
  dropped body would not panic either). The open half — whether the IIFE is equally faithful for a
  NESTED block in value position — was answered by a run-proof, and it is an ENCODER question, not
  a compiler one: `compile_block` emits a native Rust block, so nothing nested is ever wrapped,
  but the unconditional inlining re-bound a `return` in the HAND-WRITTEN Rust this encoder reads.
  Inlining is conditional now, and #687's shape is what an early-exiting body gets — see
  "Immediately-invoked closures" below. The script-mode round-trip leg lives beside the
  library-mode ones in `compile_reencode_roundtrip.rs`.
  The invariant's **second** open instance is the compiled method dispatcher's scrutinee, **#718**: `compile_method_dispatchers`
  opens every instance-method dispatcher with `match ball_message_type_name(&__self).as_str()`,
  and that helper has no universal-`std` inverse — it returns the receiver's module-QUALIFIED tag
  (`main:Point`) while `std.type_of` (#489) returns the SHORT base name, so mapping one to the
  other would re-encode a dispatcher whose arms can never match its own scrutinee, and
  `dart/shared/std.json` declares no qualified-name function to map it to instead. It is a
  semantic merge conflict between #646 (the fail-loud table) and #685 (the first test that
  re-encodes a dispatcher), each green on its own branch; it reddened the required `Rust` context
  on `main`. Pinned by `compiled_method_dispatcher_scrutinee_is_a_documented_gap`; the
  dispatcher's behavioural half is untouched and still run-proved by
  `dispatcher_fallback_throws_the_target_neutral_message`. Whatever closes it must keep #646's
  fail-loud direction.
  `panic!` encodes to `std.throw` (field `value`), the shape `dart/encoder`'s
  `ThrowExpression` arm emits: on this target the two are literally one mechanism
  (`runtime.rs::ball_throw` IS `std::panic::panic_any`, and `ball_catch_payload` re-wraps a
  non-Ball payload as `BallValue::String(message)`), so a `catch` binds the identical value either
  way; a bare `panic!()` carries Rust's own `explicit panic` message, never `""`. The dispatcher
  fallback's message is target-neutral — `no method '<name>' for <type>`, byte-identical to
  `go/compiler/library.go` and `csharp/compiler/src/TypeEmit.cs`; the
  `ball-lang-compiler runtime:` prefix it used to carry was #616/#641 rendering drift in a spot
  no fixture observed.
- **Do not expect that fix to move Tier A's Rust row — measured, twice.** Stage 3 on the current
  pins is `1/77`, and it was `1/77` before the fix too
  ([34766105061](https://github.com/Ball-Lang/ball/actions/runs/34766105061) pre-fix,
  [34769384905](https://github.com/Ball-Lang/ball/actions/runs/34769384905) post-fix), because
  **stage 1 was the dam**: 76 of the 77 scored files failed `encode-error` on third-party Rust the
  encoder did not yet read, so only one file ever reached stage 3 — and no file in that run
  carried a `reencode-error` at all. The `panic!` gap is real and the round-trip gate proves it on
  the repository's own output; it is simply not what those pins are stopped on. A lane raising
  Rust's Tier A numbers works on stage 1, on the reasons that artifact names — read them with
  `gh run download <run-id> -n coverage-study-tier-a-rust`, **never from prose**, which is exactly
  what the six-gap list this bullet used to carry went stale by: see
  "#767's stage-1 gaps" below for the re-measured disposition of each.
- `rust/compiler/src/lib.rs` and `rust/encoder/src/lib.rs` document their own scope boundaries
  (documented gaps: multi-parameter lambdas, data-carrying enum variants, destructuring patterns,
  unmapped macros, etc.) — read those module doc comments before assuming a
  construct is unsupported by accident vs. by design.

### The runtime's collection constructors and the compiler's class prologue (issue #692)

`runtime_helpers.rs` maps the `ball_*` free functions the compiler emits for a base CALL.
`runtime_ctors.rs` is its sibling for the two shapes that are not calls into that table at all —
the biggest two buckets the `rust-roundtrip` row was first-blocked on (33 and 22 fixtures, plus
the 49 blocked on `BallValue::List`).

- **Collection constructors.** `BallValue::List(x)`/`BallValue::Map(x)` join the
  `BallValue::String(…)` identity arm (a Ball value is dynamic — the wrapper means nothing);
  `BallList::from(x)` is the same identity; `BallList::new()` is an empty list literal and
  `BallMap::new()` is `std.map_create` with no entries, the two nodes `dart/encoder` emits for
  `[]` and `{}`. Each arm defers to a file declaring its own type by that name.
- **The message builder is matched as ONE BLOCK.** `compile_message_creation` emits
  `{ let mut __ball_map = BallMap::new(); __ball_map.insert("x".to_string(), …);
  BallValue::Message(BallMessage::new("main:Point", __ball_map)) }` — an imperative builder.
  Taking it apart statement by statement would need an inverse for `BallMap::insert` and would
  produce a *different* node (a block that mutates a map) from the `message_creation` it compiled
  from, so `block.rs::encode_message_builder` matches the whole idiom and gives back the exact
  node. The match is STRUCTURAL — a fresh `BallMap::new()` binding, every intermediate statement
  an `insert` on it, a tail that consumes it — never keyed on the compiler's `__ball_map`
  spelling, and anything that is not the whole idiom falls through to ordinary block encoding and
  still fails loud on its unmapped `.insert()`.
- **`pub fn __ball_register_types()` is the class prologue, and it is DROPPED.** Its
  `ball_register_superclass(child, parent)` calls invert to the child `TypeDefinition`'s
  `metadata.superclass` — where `dart/encoder` writes it and `type_emit::superclass_of` reads it
  — and `fn main()`'s leading call to it is dropped in `block.rs`. Resolving the registration's
  SHORT `Dog` against a declared type has to undo `sanitize_ident` (the compiled struct for Ball's
  `main:Dog` is `main_Dog`), so `apply_superclass_registrations` accepts the short name itself or
  that name behind a `_`-joined qualifier and fails loud on zero or multiple matches. Any
  statement in that function that is not a two-string-literal registration is loud too, because
  the whole function is dropped and anything else in it would be silently lost.
- **Dropping it is what made the whole-program FIXPOINT reachable.** Before #692 a second compile
  emitted `__ball_register_types` twice (`error[E0428]`), which is why
  `compile_reencode_roundtrip.rs`'s own module doc comment ruled such a test out.
  `re_compiling_the_re_encoded_program_still_computes_the_same_answer` now builds and RUNS both
  compiles; it is the only assertion that can tell the `message_creation` the builder compiles
  from apart from some other structurally valid node.
- **Known, stated gap:** the compiled `pub struct main_Dog` re-encodes as the `TypeDefinition`
  `main:main_Dog` while the instances the same program builds still carry
  `BallMessage::new("main:Dog", …)`. That type-NAME infidelity predates #692; it is asserted, not
  papered over, in `the_compiled_class_registry_re_encodes_as_superclass_metadata`.

### The is/as registry and the map/set literal constructors (issue #692, second half)

Four more `ball_*` helpers that are NOT table rows, because the table's contract is "one
positional argument per input field". They have their own arms in
`lib.rs::encode_runtime_helper_call`; the gate is
`rust/encoder/tests/compiled_type_ops_and_literals.rs`.

- **The is/as registry's query side.** `ball_is`/`ball_is_not`/`ball_as` (`base_call.rs::
  compile_type_op`) and `ball_is_type` (`pattern.rs::type_check`, emitted for EVERY pattern type
  test) all invert through `runtime_helpers.rs::type_op_helper`. `ball_is_type` maps to the same
  `std.is` as `ball_is`, because it is the same discrimination — `ball_is` is literally
  `BallValue::Bool(ball_is_type(&value, type_name))` — and its bare-`bool` result has no Ball
  counterpart to preserve, since a Ball condition site coerces truthiness implicitly. The second
  operand must be a string LITERAL: `std.is`'s `type` field is one in the Ball node too
  (`dart/encoder` writes `type.toSource()` into it), so a computed type name genuinely has no
  node and fails loud. The old `runtime_helpers.rs` doc bullet excluding these ("no type-name
  string operands") is retired — it was keeping a supported shape out.
- **`ball_map_create` and `ball_set_create`** are the compiler's non-empty map/set literals
  (`BallMap::new()`/`BallList::new()` above are only the EMPTY ones). Their Ball inputs are
  *shaped*, not positional: `std.map_create` takes one repeated `entry` field per pair, each an
  anonymous `{key, value}` message-creation, and `std.set_create` names its list `elements`.
- **The operand is matched AFTER encoding, not on the `syn` tree.** A pair list arrives as
  `BallValue::List(BallList::from(vec![…]))` — three identity wrappers deep — and `encode_expr`
  already reduces every one of them to the list literal underneath, so `lib.rs::
  list_literal_elements` is the whole reader.
- **The COMPREHENSION lowering fails loud, deliberately.** `{for e in m.entries: k: v}` compiles
  to an imperative block that splices into a local `Vec` and hands `ball_map_create` that
  variable. Its Ball node is a `map_create` with `element` fields — a different, larger inverse —
  so encoding it as an entry-less `map_create` would silently compute `{}` (the issue #55 class).
  Both helpers panic naming the shape instead; `a_map_create_over_a_spliced_list_fails_loud` and
  its set twin are the pins.
- **Stated, pre-existing gap surfaced while measuring this: every compiled STRING literal
  re-encodes wrapped in `std.to_string`.** `compile_expression` emits a Ball string literal as
  `BallValue::String("a".to_string())`, and `.to_string()` is NOT one of `methods.rs`'s identity
  passthroughs — in hand-written Rust, which is this encoder's actual input, it genuinely IS
  `std.to_string`. Over a `String` that op returns its operand unchanged, so the re-encoded
  program computes the same answer; the extra node is a node-fidelity difference, not a
  behavioural one, and making it an identity would special-case a literal receiver on evidence
  nobody has measured. It is ASSERTED, not normalized away, in
  `a_compiled_map_literal_re_encodes_as_std_map_create` (the map KEYS come back as
  `std.to_string({value: "a"})`), so the day it changes, a test says so.
- **Measured yield:** the `rust-roundtrip` row moved **109 -> 124** of 361 (run 35556939950, job
  `Rust Round-Trip Leg (measurement)`), and `RUST_ROUNDTRIP_FLOOR` is raised to 124 in the same
  PR. All four of #692's blockers left the first-blocker histogram entirely — `ball_map_create`
  21, `ball_is_type` 18, `ball_set_create` 7 and `ball_is` 3 are each now zero. The leaders are
  `ball_arg_get` 61, `ball_message_type_name` 23 (#718), `ball_unsupported_base_call` 18 and
  `ball_iterate` 16. Quote the PASSED count, never the ratio: the denominator moves with the
  corpus and the floor is on the numerator alone.

### Immediately-invoked closures — inline only when the body cannot exit early (issue #687)

`(|| … )()` is the shape `rust/compiler` wraps each of its three **function** bodies in — the
entry `fn main()` (`lib.rs::compile_entry_main`, because `main` returns `()` while every compiled
expression is `BallValue`-typed), a method with instance-field write-back, and a body-carrying
constructor (both `type_emit.rs`). #646's `encoder/src/lib.rs::as_zero_arg_closure` inlines it into
the Ball `block` its body already is, and that is what makes those three re-encodable at all.

It is **not** the lowering of a value-position Ball `block`. `compile_block` emits a native Rust
block, because Rust blocks are already tail-expression-valued; C++ and Go do need an IIFE there,
which is exactly why *their* compilers route `return`/`break`/`continue` through runtime flow
signals and this one does not. Any note claiming the Rust compiler wraps a nested block in an IIFE
is stale — check `compile_block` before repeating it.

Inlining becomes unsound the moment the body can exit early, because that is the one way the two
constructs differ:

| | Rust `(|| { … return a; … })()` | Ball `block { … return a … }` |
| --- | --- | --- |
| where `return a` lands | the CLOSURE — the caller binds `a` and keeps running | the enclosing FUNCTION |

So the ordinary early-exit idiom `let x = (|| { if …{ return a; } b })();` inlined to a Ball block
that returned `a` from the enclosing function and skipped everything after it — a **well-formed**
Program with a different answer, which is why it is proved by building and RUNNING the compiled
output (`compile_reencode_roundtrip.rs::an_immediately_invoked_closures_return_stays_inside_the_closure`)
against what `rustc` prints for the same source, not by any assertion on the encoded shape.

When the body *can* exit early the faithful Ball is **`std.invoke` over a `lambda`** — the shape
`dart/encoder/lib/encoder.dart` emits for a `FunctionExpressionInvocation`, and the one
`compile_lambda` turns back into `BallValue::Function(BallFunction::new(…, move |input| { … }))`,
whose `return` leaves the closure again.

The early-exit set is **derived from what this encoder emits a `std.return` for**, never guessed
from syntax: `return` (`encode_return`) and `?` (`encode_try_operator`, which propagates by
returning the whole outcome). `break`/`continue` cannot occur — rustc rejects a loop jump crossing
a closure boundary. The scan (`closure_body_exits_early`) is a `syn::visit::Visit` rather than a
hand-written recursion, so every other node kind is covered by construction, and it stops at each
frame that owns its own `return`: a nested closure, a nested item, an `async` block, a `try` block.
Over-firing would be its own regression — every compiled program that builds a callback contains a
nested closure with a `return` — and `compiler_output.rs::a_return_inside_a_nested_closure_does_not_block_inlining`
is the negative control on it.

### Real-code coverage study (issue #491)

Issue #491 drove 196 files from 10 popular crates (anyhow, thiserror, semver, itertools, base64,
hex, smallvec, indexmap, once_cell, memchr) through `ball_lang_encoder::encode` and got **0/196**:
real library code is virtually never a single file with `fn main()`, and every failure landed on
one of the encoder's documented fail-loud panics. That is a **scope gap, not a defect** — but
nothing in CI ever *observed* those panics, because `rust/encoder/tests/end_to_end.rs`'s fixtures
are all single-file `fn main` programs (the shared conformance corpus is single-file-main-only by
construction).

`rust/encoder/tests/documented_gaps.rs` closes that observation gap: one `#[should_panic]`
characterization test per gap category (data-carrying enum variants, receiver-less associated
functions in `impl` and `trait` blocks, cross-file call targets, tuple/unit structs, non-`Fn`
`impl` and `trait` items, module-scope `const`/`static`/`type` and references to one, an `impl`
whose **self type** is not a plain named type, unmapped macro invocations at expression and item
level), each pinning the shortest stable
substring of today's panic. It runs on the required `Rust` CI check via `cargo test --workspace`.
**Keep it in sync with the module doc comments** — when a slice closes a gap, flip that test from
`#[should_panic]` to a real "encodes and round-trips" assertion in the same PR, so the module-doc
gap list and the enforced-in-CI list cannot drift apart again.

Two items are deliberately *not* pinned there, and the file says why: the no-`fn main` case is
covered end-to-end on the same leg from both sides — `rust/cli/tests/cli_encode.rs::
missing_fn_main_exits_2` for the default rejection and
`rust/encoder/tests/library_mode.rs` + `cli_encode.rs::encode_lib_flag_allows_missing_main`
for the `--lib` opt-in below — and the *compiler* side of receiver-less associated functions
already worked (`type_emit.rs::method_prologue`'s `is_static` bypass, fixture
`tests/conformance/105_static_methods.ball.json`, issue #288) — the remaining work there was
encoder-side mapping only, closed by slice 3 below.

**Read the study table's rows precisely.** `unsupported call target (only same-file functions)`
(15 files, `lib.rs::encode_call`'s path-based `ExprCall` fallback) and `unsupported method call,
callee not in this file` (24 files, `methods.rs`'s own panic on a `receiver.method(args)` whose
method name isn't in the `collect_impl_method_params` pre-pass) are **different rows against
different panic sites**. Slice 3 closed the first for the module-qualified free-function shape;
the second — the largest bucket in the study — was pinned by
`documented_gaps.rs::cross_file_method_call_is_a_documented_gap` (pinned, **not** closed: a gate
nothing observes is a missing-test bug in its own right) and is **closed now** by the crate-aware
encoder below.

It was deliberately NOT a same-day "add one dispatch arm" slice, and the reason is structural: the
free-function fix above worked because `other_file::helper(...)` carries a module-qualifying path
segment the encoder can read straight off the syntax and stash as an unresolved `ModuleImport`.
`receiver.method(args)` carries **no such qualifier** — there is no alias to attribute an
unrecognized method to — and this encoder is syntax-only (`syn`, no semantic model, the same
limitation Roslyn's C# encoder documents for itself), so on one file it cannot tell "an instance
method implemented in a sibling file" from "a typo" or "an unsupported built-in". The two honest
options were (a) a multi-file-aware entry point that pre-collects the crate's symbols before
encoding any one file, or (b) accepting it as a boundary the way `methods.rs`'s module doc names
`.next()`/`.unwrap_or_default()` as **permanent** carve-outs. The epic owner chose (a) on
2026-09-13; see "Crate-aware encoding" below.

#### Crate-aware encoding — `encode_crate` / `ball encode --crate` (issue #491)

`ball_lang_encoder::encode_crate(path)` (module `crate_graph.rs`) walks a crate's `mod` graph from
its root — `Cargo.toml` directory, `src` directory, or the root `.rs` file — and encodes **every**
file against ONE crate-wide symbol table. It is the Rust sibling of
`dart/encoder/lib/package_encoder.dart`. `ball encode --crate <dir>` is the CLI surface; `--lib`
on top forces library mode on a crate that does have a `fn main`.

- **Resolution follows the Rust reference** (<https://doc.rust-lang.org/reference/items/modules.html>):
  `foo.rs` **or** `foo/mod.rs` (both is an error, neither is an error), the declaring file's own
  directory for a mod-rs file and `<dir>/<stem>/` otherwise, `#[path = "…"]` relative to the
  declaring FILE's directory outside an inline block and to the nested directory inside one, and
  an inline `mod` block as its own module — with `#[path]` **on** an inline block replacing the
  component that block contributes, so the reference's `#[path = "thread_files"] mod thread {
  #[path = "tls.rs"] mod local_data; }` lands on `thread_files/tls.rs` (#626). **Test-only**
  modules are not walked — `cargo build` does not compile them either, and one `assert!` inside
  one would abort the whole crate encode. "Test-only" is the `cfg` predicate evaluated with
  `test := false` and every other leaf UNKNOWN, NOT a scan for a bare `test` ident: that scan
  matched `#[cfg(not(test))]` and silently dropped a module every ordinary build has (#626).
  `#[cfg(any(test, feature = "x"))]` is kept for the same reason — cargo builds it with the
  feature.
- **Output is multi-module, and needed no compiler change.** One Ball `Module` per Rust module
  (crate root → `main`, others keep their `::`-joined path); a cross-file call carries
  `FunctionCall.module`, which `type_emit.rs::resolve_user_call_name` — issue #38's multi-module
  output — already turns into the `<mod>::` qualifier, landing on the `pub fn <short>` dispatcher
  `compile_method_dispatchers` emits inside that module.
- **`crate::`/`self::`/`super::` resolve** in crate mode. `rust/encoder/src/lib.rs`'s module doc
  used to list those as a known limitation of the single-file fallback (they became an unresolved
  `crate` import); a crate walk knows what they name, and they are how real multi-file crates
  address each other.
- **What it narrows rather than removes.** A method NO file in the crate declares still fails
  loud (pinned:
  `crate_encoding.rs::a_method_no_file_in_the_crate_declares_still_fails_loud`). So does a method
  short name declared in two modules where the *call site's* module declares neither — the
  compiler's dispatcher resolves by short name within a module, so picking one would silently
  dispatch to the wrong body. A cross-module enum-variant read is refused with a message naming
  the owning module (the compiled enum namespace is not reachable by bare name from another
  module). A `mod` whose file is absent is a loud panic, never a dropped module.
- **Indexing must not fail loud where ENCODING must.** The walk catalogues the whole crate before
  encoding anything, so the index reads parameter names with its own non-panicking
  `simple_param_names` — reaching for `param_names_and_types`/`method_non_self_params` (which
  panic on a destructuring parameter, correctly, at their own encode sites) turned ONE such
  signature into "this whole crate gets no crate-aware measurement". That is not hypothetical:
  `itertools`' `fn cmp(&self, (c, t): …)` cost all of its files their crate context on the first
  real sweep.
- **Measured, with one binary over one checkout.** `rq1-study --single-file` reproduces the
  pre-crate measurement, so before/after is not a comparison of two harness builds. Over the 5
  pinned crates (110 scored files): stage-1 `1 encoded` **0/110 → 1/110**; clean stays **0/110**.
  The first-blocker histogram moves and is conserved — `unsupported method call` 18 → 11,
  `unsupported call target` 35 → 32, with 10 files clearing their first blocker and landing on a
  second, independent gap. `tools/coverage-study/baseline.json`'s Rust row is raised to the
  measured `encoded: 1` and **nothing else**; this is the first #491 slice to move the aggregate
  funnel at all, and it moved it by one file. Say that plainly rather than implying a floor jump.

#### Receiver-less associated functions + cross-file calls (PR #526, self-labelled "#491 slice 3")

Two more buckets closed, both encoder-side only (no compiler, proto or self-hosted-engine change):

- **`impl Point { fn new(x, y) -> Point { … } }` (26/196 files).** A receiver-less `impl` fn now
  encodes as a `metadata.kind = "method"` + `metadata.is_static = true` class member —
  the exact shape `type_emit.rs::method_prologue`/`compile_method_dispatchers` has supported since
  #288 — and a `Point::new(3, 4)` call site emits `FunctionCall{module: "", function: "new"}`
  packed with the callee's real parameter names and no `"self"` field.
  `rust/encoder/tests/static_methods.rs` is the proof: it encodes real source, compiles it through
  `ball-lang-compiler`, `cargo build`s it and asserts the program prints `7`.
  The **trait** sibling used to be described as one gap; it is two, and only one is still open —
  see "Default-bodied receiver-less `trait` functions" below.
- **`other_file::helper(1)` (15/196 files).** A module-qualified call whose callee this file does
  not declare no longer panics: it emits `FunctionCall{module: "other_file", function: "helper"}`
  plus a **source-less `ModuleImport`** on the `main` module — the proto's own "reference only"
  shape, matching `go/encoder/encoder.go`'s `ModuleImport{Name: name}` convention.
  Arguments pack **positionally** (`arg0`/`arg1`), because an external callee's real parameter
  names are unknown to a single-file encoder. The referenced module is deliberately never
  synthesised as a base module.

  **Module, not type**, and Rust's own naming convention is the discriminator: the fallback
  applies only when the segment immediately OWNING the function is `snake_case`. So
  `other_file::helper` and `std::cmp::max` encode, while `Vec::new()` and `std::vec::Vec::new()`
  keep failing loud — an associated function on a foreign type is not a missing module, and no
  import could ever supply it, so degrading it into an unresolved import would swap a loud failure
  for an unfixable one. Pinned both ways in `tests/cross_module_calls.rs`.

  The **verified** contract of an unresolved import (measured against the reference tooling, not
  assumed): a source-less import is structurally legal and deliberately unresolved.
  `dart/shared/lib/cli_core.dart`'s `validationErrors` never inspects `module_imports` and its
  `treeReport` renders exactly this shape as `ref only`; `dart/cli/lib/src/runner.dart`'s
  `ball build` counts an import as needing the resolver only when `whichSource() != notSet`; and
  `rust/cli/src/commands/check.rs`'s `validate_structure` likewise never inspects imports. So
  `ball check` **accepts** the program (pinned by `cli_check.rs::
  encoded_cross_file_call_is_structurally_valid_but_unresolved`) and it is deliberately not
  runnable until the referenced module is supplied — the same boundary library mode established
  for an empty `entry_function`. Known limitation, documented in `lib.rs`: a
  `crate::`/`self::`-qualified call to a same-file function is treated as external too.

  The C# encoder's own cross-file bucket (#492, bucket d) is still open; when it lands it should
  mirror this "emit an unresolved `ModuleImport` rather than fail" decision.

#### Default-bodied receiver-less `trait` functions (#491)

The "receiver-less associated function inside a `trait`" gap was ONE bullet describing TWO
structurally different things, and only one of them was ever a real gap. `types.rs::
encode_item_trait`'s guard fired unconditionally on `!has_self_receiver(&trait_fn.sig)` — before
it ever reached the `let is_default_bodied = trait_fn.default.is_some();` it computes three lines
later and already uses correctly for the has-`self` case. So a file merely *declaring*
`trait Maker { fn make(n: i64, m: i64) -> i64 { n + m } }` aborted wholesale.

The compiler needed **no change**, and that is provable by reading it rather than by guessing:
`type_emit.rs::compile_struct_def` filters a type's members with `.filter(|m|
!func_meta_bool(m, "is_abstract"))` — it never consults `metadata.kind`, so a trait-owned concrete
member lands in the same inherent `impl` block as an `impl`-owned one — and
`compile_method_dispatchers` applies its single-owner `is_static` shortcut (issue #288) by exactly
the same rule. A default-bodied receiver-less trait fn is therefore architecturally identical to
`impl Point { fn new(..) }` at every layer below the encoder.

The fix is three encoder-local edits: the guard keys on the missing **body**
(`is_static && !is_default_bodied`) rather than the missing receiver; the member carries
`metadata.is_static`; and a new pre-pass sibling, `types.rs::collect_trait_static_params`, registers
each default-bodied receiver-less member into `Encoder::static_method_params` under the same
`(owner short, method short)` key `collect_impl_method_params` uses — owner-qualified, so a
trait's `make` and an `impl`'s `make` cannot shadow each other.

**One subtlety worth the paragraph:** a receiver-less member's `metadata.params` must come from
`param_names_and_types`, **not** `method_non_self_params`. The latter unconditionally `.skip(1)`s
a leading `self` that isn't there, so it silently drops the member's FIRST real parameter.
`encode_item_impl` already branches on exactly this; `encode_item_trait` had to learn to. A
0- or 1-parameter example cannot expose it (an empty iterator skips nothing, and a single argument
is passed directly rather than packed under a field name), which is why the proof test declares
`fn make(n, m)` with two — reverting just that branch turns its assertion into
`left: ["m"], right: ["n", "m"]`.

Still open, deliberately: a **signature-only** receiver-less trait fn
(`trait Maker { fn make() -> i32; }`). Both compiler passes above skip every `is_abstract` member,
so a `Maker::make()` call site would have no dispatcher to resolve to — closing THAT does need
compiler-side work with no #288-style precedent, and
`documented_gaps.rs::trait_associated_fn_without_receiver_is_a_documented_gap` stays
`#[should_panic]` on that exact input. This slice NARROWED the gap; it did not close it.

Proof: `rust/encoder/tests/static_methods.rs::
default_bodied_trait_fn_without_receiver_encodes_and_round_trips` encodes a file carrying both a
trait (2-parameter default static, 0-parameter default static, `&self` default method) and an
`impl` (its own receiver-less associated fn), compiles it through `ball-lang-compiler`,
`cargo build`s it and asserts the program prints `12`.

**Measured, not predicted: Tier A did not move — and neither did the histogram.** Re-run on the
5-crate pin set with this fix in place: `Results: 0 passed, 110 failed, 110 total`,
`1 encoded: 0/110`, and a first-blocker histogram *identical* to the one the tuple/unit-struct
slice recorded above (call target 30, method call 16, top-level item 12, path expression 12,
macro 9, `impl` self type 8, expression kind 7, data-carrying enum 5). Not one scored file was
blocked FIRST by the trait guard, so narrowing it moved no category at all — a weaker result than
the tuple/unit-struct slice's, which at least emptied its own row. A default-bodied
*receiver-less* trait fn is simply a narrow Rust idiom; most default trait methods take `&self`.
Say that plainly rather than implying a moved floor. The value here is that a real gap was
narrower than three merged PRs' worth of documentation claimed, and that a latent
parameter-dropping defect (see the paragraph above) never shipped.

A neighbouring trait gap the same sweep showed as live: `only method signatures are supported
inside a `trait` block` — an associated `const`/`type` inside a `trait` — blocked 3 of the 110
files first. That was the `impl`-block tolerance of slice 5 not yet extended to `trait` blocks;
it is **closed now**, together with the module-scope `const`/`static`/`type` skip — see
"Module-scope `const`/`static`/`type` alias + trait-block associated items" below.

#### Non-`Fn` items inside an `impl` block (#491 slice 5)

`types.rs::encode_item_impl` used to `panic!` the instant its `for impl_item in &item.items` loop
reached anything that was not an `ImplItem::Fn` — so ONE associated `const` or `type` aborted the
whole file even when every method beside it encoded perfectly. It now **skips** the non-`Fn` item
and keeps going, exactly as the sibling pre-pass over the same syntax
(`types.rs::collect_impl_method_params`, an `if let … { … }` with no `else`) always did: this
slice makes two passes over one syntax tree agree, rather than inventing new tolerance.

Skipping cannot silently change what a program computes — a real *reference* to the dropped item
(`Self::CAP`) still fails loud on its own, at `lib.rs`'s "unsupported path expression" panic.
Proof: `rust/encoder/tests/mixed_impl_items.rs` encodes a mixed `impl`, compiles it through
`ball-lang-compiler`, `cargo build`s it and asserts the program prints `7`; the
`documented_gaps.rs` pin is flipped to a positive assertion in the same PR.

**Worth 14 of the 110 scored Tier A files** (e.g. `itertools/array_impl.rs`) — not the 22 an
earlier count claimed. That number conflated this bucket with a **separate** 8-file one: an `impl`
whose SELF TYPE is not a plain named type, which fails at `types.rs::type_short_name`'s
"unsupported `impl` self type" panic. Half of that one closed in #767 (a REFERENCE self type,
`&'a ChunkBy<…>`/`&mut I`, is looked through); the four genuinely non-nominal ones —
`(I::Item,)`, `[T; M]` and friends — stay refused, because Ball's class model keys members on an
owner's short *name* and a tuple or array type has none. See "#767's stage-1 gaps" below; both
shapes have their own `documented_gaps.rs` pin.

#### Tuple + unit structs (#491)

`types.rs::encode_item_struct` used to `panic!` the instant `item.fields` was anything but
`syn::Fields::Named`. All three shapes now produce the same class-shaped `TypeDefinition`; only
the field *names* differ — a named field keeps its identifier, a tuple element is declared under
its **positional index rendered as a decimal string** (`"0"`, `"1"`), and a unit struct declares
zero fields (an empty `DescriptorProto`, not a missing one).

That `"0"`/`"1"` spelling is load-bearing, not cosmetic: `types.rs::member_name` has always turned
a `syn::Member::Unnamed` *read* (`p.0`) into exactly that string, so declaration and read agree
with no translation table, and `ball-lang-compiler` treats a field name as an opaque map key
(`is_positional_arg_name` matches only `arg<digits>`, so a bare `"0"` is inserted verbatim). The
read side needed **no change at all** — `lib.rs::encode_field` and `member_name` were already
correct, and are now pinned by a test rather than re-derived.

**Declaration alone would have been a regression, not a fix**, so two `lib.rs` call sites landed in
the same PR. `Pair(3, 4)` is syntactically identical to a same-file function call, so `encode_call`
intercepts a known tuple-struct name *before* its `encode_user_call` branch and emits a
`message_creation`; `Marker` used as a value is syntactically identical to a variable read, so
`encode_path_expr` intercepts a known unit-struct name *before* its `reference(name)` fallback
(and *after* `is_current_multi_param`, so a same-named fn/closure parameter still wins — this
crate's established syntactic, name-only bias, deliberately not widened). Without those two, the
encoder would have traded a loud encode-time panic for a program that fails to build downstream.
Both sets are populated by the existing pre-pass in `encode_main_module`, because a use may
textually precede its declaration.

Proof: `rust/encoder/tests/tuple_and_unit_structs.rs` (encode → compile → `cargo build` → run,
asserting `7` and `42`); the two `documented_gaps.rs` pins are flipped to positive assertions in
the same PR.

**Measured, and do not let a reader infer otherwise: the Tier A aggregate does NOT move.** Before
and after, on the same 5 pinned crates and the same 110 scored files:
`Results: 0 passed, 110 failed, 110 total`, `1 encoded: 0/110`. The first-blocker histogram is
what changed, and it is exactly conserved:

| first-blocker category | before | after |
|---|---|---|
| `only a struct with named fields is supported` (this slice) | **14** | **0** |
| `unsupported macro invocation` (chiefly `write!`) | 2 | **9** |
| `unsupported Rust expression kind` | 4 | 7 |
| `unsupported top-level item` | 10 | 12 |
| `unsupported path expression` | 11 | 12 |
| `unsupported match pattern` | 0 | 1 |
| every other category (call target 30, method call 16, `impl` self type 8, data-carrying enum 5, …) | unchanged | unchanged |

All 14 files hit a **second, independent** documented gap immediately afterward — 7 of them
`write!`, which `methods.rs::encode_macro` did not map at the time.
**`write!` was therefore the measured next-highest-yield target**, alongside the already-known
cross-file method-call bucket; recording it here so the next slice did not have to re-derive it.
It is **CLOSED** by issue #630 — see "`write!`/`writeln!` and the declared text sink" below, the
first slice to move the Tier A aggregate by more than one file.
A closed category is a real win on its own terms — it is simply not an aggregate one, and the PR
that closes one must not imply that it is.

#### `write!`/`writeln!` and the declared text sink (issue #630)

The design record is `docs/SINK_DESIGN.md`; the owner approved it on 2026-09-13. PR #636
landed the three declarations `std.sink_create`/`sink_write`/`sink_to_string` (a `__type__`-tagged,
reference-semantic value — see `.claude/rules/rust.md`); the encoder half is this slice.

**`write!` needs no type information, and that is the whole design.** `core`'s own definition is
`($dst:expr, $($arg:tt)*) => { $dst.write_fmt($crate::format_args!($($arg)*)) }` — the destination
is a **method receiver**, so the first argument IS the sink by construction. rustc special-cases
only `format_args!` (rust-lang/rust#106745 moved it into the AST) and rust-analyzer makes the same
split (`format_args`/`format_args_nl` are builtin expanders; `write!`/`writeln!` go through
`core`'s ordinary `macro_rules!`). That matters concretely: **6 of the 7 first-blocked files write
through an unannotated closure parameter** (`|f| write!(f, "-")` in `heck`), which no inference
could resolve.

`methods.rs::encode_write_macro` therefore classifies the destination by **syntax alone**:

| destination | arm | emitted |
|---|---|---|
| anything that is not a local binding — a parameter, field, closure param, call result | (b) | `std.sink_write{sink, text}` |
| a bare name bound by a `let` whose initialiser is a `String` constructor | (a) | `std.assign{target, value: std.concat(target, text), op: "="}` |
| a bare name bound by a `let` of any other shape | — | **loud refusal** naming the local and its initialiser |

Arm (a) is the **join-sites** rule: in `itertools::join` the same local is *also* read as a
`String`, so making it an opaque sink would silently change those reads; guessing either way is a
behaviour change, so the third row refuses rather than pick. `writeln!` is `write!` + a `"\n"`
part (`core` spells its no-argument arm as literally `write!($dst, "\n")`), and both arms are
wrapped in the unified `Ok(..)` outcome because `write!` evaluates to a `fmt::Result` that 22 of
the 25 corpus sites consume with `?` or `.unwrap()`.

Three supporting changes ship with it. `Encoder::local_scopes` is a stack of binding frames — one per
fn / closure / `impl` method / default-bodied trait method, seeded with that body's parameters, and
one per `{ .. }` block, because a block's `let`s are gone at its closing brace and leaking one past
it leaves a shadowed parameter looking like a local; each frame is filled with its `let`s and looked
up innermost-first. It is deliberately **separate** from
`push_fn_scope`, which records parameters only for a 2+-parameter body and is not pushed at all for
an `impl` method; either would leave a parameter looking like a local, and a parameter misread as a
local `String` is the silent miscompile the frame exists to prevent. And `String::new()` /
`String::with_capacity(n)` now encode as the empty string — both were in the "unsupported call
target" bucket, so arm (a) would have been unreachable; capacity is an allocation hint with no
observable effect and Ball has no allocation model to carry it into.

**The capacity argument's EVALUATION survives, even though its value does not (#777).** Dropping
the hint is sound; dropping the expression that computes it is not —
`String::with_capacity(next_id())` runs `next_id()` in Rust, and before #777 the encoded program
did not, a silent degradation the pre-#630 "unsupported call target" refusal did not have.
`capacity_argument_is_evaluation_free` is the CLOSED set that keeps the bare empty-string fast
path: a literal, or a path read (a local, a `const`, a `static`), through `(…)`/group wrappers —
reading a place as a value runs no user code. Every other argument (a call, a method call, a
macro, an index or an arithmetic expression, both of which can panic) is encoded as the single
statement of a `block` whose `result` is the empty string, so the value is dropped and the
effects are not. Only WIDENING that set is unsound: the block wrapper is always correct, and it
is invisible to arm (a), which classifies the `syn` AST (`is_string_constructor`), never the
encoded node. The guard is behavioural, not structural — a dropped side effect still produces a
well-formed `Program`, so
`write_sinks.rs::with_capacity_still_evaluates_an_argument_that_has_a_side_effect` compiles and
RUNS the encoded program and asserts its stdout EXACTLY, with
`with_capacity_of_a_literal_or_a_plain_name_stays_a_bare_empty_string` as the control on the fast
path.

And a `&mut` ALIAS binding resolves to the variable it borrows before the table above is
consulted. `let slot = &mut s;` is recorded in `Encoder::ref_aliases` and emits no `let` at all
(issue #642 — Ball has no references), and every read of `slot` resolves back to `s` in
`encode_path_expr`; a `write!` destination is a read like any other, so `write!(slot, ..)` and
`write!(&mut s, ..)` take the same arm in both directions. Without the resolution the alias is
simply absent from every binding frame, which reads as "not a local": a local `String` would take
arm (b) and hand `std.sink_write` a plain string, which every engine and runtime rejects at RUN
time (`rust/shared/src/runtime.rs::sink_backing`) — loud, but one stage later than the encoder
can answer it. Only the MODELLED half resolves: an `AliasTarget::Opaque` binding (#693 — a borrow
of `p.x`/`v[0]`, which DOES emit a `let`) falls through under its own name and reaches the same
loud refusal `encode_assign` gives a plain write through it, because the binding it emits is a
copy.

And a **pattern** binding — a for-loop variable, a `match`-arm binding, an `if let`/`while let`
binding — opens a frame of its own (`Encoder::with_pattern_binding`), which also drops a `&mut`
alias of that name for its duration exactly as a plain `let` of it does. `record_local`'s only
call site is
the `let` handling, so without a frame a pattern binding is not merely unknown but **invisible**:
the innermost-first lookup walks past it to a same-named ENCLOSING binding, and an enclosing local
`String` is the one kind that does not fail loud —
`let mut s = String::new(); for s in writers.iter_mut() { write!(s, "x")?; }` re-assigned the outer
`s` and lost every write the Rust aims at an element, silently. It classifies as a **sink**, like a
parameter, never as a refusal: arm (a) is not expressible for a loop variable (whether writing to it
reaches the collection is not something Ball models), iterating real sinks is an ordinary working
shape, and a plain-`String` element lands in the documented boundary below and fails loud at RUN
time.

**Measured, on the 77 scored files** (the post-#648 denominator, not the 110 the histograms above
are written against), same 5 pins, by the repo's own instrument — a `Coverage Study` dispatch on the
branch, whose `Tier A (Rust)` job runs the exact `rq1-study` invocation `coverage-study.yml` pins and
whose `publish` job then checks the raised row against `tools/coverage-study/baseline.json`
([run 34788637747](https://github.com/Ball-Lang/ball/actions/runs/34788637747)). The "before" column
is that same baseline row, recorded by the last main run:

| funnel stage | before | after |
|---|---:|---:|
| 1 encoded | 1/77 | **7/77** |
| 2 compiled back | 1/77 | **7/77** |
| 3 re-encoded | 1/77 | 1/77 |
| 4 declarations kept | 0/77 | 0/77 |
| 5 fixpoint (clean) | 0/77 | 0/77 |

`baseline.json`'s Rust row is raised on `encoded` only. **`clean` does not move, and must not be
promised.** The wall for those 7 is stage 3, and **it is not #632 any more** — #632 was closed on
`main` by #685, and the last dispatch on this branch measured the six as
``reencode-error: unsupported runtime helper `ball_arg_get(...)` `` instead: the same
compiler↔encoder round-trip class, one construct further along, and squarely issue **#692**'s.
The seventh stops at stage 4, on declaration drift. A second pre-existing reason sits behind that
one: every `MessageCreation` — which the `Ok(..)` outcome is, and which a plain `Ok(x)` in
hand-written source always has been — compiles to `{ let mut __ball_map = BallMap::new(); … }`, and
`BallMap::new()` is an associated function on a foreign type the encoder documents as a permanent
gap (#692 again). Re-measure before quoting a wall: this one moved twice while the PR was open.

Tests: `rust/encoder/tests/write_sinks.rs` (27 cases — every destination shape, the newline rule,
the join-sites rule, the closure-, block- and pattern-shadowing traps, both directions of an alias
binding, both loud refusals, the `impl Display` shape the issue names, a real
`cargo build` of the compiled-back library, and an end-to-end run of the local-`String` arm).

#### Data-carrying enum variants are deliberately NOT bundled with the above

They look like the same "declaration shape" bucket and are not. `Point::new` was encoder-only work
because the *compiler* already had #288's `is_static` shape to map onto; a Rust sum type has no
such precedent. Closing it needs **both** an ADT representation decision for construction (Ball's
`TypeDefinition` has no variant-with-payload shape; the nearest neighbour is a `superclass`-per-
variant hierarchy — `type_emit.rs::superclass_of` exists, but nothing uses it this way) **and** new
`match`-arm support for type-tag patterns with field binding: `control_flow.rs::encode_match` has
exactly two arms today (`is_option_result_pattern`, `encode_literal_switch_match`), so matching a
user enum's variant name panics even in the *fieldless* case. Five first-blocked Tier A files, and
per the table above the aggregate would not move either. `data_carrying_enum_variant_is_a_documented_gap`
stays `#[should_panic]`, with this reasoning recorded in its doc comment.

#### #767's stage-1 gaps — tuple expressions, reference `impl` self types, and two carve-outs

Issue #767 collected the six stage-1 first-blockers from run
[34769384905](https://github.com/Ball-Lang/ball/actions/runs/34769384905) into a tracked list.
Every count below was **re-measured** over the same five pins with one binary and one set of
checkouts, before and after — the `before` reproduced `baseline.json`'s Rust row exactly
(`scored 77 / encoded 7 / compiledBack 7 / reencoded 1 / declarationsKept 0 / excluded 34`), which
is what makes the `after` a comparison rather than a fresh reading. One of the issue's six was
already stale by the time it was filed.

| gap | issue said | re-measured | disposition |
|---|---:|---:|---|
| `.finish()` | 9 | 9 | **permanent carve-out**, now pinned |
| non-plain `impl` self type | 8 | 8 | **half CLOSED** — 4 reference self types; 4 non-nominal ones pinned |
| `write!` | 7 | **0** | **already CLOSED** by #630/#698 — left the histogram entirely |
| tuple expressions | 6 | 6 | **CLOSED** |
| data-carrying enum variants | 5 | 5 | still open (see the section above) |
| non-identifier `Some`/`Ok`/`Err` bindings | 4 | **5** | still open |

**Tuple expressions.** `lib.rs::encode_expr` had no `syn::Expr::Tuple` arm at all.
`encode_tuple` lowers `(a, b)` to `std.record` — the universal base function
`dart/shared/std.json` declares for a positional record — with components named `"0"`/`"1"`, and
`()` to the Ball null literal. The component names are **Rust's own member spelling, not Dart's
`$1`/`$2`**, and that is a decision rather than an oversight: the READ side already produces the
decimal index (`lib.rs::encode_field` for a `t.0`, and `types.rs::encode_item_struct` for a tuple
STRUCT's fields — the `"0"`/`"1"` spelling the section above calls load-bearing), and `p.0` on a
tuple struct is syntactically indistinguishable from `t.0` on a tuple, so choosing `$1` would have
forced re-spelling the tuple-struct fields too. It stays portable: every target treats a component
name that is neither `$N` nor `argN` as an opaque key on BOTH the `record` build side and the
`field_access` read side (`cpp/compiler/src/compiler.cpp`'s `"record"` arm classifies it as a
*named* component, and its `.$N` rewrite does not fire; `dart/engine/lib/engine_std.dart`'s
`_stdRecord` hands the field map straight back). Proof:
`rust/encoder/tests/tuple_expressions.rs` — encode → compile → `cargo build` → run, printing a
hand-computed `14` and `true`, because a shape assertion would pass even if the compiled program
could not read a component back.

**Reference `impl` self types.** `types.rs::type_short_name` accepted only `syn::Type::Path`; it
now looks through `&T` / `&mut T` / `&'a T` (and `Paren`/`Group`) to the referent. Sound, not a
tolerance: Ball has no reference-vs-value distinction at all — `encode_expr` has always encoded
`&x` as `x` — so `impl Trait for &Counter` names the *same* Ball class as
`impl Trait for Counter`, and nothing is guessed from a name. That closes 4 of the 8:
`itertools/groupbylazy.rs` (`&'a ChunkBy<K, I, F>`), `itertools/peeking_take_while.rs`
(`&mut I`), `itertools/rciter_impl.rs` (`&RcIter<I>`), `strsim/lib.rs` (`&StringWrapper<'b>`).
The other 4 are genuinely non-nominal — `(I::Item,)`, `(ignore_ident!(l, A),)`, `[usize; K]`,
`[T; M]` — and stay refused; a tuple or array type has no short name to key members under.
**Consequence, stated rather than discovered:** an inherent `impl Counter { fn f }` and an
`impl Trait for &Counter { fn f }` in one file now register the same member name on the same
owner. Rust keeps them distinct and Ball cannot — but `impl Counter` and `impl Trait for Counter`
already collide identically, so this is the standing property of a short-name-keyed class model,
not something the reference arm introduces. Proof:
`rust/encoder/tests/impl_for_reference_self_type.rs`.

**`.finish()` is a PERMANENT carve-out, not a backlog item.** All 9 files are one construct:
`itertools`' `debug_fmt_fields!` (`src/impl_macros.rs`), which #629's `macro_rules!` expansion now
expands into `f.debug_struct("X").field("a", &self.a).finish()`, plus the hand-written
`debug_tuple(..).field(..).finish()` in `diff.rs` and `dbg.field(..).finish()` in
`exactly_one_err.rs`. The builder's OUTPUT is each field rendered through that field's own `Debug`
impl — type-directed formatting with no universal `std` counterpart, and `std.to_string` is a
*different* string — so an arm here would emit a program that runs and prints the wrong text:
silently wrong output, the failure mode this crate's fail-loud posture exists to prevent. The
receiver is also a caller-supplied `&mut Formatter` trait object with no Ball value behind it,
which is exactly the `.serialize_seq()`/`.is_human_readable()` class `methods.rs`' module doc
comment already names. `write!(f, "…")` on that same `Formatter` stays supported (#630) and is
not in tension: it carries its own literal format string, so the text it produces is in the
source. Pinned by `documented_gaps.rs::the_fmt_debug_builder_chain_is_a_permanent_carve_out`.

**Measured yield, stated plainly.** Stage 1 `encoded` **7/77 → 9/77**, `compiled back` **7 → 9**,
and the first-blocker histogram is exactly conserved at 77:
`unsupported Rust expression kind \`tuple\`` **6 → 0** and `unsupported \`impl\` self type`
**8 → 4**, with all ten of those files landing on a further gap. `reencoded` stays at **1** and
`baseline.json` is NOT raised on it: both files that newly reached stage 3 stop on
``unsupported runtime helper `ball_arg_get(...)` ``, the compiled parameter prologue tracked as
**#790**. Stage 3 is dammed by that helper now, not by stage 1 — closing further stage-1 gaps
cannot move it until #790 does.

**`excluded.json` is deliberately untouched.** It records the *test-only* files each harness takes
out of the denominator, and a path it lists that a run SCORED is a breach (#676). An encoder
carve-out is not a test-only file: those 9 + 4 files stay scored and stay failing, which is the
honest reading. Carve-outs live in the `methods.rs`/`types.rs` doc comments, the
`documented_gaps.rs` pins and this section.

#### A note on "slice N" labels

#491's issue body numbers its slices one way and the PRs that landed self-labelled *different*
work with the same ordinals — what the issue calls "slice 5" (tuple/unit structs) merged long
after a PR titled "slice 5" that closed non-`Fn` impl items, a gap discovered organically and
never in the issue's list. The headings in this file preserve the labels their PRs actually used;
**name a gap by its content from here on** (`tuple_and_unit_structs`, `data_carrying_enums`,
`method_call_cross_file`), not by an ordinal that no longer identifies anything.

**The concrete cost of that drift, recorded so it is not paid twice.** A 2026-09-13 dispatch
re-targeted "impl associated fns without a `self` receiver (26 study files)" and "same-file/
`use`-visible call targets (15 files)" as new work. Both were closed six weeks earlier, by
**PR #526** (`feat(rust,csharp): encode receiver-less associated functions and cross-file calls`,
merged 2026-09-03) — the PR the "Receiver-less associated functions + cross-file calls" section
above is now explicitly attributed to, and which appeared in no "landed" list the dispatch was
built from. The row counts in the issue body are from the ORIGINAL
196-file/10-crate characterisation and were never revised as slices landed, so reading them as a
worklist re-targets closed work.

The authoritative "what is still open" is not the issue body: it is
`rust/encoder/tests/documented_gaps.rs` (every remaining gap has a `#[should_panic]` pin; a closed
one is a positive assertion) plus a fresh Tier A run's first-blocker histogram. Check those two
before sizing a slice, and prefer `grep -c '^#\[should_panic' rust/encoder/tests/documented_gaps.rs`
over any prose count — including this file's. Anchor the pattern at the line start: the
unanchored form counts the file's prose mentions too (13 against 6 real pins, #626).

#### Module-scope `const`/`static`/`type` alias + trait-block associated items (#491)

Two sites that each aborted a whole file on one modelless declaration, closed together because
they are the same argument:

- `lib.rs`'s top-level item `match` had no arm for `syn::Item::Const`/`Static`/`Type`, so they
  fell through to the `unsupported top-level item` panic. A top-level **`type` alias was the
  first blocker for 7 of the 110 scored files** (`itertools/free.rs`, `size_hint.rs`,
  `intersperse.rs`, `merge_join.rs`, `grouping_map.rs`, `duplicates_impl.rs`,
  `combinations_with_replacement.rs`).
- `types.rs::encode_item_trait` panicked (`only method signatures are supported inside a trait
  block`) on the first non-`Fn` `TraitItem` — **3 of the 110**
  (`itertools/adaptors/map.rs`, `itertools/iter_index.rs`, `bitflags/traits.rs`). This is the
  "plausible cheap next slice" the previous section flagged; it is now closed.

Both now **skip** the declaration, exactly as `encode_item_impl` already does one level down.

**The module-scope skip needed a second half that the `impl`-block one did not**, and this is the
part worth remembering. `encode_item_impl`'s skip is self-securing because a reference to what it
dropped is `Self::CAP` — a two-segment path `encode_path_expr` already refuses. A module-scope
`const` is referenced as a bare `LIMIT`, a **single**-segment path that the very same function
would have passed straight through its `reference(name)` fallback, emitting a read of a binding
nobody declared: a silent degradation, not a loud failure. So `encode_main_module`'s pass 1
records every skipped name in `Encoder::skipped_item_names` and `encode_path_expr` panics at the
USE site, naming the declaration. Copying the `impl` precedent without that guard would have
traded a loud encode-time panic for a program that fails to build downstream.

**A top-level macro invocation is deliberately NOT included.** A macro at item level can be the
thing that DEFINES a type the rest of the file references — `bitflags::bitflags! { … }` produces
the `TestFlags` that every `bitflags/tests/*.rs` file then calls into, and those files are 28 of
the 110 scored (18 `unsupported call target` + 10 `unsupported path expression`, all on
`TestFlags::…`). Skipping the macro would orphan those references into a *more* confusing panic
naming a type that looks like it should exist. That bucket needs macro **expansion**, and is
pinned by `documented_gaps.rs::top_level_macro_invocation_is_a_documented_gap`.

Proof: `rust/encoder/tests/mixed_module_items.rs` (encode → compile → `cargo build` → run,
prints `11`) plus its loud-reference counterpart; three `documented_gaps.rs` pins land in the same
PR — `top_level_const_static_and_type_alias_encode` and `trait_associated_const_and_type_encode`
flipped positive, `reference_to_a_skipped_top_level_const_is_a_documented_gap` and
`top_level_macro_invocation_is_a_documented_gap` added. The trait-block gap had **no pin at all**
before this PR (it was reachable only incidentally through the receiver-less-fn characterisation,
which exercises a different failure in the same function), so the pin is added here, already
flipped — a gate nothing observes is a missing-test bug in its own right.

`item_kind_name`'s `const`/`static`/`type alias` arms are gone with them (unreachable now), and
the variants that CAN still reach the panic are named individually instead of collapsing to
`item`. That alone identified the three files the previous sweep could only report as an
unclassified `item`: `itertools/lib.rs` and `heck/lib.rs` are `extern crate`, and
`smallvec/rawsmallvec.rs` is a `union`.

**Measured before and after, same 5 pins, same 110 scored files: the aggregate does NOT move.**
`Results: 0 passed, 110 failed, 110 total`, `1 encoded: 0/110` both ways, so
`tools/coverage-study/baseline.json`'s Rust row (scored 110 / clean 0 / encoded 0) is unchanged —
nothing dropped, nothing to ratchet up. All 10 files land on a second, independent gap
immediately:

| first-blocker category | before | after |
|---|---:|---:|
| `unsupported top-level item` | 12 | **5** |
| `only method signatures are supported inside a `trait` block` | 3 | **0** |
| `unsupported call target` | 30 | 35 |
| `unsupported method call` | 16 | 18 |
| `unsupported Rust expression kind` | 7 | 8 |
| a `let` binding's non-identifier pattern | 0 | 1 |
| signature-only receiver-less `trait` fn | 0 | 1 |
| every other category (path expression 12, macro 9, `impl` self type 8, data-carrying enum 5, …) | unchanged | unchanged |

The 5 that still block on `unsupported top-level item` are the 2 macro invocations, 2 `extern
crate`s and 1 `union` named above — none of them a tolerance fix.

#### `.fuse()` / `.is_empty()` (#491 slice 6)

Two more arms in `methods.rs::encode_method_call`, chosen because they are the only members of
that file's catch-all bucket resolvable **without type information**:

- `.fuse()` joins the existing identity-passthrough arm beside `.iter()`/`.by_ref()` — a Ball
  `List` has no "already exhausted" state for a fused iterator to preserve.
- `.is_empty()` lowers to `std.equals(std.length(receiver), 0)`, reusing the very same universal
  `std.length` dispatch `.len()` already routes through, so it stays correct whether the receiver
  is a `String` or a `Vec` at run time — no new base function, no type inference.

Proof: `rust/encoder/tests/method_sugar.rs` (encode → compile → `cargo build` → run, asserts `13`).

**Both new arms defer to a same-file user method of that name**, unlike every older arm in the
file. Matching on the name alone is an inherent bias of a syntactic encoder — a user's
`fn len(&self)` has always encoded as `std.length` — but a `Vec`-backed struct's own `is_empty`
lowered to `std.length(struct) == 0` would be *silently wrong output*, the one failure mode this
crate's fail-loud posture exists to prevent, so slice 6 does not widen that bias. Pinned by
`method_sugar.rs::user_declared_is_empty_wins_over_the_builtin_arm`.

**The rest of that bucket is a PERMANENT carve-out, listed by name** in `methods.rs`'s module doc
comment so it stops being an unbounded TODO: `.next()` (stateful-iterator semantics Ball does not
have), `.unwrap_or_default()` (needs the receiver's `Default` impl), `.spilled()` (SmallVec),
`.iter_names()` (bitflags), `.serialize_seq()` / `.is_human_readable()` (serde trait-object
dispatch), `.ok_or()` (Ball's unified outcome shape has no distinct error channel), `.value()` and
`.multiunzip()` (resolvable only with the receiver's concrete type). Do not add an arm for any of
them without a type model — a guess here produces silently wrong output, not a loud failure.

#### Library mode — `encode_library` / `ball encode --lib` (#491 slice 2)

`ball_lang_encoder::encode` requires a `fn main()`; real library crates have none, which is the
single largest bucket in the study above. `ball_lang_encoder::encode_library` is the opt-in that
drops **only** that requirement — same walk, same std accumulation, same fail-loud panic on every
other documented gap. `ball encode --lib <source.rs>` is its CLI surface.

**A library-mode `Program` is deliberately not runnable.** It carries `entry_module = "main"`
(which `Compiler::compile_library` needs — it looks that module up to inline its items at the
crate root) and an **empty `entry_function`**. `Program.entry_function` is an unconstrained proto3
string, so that is structurally legal, and `ball check` correctly reports `missing entry_function`
(pinned by `cli_encode.rs::a_library_mode_program_is_rejected_by_check_as_non_runnable`).
**Never "fix" that by synthesising a fake entry function** — the C# encoder's `EncodeLibrary`
makes the identical call, and the two must stay consistent. `ball validate` (the self-hosted
cli-core verb) rejects it for the same reason and for the same correct cause.

`rust/encoder/tests/library_mode.rs` is the round-trip proof, not a shape assertion: it encodes a
`main`-less two-`pub fn` source, runs the result through `Compiler::compile_library`, and asserts
`cargo build` accepts the output as a real `[lib]` crate.

## Key Differences from Dart

- Rust has no garbage-collected dynamic `Object?` — `BallValue` is a hand-written `enum` so the
  compiler/engine can pattern-match exhaustively instead of relying on `dynamic`/`std::any`.
- `Block` compiles to a native Rust block expression (tail-expression-valued), not an
  immediately-invoked closure like the C++ compiler's blocks.
- Int arithmetic uses wrapping ops (`wrapping_add`/...) to match Dart's fixed-width 64-bit `int`
  (no overflow panics); `modulo` is Euclidean (sign of the divisor), matching Dart/`ball_dyn.h`,
  not Rust's native `%` (sign of the dividend).
- **`BallValue` has no `Set` variant**, so a `Set` is the portable tagged map
  `{'__ball_set__': [...]}` (issue #528) — the same shape C++'s `ball_make_set` builds and the
  self-hosted engine's `_ballSetOf` materialises. `ball_set_create` and every sibling op build and
  read that shape (see the `std_collections — sets` banner in `shared/src/runtime.rs`), so
  `std.type_of` and `ball_is_type(v, "Set")` answer `Set` on a directly-compiled program as well as
  under the self-hosted engine. Three details are load-bearing and easy to break: mutation reaches
  **through** the wrapper to the wrapped list's shared `Arc<Mutex<Vec>>` backing (`set_backing`,
  the analog of C++'s `_setBackingList()`), so a `set.add(x)` through one alias is observed through
  every other; `as_list` and `ball_field_get`'s virtual `length`/`isEmpty`/`first`/`last` see
  through the tag (Dart's `Set implements Iterable` — reading the one-entry wrapper made
  `{1,2,3,4,5}.length` answer `1`); and `write_entries` renders the tagged shape as `{1, 2}`, never
  `{__ball_set__: [1, 2]}`. Pinned by `runtime.rs`'s
  `set_create_produces_a_value_that_is_a_set_and_not_a_list` /
  `type_of_a_set_created_set_is_set` / `set_mutation_is_observed_through_every_alias` /
  `set_renders_as_a_brace_list_not_its_tagged_map` /
  `set_algebra_produces_sets_and_iterates_as_a_list`, which run on every PR.
- **`ball_set_add`/`ball_set_remove` answer a `bool`, never the set** (issue #545): they mutate
  the shared backing in place and return `true` only when the element was newly inserted / was
  actually present, exactly like Dart's `Set.add`/`Set.remove`. That is the ONE portable contract
  every target now implements — before #545 `ball_set_add` returned the set here, disagreeing
  with `ball_set_remove`'s own bool. Pinned by `runtime.rs`'s
  `set_add_remove_return_bool_and_mutate_in_place` and, cross-target, by conformance fixture
  `459_set_add_remove_bool`.
- **A named constructor (`Class.name(args)`) compiles** since #527. The Dart encoder emits it as a
  method call whose packed `self` field is a bare `reference{name: "Class"}` — a static, syntactic
  class name, not a value — so `compile_call` resolves it at COMPILE time to the class's associated
  fn (`self_field_class_reference` + `named_constructor_fn` in `type_emit.rs`), rather than letting
  `compile_reference` fall through to `Countdown.clone()` (`[E0425]`). **Shadowing wins**: a binding
  of that name is a real value and the call stays an ordinary dispatch. `body_constructor_fn` picks
  the UNNAMED (`new`) constructor only, so a `messageCreation` never runs a NAMED constructor's
  body. A constructor's `metadata.initializers` are also applied when it carries a body
  (`constructor_self_init` now lowers a literal initializer value through
  `lower_field_initializer`, not only the `field = param` shape). Fixtures
  `436_recursive_ctor_named` / `438_ctor_initializer_list_with_body` measure it end to end;
  `compiler/tests/named_constructor.rs` is the PR-gated guard.

## Publishing (crates.io) — issue #366

The five publishable crates ship to **crates.io** via
`.github/workflows/publish-crates.yml`. It is **tag-gated** — merging a PR never
publishes; a release only fires when a `rust-crates/vX.Y.Z` tag is pushed.

### Trigger & tag namespace

```bash
git tag rust-crates/v0.1.0 && git push origin rust-crates/v0.1.0
```

The `rust-crates/` **slash** prefix is deliberate: GitHub Actions tag filters
treat `*` as "any char except `/`", so `rust-crates/v0.1.0` does **not** match
the Dart channel's `*-v[0-9]+.[0-9]+.[0-9]+*` filter (`release-publish.yml`) —
the crates.io and pub.dev release channels never cross-fire. All five crates are
released together at the single `[workspace.package] version`.

### Dependency-DAG publish order

The workflow runs `cargo publish --workspace`, which computes the topological
order itself and waits for each crate to be index-available before its
dependents publish (no hand-rolled sleeps, no crates.io index-propagation race):

```
ball-lang-shared / ball-lang-macro-expand
    → ball-lang-compiler / ball-lang-encoder
    → ball-lang-engine
    → ball-lang-cli
```

`ball-lang-macro-expand` (issue #629) depends on nothing in this workspace, so cargo is free to
publish it first; `ball-lang-encoder` depends on it. It is published rather than
`publish = false` because `cargo publish --workspace` **refuses a `publish = false` dependency
of a published crate** — the quarantine is an API boundary, not a distribution one.

`ball-engine-regen` and `ball-cli-regen` carry `publish = false` and are skipped
automatically. `ball run`'s binary is `ball` (via `[[bin]]`), unrelated to the
pre-existing 2022 `ball` crate on crates.io.

### Generated-source packaging (the `include` arrangement)

`ball-lang-engine`'s `src/compiled_engine.rs` and `ball-lang-cli`'s `src/compiled_cli.rs`
are **gitignored** (generated by `ball-engine-regen` / `ball-cli-regen`). By
default `cargo package` skips gitignored files, which would ship broken crates.
Each crate sets `include = ["src/**/*.rs", "Cargo.toml"]`: per the [Cargo
reference](https://doc.rust-lang.org/cargo/reference/manifest.html#the-exclude-and-include-fields),
**specifying `include` disables gitignore-based file discovery entirely**, so
the listed glob packages the generated file regardless of `.gitignore`. The
workflow regenerates both files (Dart → `*.ball.json` → `cargo run -p
ball-*-regen`) **before** packaging, so the shipped copies are current.

### Published feature shape (working `ball run` out of the box)

The committed `default` features are **off** for `ball-lang-engine`
(`self_host`) and `ball-lang-cli` (`self_host` + `cli_core`) so a fresh-checkout
`cargo build --workspace` stays green without the dart+regen dance. For the
**published** crates the workflow flips the defaults **on** (a `sed` step, after
regen, before `cargo package`), so `cargo install ball-lang-cli` yields a working
`ball run` (self-hosted engine) plus `info`/`validate`/`tree` (cli-core) with no
`--features` flag. The flip is publish-time only; nothing is committed with the
defaults on.

### Version policy (issue #366 comment)

`ball version` reports the **ecosystem package version** — the crates.io
`ball-lang-cli` version, single-sourced from `CARGO_PKG_VERSION` (the cargo workspace
version). This is the deliberate cross-target decision: each CLI stays true to
its own registry (crates.io for Rust, npm's semantic-release line for
TypeScript, the pubspec version for Dart), rather than carrying a shared
cross-target toolchain string. There is intentionally **no** combined
`ball <pkg> (toolchain <repo-release>)` string.

### Auth: crates.io Trusted Publishing (OIDC) — required

Auth uses [`rust-lang/crates-io-auth-action@v1`](https://github.com/rust-lang/crates-io-auth-action)
(pinned to the v1.0.5 SHA): it exchanges the GitHub OIDC token
(`permissions: id-token: write`) for a short-lived crates.io token exposed as
`steps.auth.outputs.token` and auto-revoked in its post step. That token is
passed to `cargo publish` via `CARGO_REGISTRY_TOKEN`.

There is **no secret fallback**. The `continue-on-error` + `CARGO_REGISTRY_TOKEN`
**secret** path existed only to bootstrap release #1, because crates.io does not
allow a Trusted Publisher to be configured **until after** a crate's first publish
(RFC 3691). All five crates now have a Trusted Publisher, so the fallback is gone:
a silent fallback would let a broken or removed Trusted Publisher hide behind a
green run. If OIDC fails, the job fails.

### Maintainer setup (registry side) — DONE

All five crates are published and each has a Trusted Publisher configured
(repository `Ball-Lang/ball`, workflow `publish-crates.yml`, environment blank).
The `CARGO_REGISTRY_TOKEN` secret is no longer used by the workflow and can be
deleted.

Historical note, for anyone adding a SIXTH crate: crates.io does not allow a
Trusted Publisher to be configured until **after** a crate's first publish
(RFC 3691). A brand-new crate name therefore has to be claimed once with an API
token before OIDC can take over — which is why the workflow briefly carried a
`continue-on-error` auth step and a `CARGO_REGISTRY_TOKEN` fallback.

### Dart's `StateError`: typed AND readable (issue #616)

#597/#604 settled that `std_collections.list_find`'s no-match THROWS and that the throw is
typed. Neither settled what the program then OBSERVES — conformance fixture
`463_list_find_no_match` prints a hardcoded literal from its catch bodies — and every target
answered differently. Measured on `origin/main` before the fix, one program printing
`to_string(e)` from its catch: the Dart reference engine `Bad state: No element` (which is also
real Dart's `StateError('No element').toString()`), the TS self-hosted engine
`{message: No element}`, the Go self-hosted engine `main:StateError`.

The contract now has two halves at EVERY site that raises Dart's `StateError` — an empty
`.first`/`.last`/`.single`/`removeLast`/`reduce`, or a `firstWhere` with no match:

1. **TYPED** — the thrown value carries the type name `StateError`, so a program's own
   `on StateError catch` matches it. Several sites used to raise an untyped native fault that
   the compiled `try` could not see at all.
2. **OBSERVABLE** — it stringifies as Dart's own `StateError.toString()`, `Bad state: <message>`,
   so `to_string(e)` in the catch body reads the same here as on the Dart reference engine.

`tests/conformance/465_state_error_message` is the cross-target guard (it prints the caught
value for `list_find`'s no match AND `list_first` on an empty list — never a hardcoded string).
Per-target details are in `.claude/rules/<lang>.md`; the gap class is
`docs/TESTING_STRATEGY.md` §5b.
