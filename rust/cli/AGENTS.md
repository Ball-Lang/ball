<!-- Parent: ../AGENTS.md -->

# `ball-cli` — Rust Ball CLI

The binary `ball` (crate `ball-cli`): `run`/`compile`/`encode`/`check` subcommands over
`ball-engine`/`ball-compiler`/`ball-encoder` (issue #41). Mirrors `dart/cli/` and `ts/cli/`
where their subcommand shapes overlap; narrower than `dart/cli` (no package-registry
commands — `init`/`add`/`resolve`/`publish` — yet).

## Layout

- `src/main.rs` — `clap` (derive) CLI definition + subcommand dispatch + exit-code handling.
- `src/error.rs` — `CliError` (`Io`/`Parse`/`Runtime`) and the exit-code contract (see below).
  `From<ball_engine::EngineError>` maps the engine's own error variants onto it.
- `src/loader.rs` — `load_engine(path)`: format-sniffs `.bin` (binary protobuf) vs. anything
  else (proto3 JSON) and loads via `ball_engine::BallEngine::from_binary`/`from_json` — reused
  by every subcommand, per the issue's "the loader in ball-engine handles both" note.
- `src/serialize.rs` — `program_to_json`/`program_to_binary`: the reverse direction of
  `rust/engine/src/loader.rs`, for `ball encode`'s output.
- `src/panic_guard.rs` — `catch_panic_message`: converts a `ball-compiler`/`ball-encoder`
  `panic!` (their documented "fail loud on an unsupported shape" behavior — see each crate's
  own module doc comment) into a `CliError::Parse` instead of aborting the process with Rust's
  own exit code `101`.
- `src/output.rs` — `write_text`/`write_bytes`: `--output <file>` vs. stdout, shared by
  `compile` and `encode`.
- `src/commands/{run,compile,encode,check}.rs` — one module per subcommand.

## Exit-code contract (issue #41)

| Code | Meaning |
|------|---------|
| `0`  | success |
| `1`  | runtime error — a Ball program ran but failed (a `throw` that escaped `main`, or the engine reporting an error) |
| `2`  | invalid/unparseable program — bad `.ball.json`/`.ball.bin` shape, Rust source `encode` couldn't turn into a program, or a loaded program was too malformed to compile |
| `3`  | file-not-found / other I/O error reading input or writing `--output` |

Every subcommand returns `Result<(), CliError>`; `main` prints `ball: <message>` to stderr and
exits with `CliError::exit_code()` on `Err`. `0` is simply the absence of an `Err` — never an
explicit branch, so a subcommand can't accidentally "succeed" without actually completing its
work.

## `run` and the `self_host` Cargo feature

`ball-cli` has its own `self_host` feature (`Cargo.toml`), off by default, forwarding to
`ball-engine/self_host`. This mirrors `ball-engine`'s own default-off design (see
`rust/engine/AGENTS.md`): `rust/engine/src/compiled_engine.rs` is a **generated, gitignored**
file (`cargo run -p ball-engine-regen`, which itself needs `dart/self_host/engine.ball.json` —
also generated, also gitignored) that is not present in a fresh checkout. Keeping `self_host`
off by default means `cargo build -p ball-cli` / `cargo test -p ball-cli` stay green without
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

## Testing

```bash
cargo build -p ball-cli
cargo test -p ball-cli            # unit tests (error/panic_guard/check validator) + tests/*.rs
                                   # integration tests (spawn the built `ball` binary)
cargo fmt -p ball-cli --check
cargo clippy -p ball-cli --all-targets -- -D warnings
```

`tests/cli_{run,compile,encode,check,general}.rs` spawn the real built binary
(`Command::new(env!("CARGO_BIN_EXE_ball"))`, no `assert_cmd` dependency) and assert on
stdout/stderr/exit code for both the happy path and every exit-code bucket (missing file,
malformed input, a structurally-valid-but-uncompilable program). `tests/cli_compile.rs`
additionally proves `ball compile`'s Rust output for `hello_world`/`fibonacci` actually
compiles and runs with the real toolchain (`cargo run` against a throwaway package depending
on `ball-shared`, reusing the workspace `target/` dir — the same harness
`rust/compiler/tests/end_to_end.rs`/`rust/encoder/tests/end_to_end.rs` use).

## Known gaps

- No package-registry commands (`dart/cli`'s `init`/`add`/`resolve`/`publish`/`build`/`tree`) —
  out of scope for issue #41.
- `check` does not attempt to run the program — only `ball-compiler`-shaped structural
  validation, plus an opt-in `--compile` dry-run. It never drives `ball-engine`.
- No CI job wires this crate up yet (`.github/workflows/ci.yml` — tracked by #44, a separate
  issue).
