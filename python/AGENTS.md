<!-- Parent: ../AGENTS.md -->

# Python (runtime + compiler + encoder + engine + cli)

## Purpose
The Python Ball target. A **compiler + runtime + encoder + self-hosted engine +
CLI** (Ball epic #445 Phases 2-5), **CI-gated** (Phase 7): the `python` job in
`.github/workflows/ci.yml` (compiler/encoder/CLI pytest + `compileall` + the
regenerate-and-run self-hosted engine conformance sweep) plus a `python-engine`
row in `conformance-matrix.yml`, both gating on full Dart parity.

## Key Files / Contents
| Dir | Description |
|-----|-------------|
| `shared/` | Generated Python protobuf bindings (`buf.gen.yaml`) — NEVER edit by hand. The compiler and encoder walk the raw proto3-JSON dict view and do not use them; the **engine loader** does, to materialise proto3 defaults in the target-program view. |
| `runtime/` | `ballrt` — the zero-dependency runtime (value model, Dart-exact ops, flow-signal exceptions, stdout, ball_proto access patterns, Dart-SDK method dispatch, ball_value base classes). See `runtime/AGENTS.md`. |
| `compiler/` | `ball_compiler` — the Ball -> Python compiler (`compile` script mode + `compile_library` for the engine) + the `ballpyc` CLI. See `compiler/AGENTS.md`. |
| `encoder/` | `ball_encoder` — the Python -> Ball encoder (stdlib `ast`) + the `ballpyenc` CLI. Proven by round-trips through the compiler. See `encoder/AGENTS.md`. |
| `engine/` | `ball_engine` — the self-hosted engine: compiles `dart/self_host/engine.ball.json` through `compile_library` into the gitignored `compiled_engine.py`, driven by a native loader/driver; a subprocess-per-fixture conformance runner. See `engine/AGENTS.md`. |
| `cli/` | `ball_cli` — the `ball` CLI: the four core verbs `run`/`compile`/`encode`/`check` over engine/compiler/encoder, all in-process via `ball_cli.run`. `run` needs the gitignored `compiled_engine.py` (honest exit-1 + regenerate hint when absent). See `cli/AGENTS.md`. |

## Build & Test
```bash
cd python/compiler && python -m pip install -r requirements-dev.txt   # once (pytest)
python -m pytest -q                                                   # unit + golden-exact conformance
python -m compileall ../runtime/ballrt ball_compiler                  # syntax gate
python -m ball_compiler <program.ball.json> -o out.py                 # compile
PYTHONPATH=../runtime python out.py                                   # run

cd python/encoder && python -m pytest -q                              # structural + round-trip
python -m ball_encoder <src.py> -o out.ball.json                      # encode Python -> Ball

# Engine (self-hosted): regenerate the compiled engine, then sweep the corpus.
cd dart && dart run compiler/tool/gen_engine_json.dart                # self-host source
cd ../python/engine && python -m ball_engine.regen                   # -> compiled_engine.py (gitignored)
python -m conformance.runner                                          # prints the Results: line

# Round-trip leg (measurement only, #452 item 3): Ball -> Python -> Ball -> the
# DART reference engine -> golden diff. Needs `dart` on PATH (or BALL_DART), NOT
# the compiled engine. Runs from the repo root too, as CI invokes it.
cd python/engine && python -m conformance.roundtrip                   # prints the Results: line
python -m python.engine.conformance.roundtrip                         # ...from the repo root

cd python/cli && python -m pytest -q                                  # CLI, in-process (every verb)
python -m ball_cli check   <program.ball.json>                        # or compile / encode / run
```

## Status
Compiler + runtime + encoder + self-hosted engine + CLI, Python >= 3.11. The
**compiler** passes **52 tests**, the **encoder 42**, and the **CLI** drives all
four verbs in-process (`run`/`compile`/`encode`/`check`). The **self-hosted
engine** runs the whole conformance corpus at **Dart parity**:
`Results: 334 passed, 0 failed, 334 total (4 skipped carve-outs)` — Dart-identical
output (the 4 skipped are the golden-less resource-limit/sandbox carve-outs the
Rust/C#/Go runners also skip). Every non-passing input fails loud
(`CompileError`/`EncodeError` or a runtime raise) — no silent-wrong output. Verify
maturity against CI (the `python`/`python-engine` jobs, Phase 7), not prose. Full
design lives in `compiler/AGENTS.md`, `runtime/AGENTS.md`, `encoder/AGENTS.md`, and
`engine/AGENTS.md`.

### Round-trip leg (`python/engine/conformance/roundtrip.py`, #452 item 3)
A third, **measurement-only** sweep beside the engine and compiler legs: can the
encoder read back what the compiler emits? Per fixture it compiles Ball → Python,
re-encodes that source back to Ball, runs the **RE-ENCODED** program on the **Dart
reference engine** (ground truth — Python's own engine would only prove the
pipeline agrees with itself), and byte-diffs the golden.

Honest baseline **`Results: 0 passed, 321 failed, 321 total`** (55 compile-error,
266 encode-error; measured 2026-09-02). That zero is expected BY CONSTRUCTION and
is the product: the compiler emits a flat module dispatching through `ballrt.*`
helpers, a shape the syntactic `ast` encoder was never built to re-parse. It
mirrors `csharp/engine/conformance/RoundTripLeg.cs`. **Do not make it green by
weakening either side.** Gated only on harness health (a sweep that ran zero
fixtures raises), never on the failure count. Reads goldens and subprocess stdout
as **bytes**, normalising only CRLF.

CI home: the `python-roundtrip` row in `.github/workflows/conformance-matrix.yml`.
**That workflow has no `pull_request:` trigger**, so the row is ABSENT (not green)
on a PR — `gh workflow run conformance-matrix.yml --ref <branch>` and read the run
before merging a change to this leg.

## Publishing (PyPI)

The whole Python toolchain ships as **one** distribution, `ball-lang` (issue
#496): `python/pyproject.toml` bundles `python/{runtime,compiler,encoder,engine,
cli}` plus the generated `ball.v1` binding into a single wheel with a `ball`
console script. The five per-package `pyproject.toml`s are untouched — ci.yml
still runs each suite from its own directory.

```bash
python python/engine/tool/bundle_selfhost.py   # gzip the self-host Ball source
python -m build python/                        # sdist + wheel -> python/dist/
python python/tool/wheel_smoke.py              # build + clean-venv install + all 5 verbs
```

- **No generated code ships — structurally.** `python/setup.py` is a 15-line
  build hook whose `build_py` drops `ball_engine/compiled_engine.py` from both
  the wheel and the sdist. Without it, a wheel built in any tree that has run
  `python -m ball_engine.regen` (every CI job with a conformance sweep) silently
  ships that ~690 KB generated module — setuptools' declarative config has no
  per-module exclusion. `wheel_smoke.py` asserts the built wheel contains the
  bundled `.gz` and NOT the generated module, and clears `python/build/` first
  (build_py only copies newer files, so a stale build tree would leak it).
  The wheel carries the engine's Ball SOURCE as package data
  (`ball_engine/_selfhost/engine.ball.json.gz`, gitignored build output of
  `bundle_selfhost.py`), and `ball_engine/bootstrap.py` compiles it into a
  per-user cache dir on the first `ball run` (~0.25 s; `BALL_CACHE_DIR`
  overrides the location, cache key = distribution version + Python minor +
  source digest).
- **`ball.v1` packaging survives `buf generate proto`.** It is a PEP 420
  implicit-namespace directory with no `__init__.py` anywhere; the combining
  pyproject lists `ball` / `ball.v1` explicitly with a `package-dir` mapping, so
  nothing is added inside `python/shared/gen/` for a regen to delete.
- **Release:** `.github/workflows/publish-pypi.yml`, tag-gated on
  `python-pypi/vX.Y.Z`, PyPI Trusted Publishing (OIDC, no token fallback),
  version derived from the tag, self-host conformance sweep as the publish bar,
  a pre-publish wheel smoke, and a post-publish `pip install ball-lang==X.Y.Z`
  round trip from the real index. See `docs/RELEASE.md`.
- **Maintainer one-time step:** create the PyPI *pending publisher* (project
  `ball-lang`, owner `Ball-Lang`, repo `ball`, workflow `publish-pypi.yml`,
  environment `pypi`). Without it the OIDC exchange fails loudly.

## For AI Agents
- The compiler and encoder both use the raw proto3-JSON dict view (camelCase
  keys), not the generated bindings — no protobuf runtime dependency.
- Fix compiled-program behaviour in `runtime/ballrt` (semantics) or
  `compiler/ball_compiler` (codegen); never hand-edit emitted output. Fix
  encoded-program shape in `encoder/ball_encoder`.
- `python/shared/` is generated by `buf generate`; regenerate after proto
  changes, never hand-edit.
