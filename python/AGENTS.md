<!-- Parent: ../AGENTS.md -->

# Python (runtime + compiler + encoder + engine + cli)

## Third-party coverage study — Tier A (`tools/coverage-study/rq1_study_py.py`, #493)

Runs pinned third-party packages through `ball_encoder.encode` →
`ball_compiler.compile_library` → `ball_encoder.encode`, diffs the declaration
inventory using the **stdlib `ast` directly** — never `ball_encoder`'s own walk —
and checks a second-generation fixpoint.

Current measurement: **0/70 clean** (4 pinned packages,
`tools/coverage-study/packages/python.json`). 2 files encode, compile back,
re-encode and keep every declaration; the wall is stage 5 (the compiler's
`_input=None` prologue has no encoder inverse, so generation 2 grows one
`_input_N = _input` line), and the other 68 never encode at all (the
top-level-class gap). Do not "improve" that number by changing the pin list.

The denominator is **70, not 73**, and it is decided from each file's SOURCE at
stage 0 (`has_scorable_material`): three of `pyparsing`'s `__init__.py` package
markers are zero-byte, so there is nothing in them to measure. Deciding that
after the pipeline is issue #721 — it made `scored` a function of the encoder,
and #646 moved the row 73 → 70 with not one file changed. A file that HAS
declarations and comes back with none is a scored failure, never a skip.

`python tools/coverage-study/test/rq1_study_py_self_test.py` is the harness's own
self-test and **is gated on every PR** in ci.yml's `python` job (both files are
also in the `compileall` syntax gate). The RUN is the
`python-tier-a` job in `coverage-study.yml`, which has **no `pull_request:`
trigger**; its row is floored by ratchet in that workflow's `publish` job. Methodology: `tests/conformance/COVERAGE_STUDY.md`.

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

# NEEDS `dart` (or BALL_DART) + a resolved workspace (`dart pub get` at the repo
# root): tests/test_reference_engine_roundtrip.py runs the original AND the
# re-encoded program on the DART reference engine (#785). An unresolvable `dart`
# FAILS this suite, it never skips it.
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
**compiler** passes **124 tests**, the **encoder 138** (which need `dart` — see
`encoder/AGENTS.md`), and the **CLI** drives all four verbs in-process
(`run`/`compile`/`encode`/`check`). The **self-hosted
engine** runs the whole conformance corpus at **Dart parity**:
`Results: 363 passed, 0 failed, 363 total (4 skipped carve-outs)` — Dart-identical
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

It measured a flat **`0 passed, 321 failed`** from the day it shipped
(2026-09-02) until #642. That zero was not "expected by construction": the
encoder refused the compiler's own output outright — the `try:`/`except
ballrt.BallReturn` wrapper the compiler put around EVERY function body, and every
`ballrt.*` base-call helper. #642 fixed both halves (conditional wrapper
emission + `ball_encoder/ballrt_calls.py`, the inverse surface) and #690 tracks
the remainder, mapping one shape family at a time.

**A ratcheted MEASUREMENT, not a parity gate.** `tools/ci/roundtrip_floor.sh`
enforces harness health PLUS `passed >= 1` PLUS
`passed >= PYTHON_ROUNDTRIP_FLOOR` — so a flat zero is red and a fixture that
used to round-trip still must. The floor only rises: **raise it in the SAME PR as
the fix that earned it** (the job prints the exact new value). Never lower it,
and never make a row green by weakening either side. Reads goldens and subprocess
stdout as **bytes**, normalising only CRLF.

`try:` — which headed the list at 142 occurrences and was the SOLE blocker of 79
fixtures — is done: `encoder.encode_try`/`encode_while` invert all four shapes
the compiler emits (the loop break/continue trap, the `BallReturn` body wrapper
and its constructor form, and a real `std.try`), together with the
`brk`/`cont`/`ret`/`rethrow` flow helpers. See `encoder/AGENTS.md` for the table
and for why a trap is never inlined on sight.

The remaining blockers, in descending order of the fixtures they head: method
calls on a receiver (which is the same problem as top-level classes), dict
literals, and the `arg` parameter prologue, whose inverse depends on the
enclosing function's arity. All are named in #690.

CI home: the `python-roundtrip` row in `.github/workflows/conformance-matrix.yml`.
**That workflow is a PR gate since #619** — it has a path-filtered `pull_request:`
trigger sharing its `push` filter, and `python/**` is in that filter, so the row
runs on any PR touching this directory with no `gh workflow run` dispatch.

### The reference-engine half of the FAST suite (#785)

The whole-corpus leg above is the only place the Python pipeline used to meet the
Dart reference engine. The fast in-package guards
(`encoder/tests/test_ballrt_inverse.py`, `test_ballrt_namespaced.py`) re-encode a
fixture and run it **in-process under `ballrt`**, so a re-encoded tree that
Python's own runtime evaluates happily and the reference engine rejects was
structurally invisible to them — `ballrt.getfield` answers `None` for an absent
key (`runtime/ballrt/values.py`, proto3-default tolerance) where the engine fails
loud with `BallRuntimeError: Field "…" not found`.

`encoder/tests/test_reference_engine_roundtrip.py` closes that. For every fixture
those two suites certify — the set is **derived from their own lists**, never kept
there — it runs the ORIGINAL `.ball.json` *and* the RE-ENCODED program on
`dart run dart/cli/bin/ball.dart run` and asserts byte-identical stdout, with the
fixture's golden as the third leg. Its negative control encodes two
compiler-shaped programs that `ballrt` cannot tell apart and the reference engine
can, so the instrument is proven rather than trusted. This is the Python sibling
of `csharp/encoder/test/ReferenceEngineExecutionTests.cs` (#689/#730), including
its no-skip rule: an unresolvable `dart` is a FAILURE. `ci.yml`'s `python` job
therefore sets Dart up **before** its test steps — do not move that back down.

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
  environment left blank — the workflow declares no GitHub environment, matching
  the npm/crates/nuget/pub.dev channels). Without it the OIDC exchange fails
  loudly.

## For AI Agents
- The compiler and encoder both use the raw proto3-JSON dict view (camelCase
  keys), not the generated bindings — no protobuf runtime dependency.
- Fix compiled-program behaviour in `runtime/ballrt` (semantics) or
  `compiler/ball_compiler` (codegen); never hand-edit emitted output. Fix
  encoded-program shape in `encoder/ball_encoder`.
- `python/shared/` is generated by `buf generate`; regenerate after proto
  changes, never hand-edit.

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

### A typed `on T catch` is a TYPE TEST (issue #724)

A typed exception is only half of the contract; the other half is that a clause whose type does
NOT match must not run. `python/compiler`'s `run_try` compiled `catches[0]` alone, as an
unconditional catch-all with its `type` ignored, so a typed clause ran for any payload and every
later clause was dropped — the defect #615 closed for Rust/C#/Go. It now emits a dispatch chain
over `ballrt.catch_matches` (`python/runtime/ballrt/flow.py`), and `python/encoder` reads that
chain back as the multi-clause `catches` list, so the compiler/encoder pair stays closed.

The reason it survived a whole-corpus row is worth carrying: **the `python-engine` row runs the
SELF-HOSTED engine**, whose catch dispatch is Ball code (`_evalLazyTry`), and the engine source
contains no typed `on T catch` at all — so a user program's typed `try` never reached this
lowering. The leg that CAN see it is the one that compiles a conformance fixture through the
compiler under test (`python/compiler/tests/test_conformance.py`'s `PROVEN` list, and
`python -m conformance.runner` for the corpus-wide number).
