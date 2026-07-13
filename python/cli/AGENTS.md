<!-- Parent: ../AGENTS.md -->

# `python/cli` — the `ball` CLI (Python toolchain)

The `ball` console script (package `ball_cli`, entry point `ball_cli.__main__:main`):
the four core verbs `run` / `compile` / `encode` / `check` over `python/engine`,
`python/compiler`, and `python/encoder` (epic #445 Phase 5). The Python sibling of
`go/cli` / `rust/cli` / `csharp/cli`; narrower than `dart/cli` (no
package-registry commands, no `audit`). The self-hosted cli-core verbs
(`info`/`validate`/`tree`/`version`, compiled from `dart/self_host/cli.ball.json` —
what the Rust/C# CLIs added later) are a deliberate follow-up, not part of Phase 5.

## Layout

All logic lives in package `ball_cli` so the whole CLI is exercisable in-process
by the tests (via `ball_cli.run`) without spawning a subprocess; `__main__.py` is
a thin `sys.exit(run(sys.argv[1:], sys.stdout, sys.stderr))` (plus a UTF-8
`reconfigure` for `run` output on a cp1252 Windows console).

- `cli.py` — `run(argv, stdout, stderr) -> int`: subcommand dispatch, usage, and
  the top-level `CliError` guard that turns every expected failure into a clean
  `ball: <message>` line + exit code (a genuine bug still propagates as a
  traceback — no error class is swallowed and re-emitted as noise).
- `errors.py` — `CliError` + the exit-code contract (below) and the
  `io_error`/`parse_error`/`usage_error`/`runtime_error` constructors.
- `argparse_util.py` — `StreamParser`: a stdlib `argparse.ArgumentParser` wired to
  the injected streams that raises `CliError`/`HelpRequested` instead of calling
  `sys.exit`, so per-verb flag parsing stays in-process.
- `paths.py` — `bootstrap_sys_path`: put the sibling packages (runtime, shared/gen,
  engine, compiler, encoder) on `sys.path` from the checkout (the repo's
  isolated-package convention — same bootstrap the engine's `__main__` and the
  compiler/encoder `conftest.py` do).
- `loader.py` — `load_program_dict` (for `compile`/`check`, via
  `ball_compiler.load_program` — the raw proto3-JSON dict view, no protobuf
  runtime); `run` uses the engine's own protobuf-backed `load_view_from_json`.
- `output.py` — `write_output` (`-o <file>` vs. stdout), shared by
  `compile`/`encode`.
- `commands/{run,compile,encode,check}.py` — one module per verb, each a
  `command(args, stdout, stderr) -> int`.

## Exit-code contract

Mirrors the Rust/Go CLIs so the four Python verbs behave identically:

| Code | Meaning |
|------|---------|
| `0` | success |
| `1` | runtime error — a program ran but failed, or `run` when the self-hosted engine is not built (`compiled_engine.py` absent) |
| `2` | invalid/unparseable program — a bad `.ball.json` shape, Python source `encode` couldn't turn into a program, a program too malformed to compile, `check` found it invalid; also usage errors (unknown command/flag, wrong arg count) |
| `3` | file-not-found / other I/O error reading input or writing `-o`/`--output` |

## `run` and the self-hosted engine

`run` executes via the self-hosted `python/engine`, whose compiled-engine driver
imports the generated `ball_engine/compiled_engine.py` (~690 KB, compiled from
`dart/self_host/engine.ball.json`; gitignored, absent from a fresh checkout).
Because the engine lazy-imports that artifact inside `run_program_view`, its
absence raises an `ImportError` (`cannot import name 'compiled_engine' …`) that
`run` surfaces as a **runtime error (exit 1)** carrying the "regenerate with
`python -m ball_engine.regen`" message — never a silent success, never a raw
traceback. This is the Python analog of the Go CLI's `selfhost` build tag, the
Rust CLI's `self_host` Cargo feature, and C#'s `-p:SelfHost=true`.

`run` splits read → load-view → execute so each maps to the right exit code (I/O
3 / invalid 2 / runtime 1). `compile`/`encode`/`check` do not need the engine.

## Format scope: JSON only

Programs are read as proto3 JSON (`.ball.json` / `.json`, optionally `@type`-Any
enveloped); `encode` emits `@type`-enveloped proto3 JSON. Unlike `go/cli`, there
is **no binary `.pb` sniffing or `-format binary`**: the Python compiler/engine
loaders are JSON-centric (no binary-protobuf program loader exists on the Python
side), so a binary path would be a half-feature our own `run`/`compile` could not
read back. Deliberate; revisit if a Python binary loader lands.

## `check` structural rules

Loads the raw proto3-JSON view and reports every problem at once (exit 2 on any):
entry_module/entry_function set and resolving to a real module+function; every
module name non-empty and unique; every **non-base** function carries a body **or**
metadata. Only base functions may omit both (CLAUDE.md invariant 3) — and
constructors, abstract methods, and getters/setters legitimately have no `body`
but a `metadata` bag (`kind: constructor`, `params`, …), so the rule is
body-or-metadata (matching `go/cli`), **not** body-only. Empirically this accepts
323/324 conformance fixtures; the lone rejection is `201_input_validation` (100
deliberately-unnamed modules — a golden-less resource-limit carve-out). `--compile`
adds an opt-in dry-run `python/compiler` compile (Python-target-specific; can
false-positive on a valid program that hits a documented compiler scope gap).

## Build & Test

```bash
cd python/cli
python -m pip install -r requirements-dev.txt   # pytest + protobuf
python -m pytest -q                              # in-process, drives every verb
python -m compileall ball_cli                    # syntax gate

python -m ball_cli check   <program.ball.json>   # or: ball check …
python -m ball_cli compile <program.ball.json> -o out.py
python -m ball_cli encode  <source.py> -o out.ball.json
python -m ball_cli run     <program.ball.json>   # needs the compiled engine:

# Regenerate the self-hosted engine first (else `run` exits 1 with the hint):
cd ../../dart && dart run compiler/tool/gen_engine_json.dart   # -> engine.ball.json (gitignored)
cd ../python/engine && python -m ball_engine.regen             # -> compiled_engine.py (gitignored)
```

Tests drive each verb in-process through `ball_cli.run` (helpers in
`tests/conftest.py`). `test_compile`/`test_encode` additionally **run the emitted
Python** (`run_python_source`, executing `ballrt.run_entry`) and assert stdout,
proving `compile` and `encode`→`compile` produce runnable code. `test_run` covers
both self-host paths: the honest exit-1 failure without the artifact (and the
natural fresh-checkout state) plus real execution when it is present (that case is
`skipif`'d when the gitignored artifact is absent, so plain pytest stays green on a
fresh checkout).

## Known gaps / follow-ups

- No cli-core verbs (`info`/`validate`/`tree`/`version`) yet — the pattern ports
  from `rust/cli`/`csharp/cli` (compile `dart/self_host/cli.ball.json` through
  `python/compiler` in library mode into a gitignored `compiled_cli.py`, gated
  like the engine). A follow-up, out of Phase 5 scope (same boundary as `go/cli`).
- No package-registry commands and no `ball audit` — same scope boundary as
  `rust/cli`/`go/cli`.
- No binary program format (see "Format scope" above).
- CI wiring is Phase 7 — not added here.
