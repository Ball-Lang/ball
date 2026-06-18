# Ball Testing Strategy

Ball's correctness bar is **the cross-language conformance matrix**: every
language (Dart / TypeScript / C++ / …) must **compile AND encode AND execute**
the conformance corpus, and every program must behave identically to its
source language. This document explains how we *guarantee* that — and the
failure modes we deliberately design against.

It exists because of [issue #55](https://github.com/Ball-Lang/ball/issues/55): a
Dart collection-`for` (`[for (var i = 0; i < n; i++) f(i)]`) silently
round-tripped to `[]`. It was not a one-off — it was a **whole family** (C-style
`collection_for`, `collection_if`, `spread`/`null_spread`, set & map
comprehensions) broken across the Dart, TS, and C++ engines — and our "rigorous
cross-language conformance suite" never caught any of it. The post-mortem below
is the reason for every rule in this file.

## Root cause of #55 (read this before changing test infra)

The bug was an engine defect. The *reason it survived* was three compounding
flaws in the test strategy:

1. **Coverage was a hand-curated allowlist.** Conformance only tested the
   constructs someone remembered to drop a `tests/conformance/src/*.dart` for.
   Nothing forced the corpus to exhaust the encoder's emittable surface. No
   source used `[for ...]`, `[...x]`, or set/map comprehensions, so those base
   functions were **never executed** — and their broken handling was invisible.

2. **False coverage.** `92_list_comprehension.dart` contained *no comprehension*
   — it was an imperative `for` + `.add()`. A test named for the exact feature
   that was broken, that didn't test it. Worse than no test: a green light over
   a hole.

3. **Silent degradation by design.** Unimplemented base functions returned
   `null`/`[]` (e.g. `collection_for` was registered as `(_) => null`) and the
   encoder emitted `/* unsupported element */` placeholder *strings* instead of
   failing. Gaps became wrong answers instead of loud errors.

The oracle itself was sound (`generate_conformance.dart` runs **native Dart** to
produce expected output). The disease was **completeness + fail-loud**, not the
oracle.

## The invariants (non-negotiable)

### 1. The oracle is the real source language, never the system under test
`generate_conformance.dart` runs each `src/<name>.dart` through **native `dart
run`** to capture `*.expected_output.txt`, then encodes the same source to
`*.ball.json`. The engine/compiler outputs are diffed against that native
oracle. Never derive expected output from the encoder/engine — that bakes bugs
into the "expected" file and they pass forever.

### 2. Every emittable construct must be executed by a fixture (completeness)
Enforced by `dart/encoder/bin/check_encoder_completeness.dart` (CI, every PR):
every std base function the encoder *can emit* must appear in at least one
executed conformance fixture, or be a documented carve-out in
`tests/conformance/ENCODER_COMPLETENESS_CARVEOUTS.md`. This is the forward
direction that was missing for #55. `check_conformance_sources.dart` enforces
the reverse (every `.ball.json` has a source).

> Coverage measured by *function-name presence* (the old 67% number in
> `docs/CONFORMANCE_GAPS.md`) is **not** completeness: it counted
> `collection_for` as "covered" the moment any program referenced it, blind to
> the broken C-style variant and to wrong *values*. The gate measures
> **executed** emission instead.

### 3. Fail loud, never degrade silently
A construct the engine/encoder/compiler does not handle must **throw**, not
return `null`/`[]`/a placeholder string. Silent degradation is the amplifier
that turns a missing feature into silent wrong output. Concrete guards now in
place: `collection_for`/`collection_if` throw if dispatched outside a literal
(`engine_std.dart`); the encoder throws on an unknown collection element instead
of emitting `/* unsupported */`.

### 4. A fixture's name must not overstate its coverage
Enforced by `dart/encoder/bin/check_fixture_names.dart` (CI): a fixture named
`*comprehension*` / `*spread*` / `*null_aware*` / `*cascade*` must actually use
that syntax. Prevents the `92_list_comprehension` class of false coverage.

### 5. One fix, all engines
The TS (`ts/engine/src/compiled_engine.ts`) and C++
(`dart/self_host/lib/engine_rt.cpp`) engines are **generated** from the authored
Dart engine (`dart/engine/lib/engine.dart` + parts). Fix the Dart engine, then
regenerate (`dart/compiler/tool/gen_engine_json.dart`, then the TS/C++ regen
commands in `CLAUDE.md`) and verify all three. A Dart-only fix is half a fix.
**Compilers are separate** — the Dart, TS, and C++ Ball→source compilers each
need their own fix and their own verification (the `cpp-compiled` conformance
leg compiles every fixture through the C++ compiler).

### 6. Engine code must be self-host-portable
Because the engine is itself encoded to Ball, its Dart source must avoid
constructs the syntactic encoder mishandles. The one that bit #55's fix:
`List.addAll` routes to the non-mutating `list_concat`, so a spread splice
written with `result.addAll(items)` works on Dart but silently drops elements on
TS/C++. Append per-item with `.add`. Same caution for `Map.addAll`, `.keys`.
See [.claude/rules/dart.md](../.claude/rules/dart.md).

## Adding a language construct (the required workflow)

1. Encode it (`dart/encoder/lib/encoder.dart`). If a new collection element or
   base function, **fail loud** on any shape you don't handle.
2. Execute it (`dart/engine/lib/engine.dart`). Mirror across the lazy/eager
   dispatch as needed.
3. Add a `tests/conformance/src/NN_<name>.dart` fixture that actually uses the
   construct (the completeness + name gates will fail otherwise) and
   `dart run bin/generate_conformance.dart`.
4. Compile it in every target compiler (Dart/TS/C++).
5. Regenerate the self-host engines and run the conformance matrix
   (`dart/engine`, `ts/engine`, `cpp` `full_e2e.sh`).

## Coverage ratchet (toward 100% line coverage)

Beyond construct-completeness (§2), we measure **line coverage** and ratchet it
upward, never down — across **all three stacks**, uploaded to Codecov with
per-stack flags (`dart`/`typescript`/`cpp`) via OIDC (no token). Gate:
`.github/workflows/coverage.yml`.

**Completeness is the whole point — measure every package and every file, or the
number lies.** The Dart tool `tools/coverage_dart.dart`:

- **discovers every package dynamically** (`dart/*/pubspec.yaml`) — no
  hand-maintained allowlist, so a new package can't silently drop out (the bug
  the original tool had: it measured only 4 of 10 packages, reporting a
  cherry-picked number);
