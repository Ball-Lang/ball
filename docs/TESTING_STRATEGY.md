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

Beyond construct-completeness (§2), we measure **line coverage** of the
correctness-critical Dart packages and ratchet it upward, never down. Tool:
`tools/coverage_dart.dart` (aggregates `dart test --coverage-path` lcov,
excluding generated/never-authored files — `**/gen/**`, `compiled_engine.ts`,
`engine_rt.cpp`, `engine_roundtrip.dart`). Gate: `.github/workflows/coverage.yml`
(`dart run tools/coverage_dart.dart --floor N`).

**The bar is 100%; the honest current baseline is far from it** — measured
≈22% for `shared`/`engine`/`encoder` (engine 28%, encoder 16%, shared 22%;
`compiler` adds more from its snapshot/round-trip suites). The encoder figure
*understates* effective coverage because its 280-fixture exercise runs through
`generate_conformance`, not `dart test`. Reaching 100% line coverage is a
deliberate, multi-PR climb: the floor in `coverage.yml` locks in non-regression
today and must be raised toward 100% one PR at a time. **Note:** line coverage
is the *secondary* metric. The *primary* behavioral guarantee against the #55
class is the construct-completeness gate (§2), which is at 100% of
encoder-emittable constructs now.

TS and C++ line-coverage ratchets are roadmap (their engines are generated from
the Dart source, so Dart coverage is the leading indicator); their **behavioral**
coverage is already gated by the conformance matrix.

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
