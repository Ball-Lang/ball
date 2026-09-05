---
paths:
  - "python/**"
---

# Python-Specific Instructions

Python (epic #445) is a **complete pipeline** — compiler, encoder, self-hosted engine, and the
`ball` CLI (`run`/`compile`/`encode`/`check`) are all in place and tested (the self-hosted cli-core
verbs `info`/`validate`/`tree`/`version` are a deliberate follow-up, not yet ported — like Go). The
self-hosted engine runs the whole conformance corpus at **Dart parity** (`Results: 339 passed,
0 failed, 339 total (4 skipped carve-outs)`; the 4 golden-less resource-limit/sandbox fixtures are
documented carve-outs). Always verify maturity against CI (`.github/workflows/ci.yml`'s `python`
job — compiler/encoder/CLI pytest + `compileall` plus the regenerate-then-run self-hosted engine
conformance sweep — and the `python-engine` row in `conformance-matrix.yml`) and `python/AGENTS.md`,
not stale prose.

## Build System

- Native `python` works **on Windows** in this dev environment — no WSL needed (like Go, unlike
  Rust/C++). CI pins `python-version: "3.13"` via `actions/setup-python`; every
  `python/*/pyproject.toml` declares `requires-python = ">=3.11"` (the floor). This is the same
  "manifest declares the floor, CI runs the latest line" split the go job uses.
- **Five isolated packages, no workspace manager** — `runtime`, `shared`, `compiler`, `encoder`,
  `engine`, `cli` each have their own `pyproject.toml` and no shared virtualenv. Each test suite's
  `tests/conftest.py` bootstraps its sibling sources onto `sys.path` (the repo's
  isolated-package convention), so run `pytest` **from each package's own dir**:

```bash
cd python/compiler && python -m pytest -q     # 52 tests
cd python/encoder  && python -m pytest -q     # 42 tests
cd python/cli      && python -m pytest -q     # all four verbs, in-process
# Syntax gate (the Python analog of `go build`/`go vet`):
python -m compileall python/runtime/ballrt python/compiler/ball_compiler \
  python/encoder/ball_encoder python/engine/ball_engine python/cli/ball_cli python/shared/gen
```

- **The engine loader needs the `protobuf` runtime (>= 5.29).** The compiler and encoder walk the
  raw proto3-JSON dict view and have **zero** third-party deps, but `python/engine`'s loader
  (`ball_engine/loader.py`) materialises proto3 defaults through the generated binding
  (`python/shared/gen`, package `ball.v1`), which imports `google.protobuf`. `pip install
  "protobuf>=5.29"` before regenerating/running the engine or its conformance sweep. `ballrt` itself
  stays stdlib-only, so a *compiled program* still runs offline.

## Package Structure

- `python/runtime` (package `ballrt`) — the zero-dependency runtime value model (native
  `int`/`float`/`str`/`bool`/`list`/`dict`, insertion-ordered `BallSet`, `BallValue`/`BallMap` base
  classes the self-hosted engine's `BallObject` extends) + Dart-exact base ops (`ops.py`) +
  `break`/`continue`/`return`/`throw` flow-signal **exceptions** (`flow.py`) + `ball_proto` access
  patterns (`proto.py`), Dart-SDK method dispatch (`methods.py`, via `call_method`),
  `std_collections`/set (`collections.py`), `std_convert` (`convert.py`), the is/as class registry +
  builtin statics (`selfhost.py`), typed Dart exceptions (`dart_errors.py`), and console output +
  the entry-point driver (`io.py`). **Zero external dependencies** (Python stdlib only). See
  `runtime/AGENTS.md`.
- `python/shared` (package `ball.v1`, under `gen/`) — generated Python protobuf bindings
  (`buf generate`, plugin `buf.build/protocolbuffers/python`); requires `google.protobuf`. Never
  hand-edit.
- `python/compiler` — Ball → Python. Emits Python source as strings (like the C++/Rust/Go compilers,
  not Dart's `code_builder`). Two modes: `compile` (a runnable script whose `if __name__ ==
  "__main__"` block calls `ballrt.run_entry(entry)`) and `compile_library` (a flat library of
  classes/dispatchers/free-functions — no entry driver — for the self-hosted engine). Base-function
  dispatch is `base_call`; `typeDefs[]` emission is `type_emit`. `ballpyc` (`python -m
  ball_compiler`) is the front-end.
- `python/encoder` — Python → Ball via the stdlib `ast`. Routes every construct through universal
  `std`/`std_collections` — **no `python_std` base module**, ever (the Rust/Go encoders' "no
  <lang>_std" invariant). `ballpyenc` (`python -m ball_encoder`) is the front-end. Test-only reliance
  on the compiler for the round-trip proof.
- `python/engine` — self-hosted engine wrapper (`loader.py`/`driver.py` + `ball_engine/__main__.py`)
  driving the generated, gitignored `ball_engine/compiled_engine.py`. `ball_engine/regen.py`
  regenerates it; `conformance/runner.py` is the whole-corpus sweep. See `python/engine/AGENTS.md`.
- `python/cli` (package `ball_cli`, `python -m ball_cli` / `ball`) — the `ball` CLI:
  `run`/`compile`/`encode`/`check` over engine/compiler/encoder (the Python sibling of
  `rust/cli`/`csharp/cli`/`go/cli`; no package-registry commands, no `audit`). All logic is in
  `ball_cli.run` so tests exercise every verb in-process. `run` needs the gitignored
  `compiled_engine.py` — an honest exit-1 + regenerate hint when absent, never a silent success.
  `ball_cli/__main__.py` forces UTF-8 stdout/stderr so a cp1252 Windows console does not raise
  `UnicodeEncodeError` on non-ASCII `run` output. See `python/cli/AGENTS.md`.

## Key Patterns

### Compiler

- Every Ball expression compiles to a Python expression evaluating to a `ballrt` value (uniform).
  Python has no block/if/loop **expressions**, so statement-bearing constructs are wrapped as the
  compiler needs (native `if`/`for`/`while` control flow evaluated **lazily**, invariant #4).
- All 7 expression node types are handled; the reference name `"input"` is the function parameter
  (invariant #1). `return`/`break`/`continue`/`throw` are `ballrt` flow-signal **exceptions** (Python
  has no goto), caught by the emitted loop/function scaffolding.
- **Fail-loud (issue #55):** an unsupported base function / expression shape is a `CompileError`,
  never silent bad code.
- **`run_switch`'s empty-body/fall-through test is statement mode only.** Ball encodes `null` as a
  value-less `Literal` (`{"literal": {}}`) — exactly the shape `is_empty_switch_body` reads as
  "empty" — so applying it to a `switch_expr` (where nothing falls through and every arm carries a
  value) deletes every `=> null` arm and leaks its condition into the next one: compiles, exits 0,
  wrong answer. Gate it on the already-computed `expr_mode` (issue #470; same defect family as
  `rust/compiler`, same gate as `go/compiler/base_call.go:514-522`).

### Encoder

- `encode(source)` parses Python with the stdlib `ast` and walks declarations → statements →
  expressions. **One input, one output** (invariant #1): a 0-param func takes no input; a 1-param
  func keeps its parameter name; a 2+-param call packs args into one anonymous message keyed by the
  callee's parameter names (read back by the compiler).
- **Fail-loud:** an unsupported construct raises `EncodeError`, never a placeholder. The round-trip
  test is the proof: Python → Ball → (compile with `python/compiler` + run) ≡ running the original
  Python natively.

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++/Rust/C#/Go: compile
  `dart/self_host/engine.ball.json` through `python/compiler` (**library mode**) into
  `ball_engine/compiled_engine.py`.
- **Status: complete, runs at Dart parity** — `Results: 339 passed, 0 failed, 339 total (4 skipped
  carve-outs)`, matching Dart byte-for-byte.
- **Fix compiled-engine behavior in `python/compiler` (a fix + regen) or `python/runtime` (no
  regen) — NEVER hand-edit `compiled_engine.py`.** Common `python/runtime` families: `ball_proto`
  access patterns (`proto.py`), the Dart-SDK method surface (`methods.py`, via `call_method`),
  `std_collections`/set (`collections.py`), `std_convert` (`convert.py`), the is/as class registry
  (`selfhost.py`). The parity grind's root-cause clusters are catalogued in
  `python/engine/AGENTS.md`.
- **`call_method` dispatches a receiver's OWN method before the `has<Field>` presence heuristic.**
  The heuristic (`name` starts with `has` + a capital ⇒ a protobuf presence probe) used to run
  first, so Dart's real `RegExp.hasMatch(s)` became a presence probe for a field named `match` and
  silently answered `False` — every regex path in the compiled engine (`std.string_matches`, the
  engine's own `^arg\d+$` constructor-argument test) was dead in Python while every other target
  ran it. Pinned by `python/compiler/tests/test_runtime.py`.
- **Per-fixture timeout is a subprocess kill, not cooperative** (contrast Go): each fixture runs as
  its own killable `python -m ball_engine` subprocess with `subprocess.run(timeout=…)`, so a runaway
  is simply killed — a Python process is trivially killable, sidestepping the goroutine-leak problem
  the Go runner works around cooperatively.

## The bytes-not-text golden-harness rule

Conformance goldens (`tests/conformance/*.expected_output.txt`) must be read as **bytes**, then
decoded and normalised **only** for `\r\n` → `\n` — never through Python's text-mode universal
newlines. `Path.read_text()` (universal newlines) collapses *every* newline flavour, including a
semantic lone `\r` a fixture legitimately prints (Dart `'\r'`), to `\n`, which silently masks a real
divergence. The harness helper is therefore:

```python
def read_golden(path: Path) -> str:
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")
```

(see `python/compiler/tests/conftest.py`). The conformance runner
(`python/engine/conformance/runner.py`) applies the same `.replace("\r\n", "\n").rstrip("\n")`
normalisation to both actual stdout and the golden. This is the Python analog of Go's "gofmt CRLF
gotcha" rule — a Windows checkout stores goldens CRLF, but the semantics live in the LF-normalised
bytes, not in text-mode line mapping.

## Regenerate the Self-Hosted Engine

```bash
cd dart && dart run compiler/tool/gen_engine_json.dart   # writes dart/self_host/engine.ball.json
cd ../python/engine && python -m ball_engine.regen       # -> ball_engine/compiled_engine.py
python -m conformance.runner                             # prints the CI-parseable `Results:` line
```

`regen.py` reads `dart/self_host/engine.ball.json` (gitignored) and compiles it through
`ball_compiler.compile_library`. `BALL_FIXTURE=<name>` runs one fixture with a full diff;
`BALL_TIMEOUT_S=<s>` sets the per-fixture kill budget; `BALL_WORKERS=<n>` sets parallelism.

## Packaging: one `ball-lang` wheel (issue #496)

- The five isolated packages are the DEVELOPMENT shape; the REDISTRIBUTABLE shape is a single
  combining distribution, `python/pyproject.toml` (`name = "ball-lang"`), bundling
  `python/{runtime,compiler,encoder,engine,cli}` plus the generated `ball.v1` binding into one wheel
  with a `ball` console script. Never add per-package publishing — one wheel is the owner's decision.
- **Nothing generated ships**, enforced by `python/setup.py`'s `build_py` filter (setuptools has no
  declarative per-module exclusion, and `packages = ["ball_engine", …]` otherwise sweeps in the
  gitignored `compiled_engine.py` whenever the tree has been regenerated). Never delete that hook;
  `wheel_smoke.py` asserts the wheel carries the bundled `.gz` and not the generated module, and
  wipes `python/build/` first so a stale build tree cannot leak it. The wheel carries the engine's
  Ball SOURCE
  (`ball_engine/_selfhost/engine.ball.json.gz`, a gitignored build artifact of
  `python/engine/tool/bundle_selfhost.py`), and `ball_engine/bootstrap.py` compiles it into a
  per-user cache dir on the first `ball run` (~0.25 s; `BALL_CACHE_DIR` overrides the location).
  `driver.compiled_engine()` still prefers a regenerated `compiled_engine.py`, so the checkout and
  CI paths are unchanged.
- **`ball.v1` must survive `buf generate proto`.** It is a PEP 420 implicit-namespace directory with
  no `__init__.py`; the combining pyproject lists `ball` / `ball.v1` explicitly with a `package-dir`
  mapping. **Never add an `__init__.py` under `python/shared/gen/`** — the next regen deletes it.
- The gate is `python python/tool/wheel_smoke.py` (PR-gated in ci.yml's `python` job): build the
  wheel, install it into a venv OUTSIDE the repo with no `PYTHONPATH`, and run `--version` / `check`
  / `compile` / `encode` / `run`, comparing `run`'s stdout to a conformance golden as BYTES. An
  in-tree venv would let `ball_cli.paths` find the checkout and mask a packaging defect.
- `ball --version` is a FLAG, not a `version` verb: `ball version <program>` is the self-hosted
  cli-core report in the sibling CLIs, still an unported follow-up here.
- Release: `.github/workflows/publish-pypi.yml`, tag-gated on `python-pypi/vX.Y.Z`, PyPI Trusted
  Publishing (OIDC, no token fallback). See `docs/RELEASE.md` and `python/AGENTS.md § Publishing`.

## Generated Files — NEVER Edit

- `python/shared/gen/**` — protobuf bindings (`buf generate proto`, plugin
  `buf.build/protocolbuffers/python`, root `buf.gen.yaml`).
- `python/engine/ball_engine/compiled_engine.py` — gitignored (~690 KB), regenerated via `python -m
  ball_engine.regen`. Absent from a fresh checkout; the pytest/compileall gates never need it (only
  the conformance runner, which regenerates it first, does).
- `python/engine/ball_engine/_selfhost/engine.ball.json.gz` — gitignored, written by
  `python/engine/tool/bundle_selfhost.py` from the (also gitignored)
  `dart/self_host/engine.ball.json`. Only the wheel build needs it.

## Testing

- **Third-party coverage study, Tier A (#493).** `tools/coverage-study/rq1_study_py.py`
  runs real pinned packages through `ball_encoder.encode` ->
  `ball_compiler.compile_library` -> `ball_encoder.encode`, diffs the declaration
  inventory with the **stdlib `ast` directly** (never `ball_encoder`'s own walk) and
  checks a second-generation fixpoint. Honest first baseline **0/73 clean**; 5 files
  encode and compile back, and the wall is stage 3 — the compiler's `try/except` +
  `ballrt.*` output is outside the encoder's surface (the top-level-class gap keeps
  the other 68 from encoding at all). `python tools/coverage-study/test/
  rq1_study_py_self_test.py` (the harness's own self-test) IS gated on every PR in
  the `python` job, and both files are in the `compileall` syntax gate; the RUN is
  the report-only `python-tier-a` job in `coverage-study.yml`, which has **no
  `pull_request:` trigger**. Methodology: `tests/conformance/COVERAGE_STUDY.md`.

- `python -m pytest -q` from each of `python/compiler`, `python/encoder`, `python/cli` runs the
  compiler golden-exact conformance + runtime unit tests, the encoder structural + round-trip tests,
  and the CLI's in-process verb tests (including `run`'s honest-failure path when
  `compiled_engine.py` is absent — so run the CLI suite **before** regenerating the engine, as CI
  does, to actually exercise it).
- Prefer extending the compiler/encoder tests or `tests/conformance/*.ball.json` over Python-only
  unit tests, per the repo-wide "prefer conformance tests" rule.
- `python/engine/conformance/runner.py` is the committed `tests/conformance/*.ball.json` runner — the
  `python-engine` sweep is what CI gates on; quote its `Results:` line, not a hand-maintained count.
- `python/engine/conformance/roundtrip.py` (`python -m conformance.roundtrip`, or
  `python -m python.engine.conformance.roundtrip` from the repo root) is a **measurement-only**
  sweep (#452 item 3): Ball → Python → Ball → the **Dart** reference engine → golden diff. Needs
  `dart` on PATH (or `BALL_DART`), not the compiled engine. Honest baseline **0/321**, expected by
  construction and mirroring `csharp-roundtrip`; gated only on "the sweep ran something", never on
  the failure count. Its CI home is the `python-roundtrip` row in `conformance-matrix.yml`, which
  has **no `pull_request` trigger** — the row is absent, not green, on a PR; dispatch the workflow
  and read the run.