- counts **every authored `lib/`+`bin/` file**, including files **no test ever
  loads** (emitted at 0% via a conservative line proxy — omitting untested files
  is exactly what inflates a coverage number);
- **credits cross-package coverage** — each suite's lcov already reports the
  workspace path-deps it exercises (the engine suite covers `shared`), max-merged
  across all suites into one `coverage/dart.lcov`;
- excludes only generated/never-authored files (`**/gen/**`, `*.pb.dart`,
  `engine_roundtrip.dart`, `compiled_engine.ts`, `engine_rt.cpp`) and pure
  barrel/`export` directives (no instrumentable lines).

**The bar is 100%; the honest full-repo baseline is ~51.7%** (all 9 Dart
packages, all authored files). Per-package highlights: `engine` 65%, `compiler`
43%, `encoder` 37%, `shared` 39%, `ball_protobuf_gen` 89%, and `cli` 0% (an
entry-point package whose only code is `bin/ball.dart`, integration-tested via a
subprocess that line coverage can't see). Reaching 100% is a deliberate, multi-PR
climb; the floor in `coverage.yml` locks in non-regression and must be raised
toward 100% one PR at a time. **Line coverage is the *secondary* metric** — the
primary behavioral guarantee against the #55 class is the construct-completeness
gate (§2). TS (`c8 --all`) and C++ (`gcov`/`lcov --initial`) are measured the
same way (all packages, never-executed files at 0%); their **behavioral**
coverage is additionally gated by the conformance matrix.

> A failing/ungated package suite (e.g. `ball_protobuf`, issue #75) is measured
> but surfaced as a loud WARNING and under-counted — `coverage_dart.dart`
> MEASURES coverage, it is not the test gate (that is `ci.yml`).

## CI gates (where each invariant lives)

| Invariant | Gate | Trigger |
|---|---|---|
| Oracle = native Dart | `generate_conformance.dart` + drift check | every PR (`ball-freshness`) |
| Reverse sourcing | `check_conformance_sources.dart` | every PR |
| **Completeness (§2)** | `check_encoder_completeness.dart` | every PR |
| **No false coverage (§4)** | `check_fixture_names.dart` | every PR |
| Engine/compiler behavior | `conformance_test.dart`, `conformance_roundtrip_test.dart` | every PR |
| Cross-engine parity (§5) | `conformance-matrix.yml` (Dart/TS/C++) | push to main + weekly |
| Line coverage ratchet | `coverage` job | every PR |
