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

> **That gate is scoped to `dart/encoder/lib/encoder.dart` only** — it literally
> scans that one file's emit sites. It has no notion of `ts/encoder`,
> `rust/encoder`, `go/encoder`, `csharp/encoder` or `python/encoder`. Issues #489
> and #490 lived in exactly that blind spot: the TS encoder emitted fifteen std
> names no compiler implements, and left six syntax kinds unhandled, with the
> full "TypeScript" CI job green. The per-language equivalent is
> `ts/compiler/test/std_name_consistency.test.ts` (statically enumerate every
> name that encoder can emit, then compile each one) plus a documented carve-out
> file (`ts/encoder/ENCODER_CARVEOUTS.md`). A new language encoder needs both.

### 2b. A name-shape assertion is not a test
An encoder unit test that asserts `call.function === "list_add"` proves only that
the encoder is self-consistent. It passes *because* the bug exists, and it makes
the bug harder to fix, because the assertion has to be rewritten before the fix
can go green. #489/#490 shipped six such bug-locking tests — three of which
asserted an unhandled construct's `/* unhandled: ... */` placeholder as the
expected output, one of them under a comment admitting "this is a genuine
TS-encoder gap".

The counter-measure is that every construct must be exercised by a leg that
**executes** it end to end: `ts/encoder/test/roundtrip.test.ts`
(`encode() → compile() → run both → diff stdout`) for TS, the conformance corpus
for Dart. Both mismatched names and mismatched *field* names die there and
nowhere else — `string_replace` fed the wrong field names compiled silently to
`''`, which no name assertion can see.

