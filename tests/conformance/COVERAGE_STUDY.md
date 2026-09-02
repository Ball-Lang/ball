# Third-party coverage study (issue #493)

Everything else in `tests/conformance/` measures Ball against code **this
project wrote**. This document describes the study that measures it against
code it did not.

## Why

`dart/encoder/bin/check_encoder_completeness.dart` gates that every std base
function the encoder can emit appears in at least one executed fixture under
`tests/conformance/src/`, and `.github/workflows/conformance-matrix.yml` runs
every engine over that same corpus. Both are scoped, by construction, to ~320
hand-authored, single-file, `main`-shaped programs deliberately written to
avoid the encoder's known syntactic traps.

Neither has ever run over a third-party package. That is how all of the
following shipped past 18 green required checks on the same day:

| Issue | Finding |
| ----- | ------- |
| #491  | Rust encoder converted 0 of ~196 real library files |
| #492  | C# encoder converted 0 of ~200 real library files |
| #489  | TS compiler failed on 37 of 129 real files |
| #488  | Dart encoder produced type errors in 13 of 16 real files |
| #494  | Dart compiler emitted unparseable Dart on real library files |

## Tier A — structural round-trip over pinned packages

`tools/coverage-study/rq1_study.dart`. For every `.dart` file in the pinned
packages' `lib/` trees:

1. **encode** — `DartEncoder().encode(source)`
2. **compile** — `DartCompiler(program).compileModule(name)` for every non-std
   module
3. **re-encode** — `DartEncoder().encode(compiled)`
4. **declaration inventory** — the set of top-level declarations (classes,
   enums, mixins, extensions, extension types, typedefs, functions, variables)
   plus every class/mixin/extension member name, compared before and after; a
   lost declaration is `declaration-drift`
5. **second-generation fixpoint** — compile the re-encoded program again; the
   Dart text and the metadata-stripped Ball IR must be identical to generation
   1's. A pipeline that neither loses nor invents meaning reaches a fixpoint;
   one that keeps rewriting the program on every pass is losing information.

A file is **clean** only if all five stages hold. Files with no top-level
declarations (directives-only libraries, part stubs) are reported as `skipped`
and excluded from the denominator — they are not evidence either way. A pin
that cannot be fetched is reported as `unreachable` and likewise not scored, so
a network hiccup never reads as an encoder regression.

### Two load-bearing settings — do not "simplify" these away

1. **Per-module `compileModule`, never `compile()`.** Real library files have
   no `main`. `DartCompiler.compile()` needs an entry point *and* wraps its
   `_format` call in a try/catch that falls back to unformatted output
   (`compiler.dart`, the `_emitRaw` fallback) — which silently converts "the
   compiler emitted Dart that does not parse" into a pass. `compileModule()`
   has no such fallback, which is why #494's `FormatterException` is visible to
   this harness at all.
2. **Format before the check.** `compileModule()` runs `dart_style`, so
   unparseable output fails at stage 2 instead of being scored on its raw text.

`tools/coverage-study/test/rq1_study_self_test.dart` pins both settings: it
feeds the harness a synthetic two-file package shaped like the #491/#492
failure mode (cross-file class reference, no top-level `main`) and asserts every
file is **scored**, not silently skipped — which only holds while the per-module
mode is in place. It also asserts a straightforward file is reported clean (so
the harness cannot pass by calling everything dirty), that a real-code shape the
pipeline does not survive is reported with a taxonomy reason, and that the #494
arity-collision shape now survives. That self-test runs as a **gated** step in
`ci.yml`'s Dart job — the instrument is gated even though the study is not.

### What Tier A does and does not catch

Tier A is a **structural** measure. It catches the #494 class outright: a file
the encoder refuses, or one the compiler turns into Dart that does not parse,
fails at stage 1 or 2. It does **not** catch the #488 class: `return s.add(x)`
on a `Set` compiles back to the cascade `return s..add(x);`, which parses,
keeps every declaration and reaches a fixpoint — it is only wrong once Dart's
*static types* are considered. Detecting that needs either a resolved-AST
diagnostic diff or Tier B. Do not read a high Tier A number as "the pipeline
handles real code".

### Baseline (2026-09-02, five pinned packages, 106 scored files)

| | clean | reasons |
| --- | --- | --- |
| before this PR's encoder fix | 64/106 (60%) | 41 `fixpoint-drift`, 1 `compile-error` (`async` `lib/src/stream_splitter.dart`, #494 Bug A) |
| after | 65/106 (61%) | 41 `fixpoint-drift` |

The `Tier A (IR fixpoint, informational)` line (8/106) compares generation 1
against generation 0 and is reported for observability only. It is expected to
be low: the compiler faithfully lowers Ball's single `input` parameter back to a
named local (`int twice(int input) { int value = input; … }`), so almost nothing
is IR-identical across the *first* pass. That is why stage 5 compares
generations 2 and 3 instead.

## Tier B — substitution into a package's own test suite (not yet built)

For hermetic packages, replace one library file at a time with its compiled-back
version and run the package's own `dart test`. This is the tier that would catch
the #488 class, because the package's tests exercise real types and real values.
Not implemented in slice 1.

## Running it

```bash
# The harness self-test (also gated in ci.yml's Dart job)
dart run tools/coverage-study/test/rq1_study_self_test.dart

# Tier A over the pinned packages (clone each pin into <dir>/<name> first;
# .github/workflows/coverage-study.yml does exactly this)
dart run tools/coverage-study/rq1_study.dart \
  --pins tools/coverage-study/packages/dart.json \
  --checkouts <dir> \
  --json tier_a.json

# Tier A over one directory (no pin file needed)
dart run tools/coverage-study/rq1_study.dart \
  --package myapp --source-dir path/to/lib
```

## Status and honest limits

`.github/workflows/coverage-study.yml` is `workflow_dispatch` + a weekly
Monday schedule. It has **no `pull_request:` trigger and is not a required
check**, so a regression it finds does not block the PR that caused it. That is
deliberate — floors set before a baseline exists either go permanently red and
get ignored, or are set so low they mean nothing. The job fails only when the
harness itself failed (no summary line, or zero files scored).

Remaining slices of #493:

2. Floor the Dart Tier A number once a few scheduled runs establish a baseline.
3. Port Tier A to TS, Rust, C#, Go and Python (each with its own pin list;
   Rust/C# start near 0% per #491/#492, so their floors come after those epics).
4. Tier B for Dart (hermetic test-suite substitution).
5. Publish the coverage table next to the engine-parity table in the README.
