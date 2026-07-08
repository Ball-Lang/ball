---
paths:
  - "rust/**"
---

# Rust-Specific Instructions

Rust is a **prototype under active construction**, not a finished target — the compiler and
encoder are complete and tested, but the self-hosted engine is blocked (#39), and there is no
CLI (#41), conformance harness (#40), or CI job (#44) yet. Do not describe Rust as able to run
Ball programs or pass conformance in any doc you touch until #39/#40 land — verify against
`rust/AGENTS.md`'s "Self-Hosted Engine Status" section and CI (`.github/workflows/ci.yml`) before
making claims.

## Build System

- `cargo` is not on native Windows in this dev environment — run all `cargo` commands via WSL,
  e.g. `wsl.exe -e bash -lc "cd /mnt/d/packages/ball/rust && cargo build --workspace"`.
- `rust-toolchain.toml` (`rust/rust-toolchain.toml`) pins `channel = "stable"` with `rustfmt` +
  `clippy` components — a bare `cargo` inside `rust/` auto-selects it via `rustup`.
- Cargo workspace root is `rust/Cargo.toml` (`resolver = "3"`), members:
  `shared`, `compiler`, `encoder`, `engine`, `engine/tool`, `cli`. Shared version/edition/
  license/dependency versions live in `[workspace.package]` / `[workspace.dependencies]` —
  member crates reference them with `{ workspace = true }`, never a repeated version string.

```bash
cd rust
cargo build --workspace
cargo test --workspace
cargo fmt --check && cargo clippy --workspace
```

## Package Structure

- `ball-shared` (`rust/shared/`) — protobuf bindings (`prost`/`prost-reflect`, generated into
  `rust/shared/gen/`) + runtime value model (`BallValue`/`BallList`/`BallMap`/`BallFunction`/
  `BallMessage`, `rust/shared/src/value.rs`) + std/std_collections/std_io/std_memory module
  builders + `runtime::*` base-op helpers consumed by the compiler.
- `ball-compiler` (`rust/compiler/`) — Ball → Rust compiler. `compile_expression` handles all 7
  expression node types; `base_call.rs` is the base-function dispatch table (delegates to
  `ball_shared::runtime`); `lvalue.rs` handles assignment/mutation; `type_emit.rs` handles
  `typeDefs[]` → struct/trait/enum + multi-module output.
- `ball-encoder` (`rust/encoder/`) — Rust → Ball via `syn` 2.x (`features = ["full",
  "extra-traits"]`). Routes every construct through universal `std`/`std_collections` — **no
  `rust_std` base module**, ever.
- `ball-engine` (`rust/engine/`) — self-hosted engine wrapper (`loader.rs`/`scope.rs`/
  `ball_proto.rs`) + generated, gitignored `src/compiled_engine.rs`. See
  `rust/engine/AGENTS.md` for the full self-host gap list; the compiled-engine driver is behind
  the off-by-default `self_host` cargo feature.
- `ball-engine-regen` (`rust/engine/tool/`) — `cargo run -p ball-engine-regen` regenerates
  `compiled_engine.rs` from `dart/self_host/engine.ball.json`.
- `ball-cli` (`rust/cli/`) — currently a placeholder `main()` printing a scaffold message; no
  subcommands wired (issue #41).

## Key Patterns

### Compiler

- `Compiler::compile` / `compile_library` (library mode has no runnable entry point — used for
  the self-host regen tool) emit Rust source **as strings**, closest in spirit to the C++
  compiler's string-concatenation approach (not Dart's `code_builder`/TS's `ts-morph`).
- Every compiled expression evaluates to a `ball_shared::BallValue` — there are no "void"
  expressions; side-effecting calls like `print` compile to `{ ...; BallValue::Null }` so every
  expression position (block tail, `if`/`else` arms, function bodies) stays type-uniform.
- `Block` compiles to a **native Rust block expression** (Rust blocks are already
  tail-expression-valued) — unlike C++'s immediately-invoked lambda pattern for blocks.
- Control flow (`if`/`and`/`or`/`for`/`for_in`/`while`/`do_while`) compiles to native Rust
  control flow, never a function call — lazy evaluation per invariant #4.
- Arithmetic semantics must match the Dart reference engine, not "whatever Rust's operator
  does": `modulo` is Euclidean (sign of divisor, via `ball_shared::runtime`), int ops use
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
- Documented gaps (see `rust/encoder/src/lib.rs` / `types.rs`): tuple/unit structs,
  data-carrying enum variants, receiver-less associated functions (`Point::new(...)` — would
  silently panic in `ball-compiler`'s `method_prologue`, so it's rejected rather than encoded).

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++: compile
  `dart/self_host/engine.ball.json` through `ball-compiler` into `src/compiled_engine.rs`.
- **Status: blocked, not runnable.** 186 `rustc` errors compiling the full self-hosted engine
  (down from ~414 → ~326). Resolved so far: oneof-discriminator enum constants, named/optional-
  param binding, the `__no_init__` sentinel, and the whole Dart-SDK method/type-ref surface
  (String/List/Map/Set/`num`/`int`/`double`/`RegExp`/`DateTime`/`File` — the `ball_shared::
  runtime::dartsdk` submodule). Still blocking: `ball_proto`/`std_convert` base dispatch,
  constructor/super-constructor inheritance, `Function.apply`/`List.indexWhere` (dynamic function
  dispatch), and the borrow-checker-vs-dynamic-value mismatches (the bulk of the remaining count).
  Full breakdown in `rust/engine/AGENTS.md`. The `self_host` cargo feature keeps the broken driver off by
  default; `cargo build -p ball-engine` / `cargo test -p ball-engine` are green on the wrapper
  foundation (`loader.rs`/`scope.rs`/`ball_proto.rs`) only.
- Do NOT wire new callers to `BallEngine::run` expecting real execution — it currently returns
  `EngineError::SelfHostPending` in the default (non-`self_host`-feature) build.
- Fixes to the blocking gaps belong in `rust/compiler/` (or the Dart self-host source, then
  regenerate) — never hand-patch `compiled_engine.rs`.

## Generated Files — NEVER Edit

- `rust/shared/gen/*.rs` — protobuf bindings from the `buf.build/community/neoeinstein-prost`
  plugin (root `buf.gen.yaml`; there is no official `protocolbuffers/rust` plugin). Regenerate
  via `buf generate`.
- `rust/engine/src/compiled_engine.rs` — gitignored (like C++'s `engine_rt.cpp`), regenerated
  via `cargo run -p ball-engine-regen`.

## Testing

- `cargo test --workspace` from `rust/` (via WSL). `ball-engine`'s compiled-engine driver is
  feature-gated off by default, so this stays green without depending on #39.
- `cargo test -p ball-compiler` / `cargo test -p ball-encoder` include `tests/end_to_end.rs`
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