> Coverage measured by *function-name presence* (the old 67% number tracked in
> [issue #134](https://github.com/Ball-Lang/ball/issues/134)) is **not**
> completeness: it counted
> `collection_for` as "covered" the moment any program referenced it, blind to
> the broken C-style variant and to wrong *values*. The gate measures
> **executed** emission instead.

> **The corpus can only reach IR some encoder can emit.** Valid Ball IR is a
> strict superset of that. A rule about a *shape no source language can express*
> is therefore structurally unreachable from a fixture and needs a targeted test
> that hand-builds the IR. Worked example: assigning to a getter-only property is
> a Dart **compile-time** error, so no `src/*.dart` (which must first run under
> `dart run`) can ever produce that IR — the C# compiler grafted a silent shadow
> field on it for months (#461). `csharp/compiler/test/AccessorEdgeCaseTests.cs`
> is the shape of the fix: build the `Program` in code, compile it, run it,
> assert. Before reaching for "add a fixture", check the shape is *emittable*.

> **Name the leg precisely when you ask "why didn't a test catch this?"** The
> obvious candidate is often not a corpus sweep at all. `csharp/compiler/test/
> EndToEndTests.cs`, for instance, hardcodes four fixtures — it was never in a
> position to catch a corpus-wide regression. The leg that *does* compile the
> whole corpus through the C# compiler is `csharp/engine/conformance --leg=
> compiler`, which lives in `conformance-matrix.yml` — a workflow with **no
> `pull_request` trigger** — and is a ratchet (`CSHARP_COMPILER_FLOOR`) that
> already tolerates its known gaps. "A gate exists" and "a gate runs on your PR
> and would have gone red" are different claims.

> **An assertion that cannot fail documents an intent; it does not enforce it.**
> Before adding an assertion, name the concrete change that would make it red. A
> loop that appends one result per entry of a static table and then asserts
> `results.Count == Table.Length` is checking the table against itself — that was
> the C# encoder sweep's "intact fixture set" claim until it was rewritten to
> compare the table against a real directory listing, in both directions. Same
> family as the positive-floor rule ("0 failed" over "0 ran" is a fake green),
> and same fix: assert against something *outside* the thing under test.

> **A failing test's own diagnostics are part of the test.** All three C#
> conformance legs described a mismatch by printing line 0 of each side, so a
> divergence on any later line rendered as `expected (3): 1` / `actual (3): 1` —
> a `Fail` whose diff reads like a match. `Fixtures.DescribeMismatch` now names
> the first line that actually differs, pinned by
> `csharp/engine/test/MismatchDescriptionTests.cs`. Silent degradation in a
> diagnostic costs the next debugger hours; treat it as a bug, not cosmetics.

> **A new fixture must clear every required PR check, on every target.**
> `406_subclass_field_over_getter` (a subclass field shadowing an inherited
> getter) ran correctly on Dart/TS/Rust/Go/Python/C# and the C++ *self-hosted*
> engine, but the Ball → C++ **compiled** leg — a different leg, and a required
> PR check — emitted a call to the hidden getter and `g++` rejected it. The
> fixture was withdrawn and the gap filed as
> [#501](https://github.com/Ball-Lang/ball/issues/501) rather than carved out.
> When you add a fixture, enumerate the legs it must pass — the engine rows and
> the compiled rows are not the same set.
>
> *Resolved:* #501 fixed the C++ emitter (a shadowing field now becomes a private
> renamed backing member plus a public `virtual` accessor pair over a virtualised
> ancestor getter, so the vtable — not a compile-time type guess — resolves it)
> and 406 is back, unchanged. `CPP_COMPILE_CARVEOUTS` is still empty.

> **One fixture per defect, not one per defect *family*.** 406 exercises only the
> READ side of a shadowed accessor, through a receiver whose static and runtime
> types agree. Three more fixtures were needed to pin the rest of the family, and
> each found something 406 could not:
> `431_shadowed_getter_dynamic_dispatch` reads through a base-declared method, so
> a fix that resolved the accessor against the receiver's *static* class — the
> wording #501's own body suggested — would compile and pass 406 while silently
> printing the base value here; `432_shadowed_getter_setter_write` gives the
> ancestor a `set x` as well, which is the only way to reach the emitter's
> `has_setter` branch at all; and `433_shadowed_field_self_write_and_local` writes
> the shadowing field *unqualified from inside its own class* and reads a
> method-local of the same name — the two shapes one step to the left of 406,
> where the first draft of the #501 fix emitted `ball_assign(x(), v)` (g++:
> "cannot bind non-const lvalue reference … to an rvalue") and `x()` on a plain
> local (which *builds*, because `BallDyn` has `operator()`, and silently
> answers `null`). 432 also went red on all six **engines**, exposing a separate,
> previously unknown defect: `_trySetterDispatch` ran an inherited setter for a
> field the instance declares itself, while the read path had always preferred
> the instance's own field — so the write was silently dropped and the read
> answered with the stale value. A fixture that only covers the shape you already
> fixed proves the fix, not the rule.
>
> **A silent-wrong-answer regression hides from a byte-diff blast-radius proof.**
> The corpus is the blast radius only for shapes the corpus contains. Both
> defects above were found by a reviewer compiling hand-written probe programs,
> not by the 328-fixture diff — so when a codegen change adds a new emission
> rule, write the probe programs for the shapes *adjacent* to the one you fixed
> and turn the ones that break into fixtures.

> **Withdraw or carve out?** Withdraw when the fixture's coverage exists
> elsewhere: 406's bug was already locked by
> `csharp/compiler/test/AccessorEdgeCaseTests.cs`, so dropping it cost nothing.
> Carve out — with the entry justified inline and referencing a filed issue —
> when the fixture is the *only* cross-target lock on behavior being fixed in
> that same PR. `416_user_method_name_arity_collision` is that case: it is the
> regression test for #494's arity fix, it is what caught the TS engine's
> `map_contains_key` prototype-pollution bug, and it lifts all four compiler-leg
> ratchets — withdrawing it would delete six engines' worth of coverage to keep
> a list empty. The Ball → C++ gap it exposes is
> [#511](https://github.com/Ball-Lang/ball/issues/511). Either way the answer is
> never "leave the leg red".
>
> A carve-out can also hollow out the leg itself: `full_e2e.sh`'s gate was
> `[[ $fail -eq 0 ]]`, so a `--fixtures` filter whose every entry was carved out
> would have exited 0 having compiled nothing. It now asserts a positive floor
> (`passed=0/failed=0` is an error). Adding a carve-out means re-checking that
> the gate around it can still fail.

### 2c. Every gate above is scoped to code WE wrote
The whole `tests/conformance/` corpus is hand-authored, single-file,
`main`-shaped Dart written to avoid the encoder's known syntactic traps, and
both the completeness gate and `conformance-matrix.yml` only ever look at it.
Nothing in CI has ever run the pipeline over a third-party package — which is
how a Rust encoder converting 0/196 real files (#491), a C# encoder converting
0/200 (#492), a TS compiler failing 37/129 (#489), and a Dart compiler emitting
unparseable Dart on real library files (#494) all shipped past 18 green required
checks on the same day.

`tools/coverage-study/` (issue #493) is the instrument for that gap; the
methodology, the two load-bearing harness settings, the current baseline and the
honest limits are in `tests/conformance/COVERAGE_STUDY.md`. It is **report-only**
— `coverage-study.yml` has no `pull_request:` trigger — because a floor set
before a baseline exists either goes permanently red and gets ignored or is set
so low it means nothing. The harness's **own** self-test is gated on every PR
(`ci.yml`'s Dart job), so the instrument cannot silently start skipping the file
shapes it exists to look at.


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

## Toolchain-drift canary (weekly `ci.yml` run on `main`)

Every CI job installs a **floating** toolchain (`dart-lang/setup-dart` with
`sdk: stable`, `actions/setup-node`, …). A toolchain release can therefore turn
`main` red with **zero commits** — and with only `push`/`pull_request` triggers
that red is first seen on the next contributor's *unrelated* PR. That is what
happened on 2026-09-02: a newly-stable Dart lint
(`unawaited_return_in_try_block`) failed the warnings-fatal `dart analyze dart/`
step on a C#-only PR, seven weeks after `main`'s last full run. `ci.yml` now
also runs on a weekly `schedule` (plus `workflow_dispatch`), so drift surfaces on
`main` itself; the `changes` job has no diff base on those events and fails
OPEN, so every stack runs. Treat a red scheduled run exactly like a red PR: fix
the code (never pin the SDK or suppress the lint to get green — the lint above
was pointing at a real frame-accounting bug in the engine, see
`dart/engine/test/constructor_frame_test.dart`).

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

**The bar is 100%, and honest product coverage has reached it**: 100.00% of
reachable lines on CI (99.99% on a local Windows run — the one delta line is
covered by a POSIX-only test), all 9 Dart packages' `lib/`; `bin/` entry-point
tooling excluded — see `coverage_dart.dart`. Dedicated suites drove the
workspace from ~64% to 100%. Per-package (see the authoritative comment in
`.github/workflows/coverage.yml`): every package at 100% (`cli` 99.80% on
local Windows only). Residual uncovered code is **excluded per-site, never
silently**: every `// coverage:ignore-*` marker carries an adjacent
justification comment, in one of three categories — environmental I/O
(network: pub.dev/git/HTTP; raw-binary stdout; the external-runner
conformance harness), verified-unreachable defensive arms (proven per-arm via
caller analysis), and `bin/` entry-point glue. The floor in `coverage.yml` is
currently **99.9** and locks in non-regression. **Line coverage is the
*secondary* metric** — the primary behavioral guarantee against the #55 class
is the construct-completeness gate (§2). TS (`c8 --all`, plus per-package c8
floors in each `package.json` gated by ci.yml), C++ (`gcov`/`lcov --initial`,
aggregate floor **87** against a measured 88.3%) and Rust (`cargo llvm-cov`,
floor 65 over authored crates) are measured the same way (all packages,
never-executed files at 0%); their **behavioral** coverage is additionally
gated by the conformance matrix.

**Trigger caveat, and the gap it left (#63).** `coverage.yml` used to run ONLY
on push-to-main and manual dispatch. Since the C++ line-coverage floor is the
only C++ coverage gate in the repo (ci.yml's `cpp` job has no instrumentation,
and `codecov.yml` marks project+patch `informational: true` for every flag), a
PR that dropped C++ coverage passed every required check and was caught only
after merging. The `cpp` job now also runs on `cpp/**`-touching pull requests;
the other four jobs stay push/dispatch-only so a C++ PR doesn't drag the whole
cross-stack matrix in. It is deliberately **not** a required check — it makes
the regression visible pre-merge, it does not block. The finer per-target C++
floors (`cpp/build-cov-floor.sh`: compiler 88 / encoder 88 / shared 81) are
**reported, not enforced** — never measured by CI, and a false red on main is
worse than an unenforced number; they ratchet once two runs establish a
baseline. That script's parser is pinned by
`cpp/test/test_build_cov_floor_parsing.sh` (it used to pass silently when it
could not parse a summary at all).

> A failing/ungated package suite (e.g. `ball_protobuf`, issue #75) is measured
> but surfaced as a loud WARNING and under-counted — `coverage_dart.dart`
> MEASURES coverage, it is not the test gate (that is `ci.yml`).

## CI gates (where each invariant lives)

| Invariant | Gate | Trigger |
|---|---|---|
| Oracle = native Dart | `generate_conformance.dart` + drift check | every PR (`ball-freshness`) |
| Reverse sourcing | `check_conformance_sources.dart` | every PR |
| **Completeness (§2)** — Dart encoder only | `check_encoder_completeness.dart` | every PR |
| **Encoder/compiler std-name consistency (§2)** — TS | `ts/compiler/test/std_name_consistency.test.ts` | every PR (`TypeScript`) |
| **Constructs are executed, not just named (§2b)** — TS | `ts/encoder/test/roundtrip.test.ts` | every PR (`TypeScript`) |
| **Self-hosted engine survives a compiler change** — TS | `ts/compiler/test/engine_runtime.test.ts` (regenerates `engine.ball.json` on demand; never skips) | every PR (`TypeScript`) |
| **No false coverage (§4)** | `check_fixture_names.dart` | every PR |
| Engine/compiler behavior | `conformance_test.dart`, `conformance_compiler_inprocess_test.dart` | every PR |
| Real subprocess round-trip (engine, `dart run`, `node`, encoder-in-the-loop) | `conformance_roundtrip_test.dart` (`@Tags(['slow'])`) | `slow-conformance.yml`, weekly + manual only |
| Cross-engine parity (§5) | `conformance-matrix.yml` (Dart/TS/C++) | push to main + weekly |
| Encoder-reads-back-the-compiler measurement (Ball → `<lang>` → Ball → **Dart** engine → golden) | `conformance-matrix.yml`'s `csharp-roundtrip` / `python-roundtrip` / `go-roundtrip` / `rust-roundtrip` rows (#452) | push to main + weekly + dispatch — **NOT a PR gate** (no floor either: an honest 0/321 is the product) |
| Changed-stacks detection (decides which jobs above run at all) | `.github/actions/detect-changed-stacks` + its `test/truth_table.sh` | every PR (the truth table runs in the always-on `proto` job) |
| **Third-party code (§2c)** — Dart Tier A | `tools/coverage-study/rq1_study.dart` via `coverage-study.yml` | weekly + manual — **report-only, NOT a PR gate** (issue #493 slice 1) |
| Coverage-study harness's own correctness | `tools/coverage-study/test/rq1_study_self_test.dart` | every PR (`Dart`) |
| Line coverage ratchet (Dart/TS/Rust/C#) | `coverage.yml` | push to main + manual — **NOT a PR gate** |
| Line coverage ratchet (C++) | `coverage.yml`'s `cpp` job | push to main + manual, **plus cpp-touching PRs** (#63) — reports, does not block (not a required check) |
