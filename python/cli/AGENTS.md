<!-- Parent: ../AGENTS.md -->

# `python/cli` — the `ball` CLI (Python toolchain)

The `ball` console script (package `ball_cli`, entry point `ball_cli.__main__:main`):
the four core verbs `run` / `compile` / `encode` / `check` over `python/engine`,
`python/compiler`, and `python/encoder` (epic #445 Phase 5), plus the four
self-hosted cli-core verbs `info` / `validate` / `tree` / `version` (issue #570).
The Python sibling of `go/cli` / `rust/cli` / `csharp/cli`; narrower than
`dart/cli` (no package-registry commands, no `audit`).

The cli-core verbs do **not** compute their own report text: it comes from
`dart/shared/lib/cli_core.dart` compiled through `python/compiler`, so every
`ball` on every registry prints byte-identical reports.
`tests/cli_core_goldens/` (the canonical golden set, shared with the Go gate) is
the proof.

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
- `commands/{run,compile,encode,check,info,validate,tree,version}.py` — one
  module per verb, each a `command(args, stdout, stderr) -> int`.
- `cli_core.py` — the single place that decides WHERE the compiled cli-core comes
  from (`reports()`) and builds the program view the reports consume
  (`program_view`, reusing the engine's own `load_view_from_json` — there is no
  second loader).
- `bootstrap_clicore.py` — compile-on-first-use + per-user cache for the CLI
  core, the exact mechanism `ball_engine.bootstrap` uses for the engine.
- `regen.py` (`python -m ball_cli.regen`) — writes the generated, gitignored
  `compiled_cli.py`; the sibling of `ball_engine.regen`.
- `tool/bundle_cli_core.py` — gzips `dart/self_host/cli.ball.json` into
  `ball_cli/_clicore/cli_core.ball.json.gz` for the wheel; the sibling of
  `python/engine/tool/bundle_selfhost.py`.

## Exit-code contract

Mirrors the Rust/Go CLIs so the four Python verbs behave identically:

| Code | Meaning |
|------|---------|
| `0` | success |
| `1` | runtime error — a program ran but failed, or `run` when the self-hosted engine is not built (`compiled_engine.py` absent) |
| `2` | invalid/unparseable program — a bad `.ball.json` shape, Python source `encode` couldn't turn into a program, a program too malformed to compile, `check` found it invalid; also usage errors (unknown command/flag, wrong arg count) |
| `3` | file-not-found / other I/O error reading input or writing `-o`/`--output` |

## `run` and the self-hosted engine

`run` executes via the self-hosted `python/engine`, which resolves its compiled
engine from one of two places (`ball_engine.driver.compiled_engine`):

1. the generated `ball_engine/compiled_engine.py` (~690 KB, compiled from
   `dart/self_host/engine.ball.json`; gitignored, absent from a fresh checkout)
   — the checkout path every CI leg exercises;
2. otherwise `ball_engine.bootstrap`, which compiles the bundled Ball engine
   source into a per-user cache dir on first use (~0.25 s) — the only path a
   `pip install ball-lang` wheel has, since generated code is never shipped
   (issue #496).

When neither is available — a fresh checkout with no
`dart/self_host/engine.ball.json` and no bundled source — the failure is honest:
**exit 1** carrying the "regenerate with `python -m ball_engine.regen`" message,
never a silent success, never a raw traceback. The same holds for an unwritable
cache dir or a compile failure, each with its own actionable message
(`BootstrapError`). This is the Python analog of the Go CLI's `selfhost` build
tag, the Rust CLI's `self_host` Cargo feature, and C#'s `-p:SelfHost=true`.

`run` splits read → load-view → execute so each maps to the right exit code (I/O
3 / invalid 2 / runtime 1). `compile`/`encode`/`check` do not need the engine.

## The cli-core verbs and their availability gate (issue #570)

`info`/`validate`/`tree`/`version` delegate to the compiled CLI core. Python has
no compile-time feature flag, so **availability is the gate** — the analog of
Go's `clicore` build tag, Rust's `cli_core` Cargo feature and C#'s
`-p:CliCore=true`. `ball_cli.cli_core.reports()` resolves, in order:

1. the generated `ball_cli/compiled_cli.py` (`python -m ball_cli.regen`;
   gitignored, absent from a fresh checkout, never shipped);
2. otherwise `ball_cli.bootstrap_clicore.load_cli_core()`, which compiles the
   bundled (`ball_cli/_clicore/cli_core.ball.json.gz`) or checkout
   (`dart/self_host/cli.ball.json`) Ball source into a per-user cache dir on
   first use — the only path a `pip install ball-lang` wheel has;
3. otherwise an honest **exit 1** naming the two commands that fix it — never a
   silent success, never a raw traceback.

The cache lives under the `clicore` subdirectory of the shared `ball-lang` cache
root (`BALL_CACHE_DIR` overrides it), so the engine's and the CLI core's compiled
modules can never be confused for one another.

The program is LOADED before the CLI core is resolved, so a missing file (exit 3)
or a malformed program (exit 2) reports its own, more specific failure.

`validate` is the PORTABLE report every cli-core `ball` shares; `check` remains
this CLI's own Python-target battery (with the opt-in `--compile` dry run). They
overlap but are not the same verb.

### Regenerating `compiled_cli.py`

```bash
cd dart && dart run compiler/tool/gen_cli_json.dart   # -> cli.ball.json (gitignored)
cd ../python/cli && python -m ball_cli.regen          # -> ball_cli/compiled_cli.py (gitignored)
BALL_REQUIRE_CLI_CORE=1 python -m pytest -q tests/test_cli_core_parity.py
```

`compiled_cli.py` is a GENERATED, NEVER-edit file: fix
`dart/shared/lib/cli_core.dart` (then rerun `gen_cli_json.dart`) or
`python/compiler`, and rerun the regenerator.

## `--version` is a flag AND `version` is a verb

`ball --version` (also `-V`) prints the installed toolchain version, read from
the installed `ball-lang` distribution metadata (`importlib.metadata`), or an
explicit `0.0.0+source (… running from a source checkout)` line when running
from the repo.

`ball version` is a different thing and both exist on purpose — exactly as they
do for Rust (clap's built-in `--version` alongside a `version` subcommand): the
verb prints the PORTABLE one-line `ball <version>` form
(`dart/shared/lib/cli_core.dart`'s `versionLine`) that every `ball` shares. The
flag is matched in `cli.py`'s dispatch before the subcommand table, so the two
never collide.

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

# The cli-core verbs (they also work straight from the checkout source, compiled
# on first use — the regen just skips that per-process compile):
cd ../../dart && dart run compiler/tool/gen_cli_json.dart      # -> cli.ball.json (gitignored)
cd ../python/cli && python -m ball_cli.regen                   # -> compiled_cli.py (gitignored)
python -m ball_cli info ../../tests/conformance/101_simple_class.ball.json
```

Tests drive each verb in-process through `ball_cli.run` (helpers in
`tests/conftest.py`). `test_compile`/`test_encode` additionally **run the emitted
Python** (`run_python_source`, executing `ballrt.run_entry`) and assert stdout,
proving `compile` and `encode`→`compile` produce runnable code. `test_run` covers
both self-host paths: the honest exit-1 failure without the artifact (and the
natural fresh-checkout state) plus real execution when it is present (that case is
`skipif`'d when the gitignored artifact is absent, so plain pytest stays green on a
fresh checkout).

`test_cli_core_parity.py` is the cli-core golden gate: in-process `info` /
`validate` / `tree` over the five-fixture set in `tests/cli_core_goldens/`,
byte-compared to the Dart CLI's own output. It skips itself when no CLI core is
reachable (the fresh-checkout state ci.yml's pre-regen `CLI tests` step is in) and
**`BALL_REQUIRE_CLI_CORE=1` turns that skip into a failure**, so the post-regen
gate cannot silently become a no-op — the same mechanism
`BALL_REQUIRE_SELFHOST_SOURCE` provides for the engine.
`test_cli_core_bootstrap.py` covers the resolution order itself: the
compile-on-first-use path, the honest exit-1 when nothing is available, and the
cache-key/cache-root invariants.

Cross-CLI, `tools/check_cli_verb_parity.py` (the always-on `CLI Verb Parity` CI
job) asserts this CLI's `--help` verb set against `tools/cli_verbs.json`, so a
verb silently disappearing here fails even though every pytest case would pass.

## Known gaps / follow-ups

- No package-registry commands and no `ball audit` — same scope boundary as
  `rust/cli`/`go/cli`. (`cli_core.auditReport` itself compiles fine into
  `compiled_cli.py`; the verb, its options and its goldens are a separate slice,
  declared in `tools/cli_verbs.json`.)
- No binary program format (see "Format scope" above).
