<!-- Parent: ../AGENTS.md -->

# Rust Implementation Agents

Rust implementation of Ball tools (epic #32). The full pipeline is in place —
compiler, encoder, self-hosted engine, and CLI — and the self-hosted engine now
**runs the whole conformance corpus at Dart parity** (`Results: 338 passed, 0
failed, 338 total`; the 4 golden-less resource-limit/sandbox fixtures are
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

Honest first baseline: **0/110 clean, 0 files even encoded** (5 pinned crates,
`tools/coverage-study/packages/rust.json`). Every scored file is an
`encode-error`: the encoder's documented gaps (item-level `const`/`static`/
`type`, tuple structs, methods declared in another file) are present in
essentially every real crate file. That is the honest number, not a
cherry-picked one — do not "improve" it by changing the pin list.

`cargo test -p ball-rq1-study` is the harness's own self-test and **is gated on
every PR** in ci.yml's `rust` job. The RUN is the report-only `rust-tier-a` job
in `coverage-study.yml`, which has **no `pull_request:` trigger** — the row is
absent, not green, on a PR. Methodology and the funnel's meaning:
`tests/conformance/COVERAGE_STUDY.md`.

## Package Layout

| Crate | Path | Purpose | Status |
|-------|------|---------|--------|
| `ball-lang-shared` | `rust/shared/` | Protobuf bindings (`prost`/`prost-reflect`) + runtime value types (`BallValue`/`BallList`/`BallMap`/`BallFunction`/`BallMessage`) + universal std module builders (a PORT of `dart/shared/lib/std*.dart`, gated name-for-name by `src/std_dart_parity.rs` — port every `_fn(...)` change in the same PR, #505) + `runtime::*` base-op helpers | Complete (#34, #35) |
| `ball-lang-compiler` | `rust/compiler/` | Ball → Rust compiler | Complete (#36-38) |
| `ball-lang-encoder` | `rust/encoder/` | Rust (`syn` AST) → Ball encoder | Complete (#42-43) |
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
*text*, so `rustc` is never invoked per fixture — the whole 321-fixture sweep is ~7 s. Its
honest baseline is **0/321**, exactly like the C# leg it mirrors: the compiler emits a flat
program dispatching through `ball_lang_shared::runtime::*` over `BallValue`, which the syntactic
`syn` encoder was never built to re-parse. It is `#[ignore]`, so `cargo test --workspace` in the
PR-gated `Rust` job never runs it:

```bash
cd rust && cargo test -p ball-lang-engine --test roundtrip_conformance -- --ignored --nocapture
```

Its CI home is the `rust-roundtrip` row in `.github/workflows/conformance-matrix.yml`.
**That workflow has no `pull_request:` trigger** — it runs on push-to-main, the weekly schedule,
or manual dispatch only, so the row is ABSENT (not green) on a PR. Dispatch it
(`gh workflow run conformance-matrix.yml --ref <branch>`) and read the run before merging a change
to this leg.

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
- `syn = "2"` (`features = ["full", "extra-traits"]`) + `proc-macro2` + `quote` — the encoder's
  Rust source parser, the Rust analog of Dart's `analyzer` / TS's TS-Compiler-API.

## Self-Hosted Engine Status (#39/#300) — Complete, at Dart parity

The self-hosted engine compiles through `ball-lang-compiler` **and runs the whole
conformance corpus with Dart-identical output**: `Results: 340 passed, 0 failed,
340 total` (the 4 golden-less resource-limit/sandbox fixtures — 196/197/201/202 —
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
  iterator sugar, `?`, `if let`) expands into universal `std`/`std_collections` calls, exactly
  like the Dart encoder's cascade/null-aware-access/spread expansion. This is invariant, not
  optional — see `ball-lang-encoder`'s module doc comment (`rust/encoder/src/lib.rs`).
- `rust/compiler/src/lib.rs` and `rust/encoder/src/lib.rs` document their own scope boundaries
  (documented gaps: multi-parameter lambdas, receiver-less associated functions, data-carrying
  enum variants, tuple/unit structs, etc.) — read those module doc comments before assuming a
  construct is unsupported by accident vs. by design.

### Real-code coverage study (issue #491)

Issue #491 drove 196 files from 10 popular crates (anyhow, thiserror, semver, itertools, base64,
hex, smallvec, indexmap, once_cell, memchr) through `ball_lang_encoder::encode` and got **0/196**:
real library code is virtually never a single file with `fn main()`, and every failure landed on
one of the encoder's documented fail-loud panics. That is a **scope gap, not a defect** — but
nothing in CI ever *observed* those panics, because `rust/encoder/tests/end_to_end.rs`'s fixtures
are all single-file `fn main` programs (the shared conformance corpus is single-file-main-only by
construction).

`rust/encoder/tests/documented_gaps.rs` closes that observation gap: one `#[should_panic]`
characterization test per gap category (tuple/unit structs, data-carrying enum variants,
receiver-less associated functions in `impl` and `trait` blocks, cross-file call targets,
item-level `const`/`static`/`type`, an `impl` whose **self type** is not a plain named type,
unmapped macro invocations), each pinning the shortest stable
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
different panic sites**. Slice 3 closed the first; the second is the largest remaining bucket, has
no `documented_gaps.rs` pin yet, and is the recommended next slice.

#### Receiver-less associated functions + cross-file calls (#491 slice 3)

Two more buckets closed, both encoder-side only (no compiler, proto or self-hosted-engine change):

- **`impl Point { fn new(x, y) -> Point { … } }` (26/196 files).** A receiver-less `impl` fn now
  encodes as a `metadata.kind = "method"` + `metadata.is_static = true` class member —
  the exact shape `type_emit.rs::method_prologue`/`compile_method_dispatchers` has supported since
  #288 — and a `Point::new(3, 4)` call site emits `FunctionCall{module: "", function: "new"}`
  packed with the callee's real parameter names and no `"self"` field.
  `rust/encoder/tests/static_methods.rs` is the proof: it encodes real source, compiles it through
  `ball-lang-compiler`, `cargo build`s it and asserts the program prints `7`.
  The **trait** sibling (`trait Maker { fn make() -> i32; }`) is still a documented gap on
  purpose — `compile_method_dispatchers` skips every `is_abstract` member, so a signature-only
  static trait item would have no dispatcher for a call site to resolve to.
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
earlier count claimed. That number conflated this bucket with a **separate, still-open** 8-file
one: an `impl` whose SELF TYPE is not a plain named type (`impl<I> Trait for (I::Item,)`, e.g.
`itertools/adaptors/mod.rs`), which fails at `types.rs::type_short_name`'s "unsupported `impl`
self type" panic. Ball's class model keys members on an owner's short *name*, so a tuple/GAT self
type has no owner to register them under — that needs a representation decision, not a tolerance
tweak, and now has its own `documented_gaps.rs` pin.

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
ball-lang-shared → ball-lang-compiler / ball-lang-encoder → ball-lang-engine → ball-lang-cli
```

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
