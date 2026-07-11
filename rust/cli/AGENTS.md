<!-- Parent: ../AGENTS.md -->

# `ball-lang-cli` — Rust Ball CLI

The binary `ball` (crate `ball-lang-cli`): `run`/`compile`/`encode`/`check` subcommands over
`ball-lang-engine`/`ball-lang-compiler`/`ball-lang-encoder` (issue #41), plus the self-hosted cli-core verbs
`info`/`validate`/`tree`/`version` (issue #365, compiled from `dart/shared/lib/cli_core.dart` —
see "cli-core adoption" below). Mirrors `dart/cli/` and `ts/cli/` where their subcommand shapes
overlap; narrower than `dart/cli` (no package-registry commands — `init`/`add`/`resolve`/
`publish` — and no `audit`, whose capability/termination analyzers don't self-host through the
encoder yet, see issue #362).

## Layout

- `src/main.rs` — `clap` (derive) CLI definition + subcommand dispatch + exit-code handling.
- `src/error.rs` — `CliError` (`Io`/`Parse`/`Runtime`) and the exit-code contract (see below).
  `From<ball_lang_engine::EngineError>` maps the engine's own error variants onto it.
- `src/loader.rs` — `load_engine(path)`: format-sniffs `.bin` (binary protobuf) vs. anything
  else (proto3 JSON) and loads via `ball_lang_engine::BallEngine::from_binary`/`from_json` — reused
  by every subcommand, per the issue's "the loader in ball-lang-engine handles both" note. `info`/
  `validate`/`tree` reuse it too, reading `BallEngine::program_value()` (the canonical
  proto3-JSON `BallValue` view) as the input the compiled `cli_core` functions expect.
- `src/serialize.rs` — `program_to_json`/`program_to_binary`: the reverse direction of
  `rust/engine/src/loader.rs`, for `ball encode`'s output.
- `src/panic_guard.rs` — `catch_panic_message`: converts a `ball-lang-compiler`/`ball-lang-encoder`
  `panic!` (their documented "fail loud on an unsupported shape" behavior — see each crate's
  own module doc comment) into a `CliError::Parse` instead of aborting the process with Rust's
  own exit code `101`.
- `src/output.rs` — `write_text`/`write_bytes`: `--output <file>` vs. stdout, shared by
  `compile` and `encode`.
- `src/compiled_cli.rs` — **generated, gitignored**; see "cli-core adoption" below.
- `src/commands/{run,compile,encode,check,info,validate,tree,version}.rs` — one module per
  subcommand.

## Exit-code contract (issue #41, extended by #365)

| Code | Meaning |
|------|---------|
| `0`  | success |
| `1`  | runtime error — a Ball program ran but failed (a `throw` that escaped `main`, or the engine reporting an error) |
| `2`  | invalid/unparseable program — bad `.ball.json`/`.ball.bin` shape, Rust source `encode` couldn't turn into a program, a loaded program was too malformed to compile, or `ball validate` found the program invalid |
| `3`  | file-not-found / other I/O error reading input or writing `--output` |

Every subcommand returns `Result<(), CliError>`; `main` prints `ball: <message>` to stderr and
exits with `CliError::exit_code()` on `Err`. `0` is simply the absence of an `Err` — never an
explicit branch, so a subcommand can't accidentally "succeed" without actually completing its
work. **Note:** the Dart CLI exits `1` (its one generic failure code) when `ball validate` finds
an invalid program; the Rust CLI maps that to `2` instead (`CliError::Parse`), matching its own
pre-existing "invalid/unparseable program" bucket (the same bucket `check`'s findings use) —
report *text* still matches Dart byte-for-byte, only the numeric exit code is adapted per target.

## `run` and the `self_host` Cargo feature

`ball-lang-cli` has its own `self_host` feature (`Cargo.toml`), off by default, forwarding to
`ball-lang-engine/self_host`. This mirrors `ball-lang-engine`'s own default-off design (see
`rust/engine/AGENTS.md`): `rust/engine/src/compiled_engine.rs` is a **generated, gitignored**
file (`cargo run -p ball-engine-regen`, which itself needs `dart/self_host/engine.ball.json` —
also generated, also gitignored) that is not present in a fresh checkout. Keeping `self_host`
off by default means `cargo build -p ball-lang-cli` / `cargo test -p ball-lang-cli` stay green without
that codegen step.

- **Default build:** `ball run <any valid program>` always reports a `Runtime` error
  (`EngineError::SelfHostPending`, exit `1`) — honest, never a false "success". Covered by
  `tests/cli_run.rs`'s `default_build_reports_self_host_pending_honestly_for_a_valid_program`.
- **`--features self_host`** (after `cargo run -p ball-engine-regen`): `run` actually executes
  the self-hosted engine. As of this writing that engine handles simple acceptance programs —
  `hello_world` prints `Hello, World!`, recursive `fibonacci(10)` prints `55` — see
  `rust/engine/AGENTS.md`'s "Self-host status" for exactly how far it currently reaches; a
  program beyond that surfaces the engine's own error, never a false success. Covered by the
  `#[cfg(feature = "self_host")]`-gated `self_host_hello_world_prints_greeting` /
  `self_host_fibonacci_recursion_matches_dart` tests in `tests/cli_run.rs` (mirroring
  `rust/engine/tests/self_host_run.rs`, but through the built CLI binary).

`compile`/`encode`/`check` are unaffected by this feature — they never touch the self-hosted
engine.

## `info`/`validate`/`tree`/`version` and the `cli_core` Cargo feature (issue #365)

`dart/shared/lib/cli_core.dart` is a Ball-portable library of `Program -> String` report
functions (`versionLine`/`infoReport`/`validationErrors`/`validateOk`/`validateReport`/
`treeReport` — plus `auditReport`, which is **not** wired here, see below) — the single source
of truth `dart/cli/lib/src/runner.dart`'s `info`/`validate`/`tree`/`version` verbs already call
natively. `cargo run -p ball-cli-regen` (`rust/cli/tool/`, mirroring `ball-engine-regen` almost
exactly) compiles it via `ball-lang-compiler` in **library mode** into `src/compiled_cli.rs`: since
`cli_core` is a plain function library (no classes, no interpreter loop, unlike the self-hosted
*engine*), the compiled output is directly-callable native Rust — `pub fn infoReport(input:
BallValue) -> BallValue`, etc. — no runtime-driving wrapper like `ball-lang-engine`'s
`run_self_hosted` is needed.

```bash
cd dart && dart run compiler/tool/gen_cli_json.dart   # regen dart/self_host/cli.ball.json
cd ../rust && cargo run -p ball-cli-regen             # regen src/compiled_cli.rs
```

- `src/compiled_cli.rs` is **generated and gitignored** (`rust/.gitignore`), same reasoning as
  `compiled_engine.rs` — never hand-patch it; fix `dart/shared/lib/cli_core.dart` (then
  regenerate `cli.ball.json`) or `rust/compiler/`.
- Gated behind `ball-lang-cli`'s own `cli_core` Cargo feature (`Cargo.toml`), off by default for the
  same not-present-in-a-fresh-checkout reason as `self_host` — **independent** of `self_host`:
  cli-core's functions are pure data transforms, not the interpreter.
  - **Default build:** `info`/`validate`/`tree` report an honest `Runtime` error (exit `1`),
    never false success — see each `src/commands/*.rs`'s `#[cfg(not(feature = "cli_core"))]`
    arm. `version` is the one exception: its whole logic is the one-line format `"ball " +
    version`, so `src/commands/version.rs` keeps a tiny always-on fallback (proven identical to
    the compiled path by `commands::version::tests::compiled_version_line_matches_dart_cli_core_format`).
  - **`--features cli_core`** (after the two regen commands above): all four verbs produce
    output byte-identical to the Dart CLI — proven by the golden-fixture parity gate below.
- **`auditReport` is intentionally excluded** from `compiled_cli.rs` (issue #365, `#362`
  residual): it calls `capability_analyzer`/`termination_analyzer`, separate Dart files pulled in
  via `import` (not `part`), which `gen_cli_json.dart`'s `resolveDartLibrary` does not merge —
  the Dart encoder leaves them as **empty import-stub modules** in `cli.ball.json`. The Dart
  parity test (`dart/cli/test/cli_core_parity_test.dart`) tolerates this by simply never calling
  `auditReport`; Rust cannot — an unresolved `analyzeCapabilities`/`writeln`/… call is a hard
  `rustc` error under whole-file AOT compilation, not a latent runtime gap. `rust/cli/tool/src/main.rs`'s
  `SKIPPED_FUNCTIONS` filter drops `auditReport` from the loaded `Program` before compiling — a
  Rust-target-only, well-documented workaround that touches neither `cli_core.dart` (shared by
  every language) nor `ball-lang-compiler` (general-purpose). No `ball audit` subcommand exists in
  `ball-lang-cli`.

### Golden-fixture parity gate

`tests/cli_core_parity.rs` compares the **built `ball` binary's** stdout for `info`/`validate`/
`tree` against golden `.txt` files checked into `tests/golden/cli_core/`, generated once from the
real Dart CLI (`dart run dart/cli/bin/ball.dart <verb> <fixture>`) — the exact regen command is
documented in that test file's module doc comment. This avoids depending on a `dart` toolchain at
`cargo test` time (unlike the Dart-native `cli_core_parity_test.dart`, which compares
in-process against the Ball-engine-run `cli.ball.json`). `version` has no golden file — its
compiled-vs-fallback identity is checked directly (see above).

## Testing

```bash
cargo build -p ball-lang-cli
cargo build -p ball-lang-cli --features cli_core     # after the two regen commands above
cargo test -p ball-lang-cli                          # unit tests + tests/*.rs integration tests
cargo test -p ball-lang-cli --features cli_core      # additionally exercises the golden parity gate
cargo fmt -p ball-lang-cli --check
cargo clippy -p ball-lang-cli --all-targets -- -D warnings
cargo clippy -p ball-lang-cli --all-targets --features cli_core -- -D warnings
```

`tests/cli_{run,compile,encode,check,general,core_parity}.rs` spawn the real built binary
(`Command::new(env!("CARGO_BIN_EXE_ball"))`, no `assert_cmd` dependency) and assert on
stdout/stderr/exit code for both the happy path and every exit-code bucket (missing file,
malformed input, a structurally-valid-but-uncompilable program). `tests/cli_compile.rs`
additionally proves `ball compile`'s Rust output for `hello_world`/`fibonacci` actually
compiles and runs with the real toolchain (`cargo run` against a throwaway package depending
on `ball-lang-shared`, reusing the workspace `target/` dir — the same harness
`rust/compiler/tests/end_to_end.rs`/`rust/encoder/tests/end_to_end.rs` use).

## Known gaps

- No package-registry commands (`dart/cli`'s `init`/`add`/`resolve`/`publish`/`build`) — out of
  scope for issue #41.
- No `ball audit` — see "`auditReport` is intentionally excluded" above (issue #362 residual).
- `check` does not attempt to run the program — only `ball-lang-compiler`-shaped structural
  validation, plus an opt-in `--compile` dry-run. It never drives `ball-lang-engine`. (It predates
  `cli_core` adoption and is deliberately kept as the Rust-target-specific stronger check;
  `validate` is the cli-core-parity verb.)
- The `rust` job in `.github/workflows/ci.yml` builds/tests this crate as part of the workspace
  `cargo build --workspace`/`cargo test --workspace` steps (#44 closed) plus dedicated
  `cli_core`-feature regen/build/test steps (#365) alongside the existing `self_host` ones.
