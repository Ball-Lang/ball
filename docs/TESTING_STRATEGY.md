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

A stdout-diffing harness must also be **environment-independent**, or its
verdict is not about the code. `roundtrip.test.ts` spawned each side with the
inherited environment and compared raw bytes; Node's `console.log` colourises a
bare `number` but never a `string`, and the Ball compiler always stringifies via
`__ball_to_string(...)`, so in a colour-capable shell the original came back
ANSI-wrapped and the round-trip plain — 18 phantom failures locally, and zero on
a TTY-less CI runner, which is why nothing caught it
([#518](https://github.com/Ball-Lang/ball/issues/518)). The harness now pins the
CHILD's `FORCE_COLOR=0`/`NO_COLOR=1` through `execSync`'s `env` (a shell prefix
is not cross-platform, and `NO_COLOR` alone is ignored by Node whenever
`FORCE_COLOR` is already set), strips SGR escapes from both sides, and carries
an invariant test that runs one fixture under a forced-colour and a colour-less
child and asserts the two agree — so the regression is gated on the CI runner
too, without a colour-forced CI leg.

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
> answered with the stale value. 433 in turn went red on the **TypeScript
> compiler** leg for a defect with no C++ content at all: a bare reference to a
> method-local named after a class member compiled to `this.<name>`, so the
> method silently answered with the MEMBER's value, and a function body's tail
> `result` was compiled after its scope had already been restored, hiding the
> local a second way. A fixture that only covers the shape you already
> fixed proves the fix, not the rule.
>
> **A fixture family that only ever uses ONE class per name cannot tell a
> per-class rule from a program-wide one.** 406/431/432/433 all have exactly one
> class family using a given shadowed field name. With at most one such family in
> a program, the emitter's program-wide `shadowed_getter_names_` set and its
> correctly per-class `class_shadowed_fields_` map emit **byte-identical** C++ —
> so four fixtures agreed for two releases while an unrelated class's own plain
> `int x` was being routed through an accessor it does not have
> ([#515](https://github.com/Ball-Lang/ball/issues/515)).
> `439_unrelated_field_name_collision` is the first fixture with a SECOND,
> unrelated class reusing the name, which is the only shape that separates them.
> When a fix keys off a name, add the fixture where two unrelated owners share it.
>
> **Value semantics need a fixture per BOUNDARY, not per mechanism.**
> [#509](https://github.com/Ball-Lang/ball/issues/509) stopped a C++ struct local
> from slicing a subclass, and 431-433 all cross that boundary through a `let`.
> Nothing crossed a base-typed function PARAMETER or a base-typed RETURN, so both
> kept slicing ([#516](https://github.com/Ball-Lang/ball/issues/516)) — and the
> failure is invisible to every leg but one: `g++` compiles the sliced code
> cleanly, and every other target's engine is an interpreter with reference
> semantics that never slices. Only the compiled-and-RUN C++ leg asserting on
> stdout can see it. `440_base_typed_param_return_slicing` printed `1\n1` instead
> of `10\n10` with a green build. Enumerate the *boundaries* a value can cross,
> not just the one you fixed.

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
> *Resolved:* #511 gave each of `compile_method_call`'s STL/Dart-SDK shortcuts
> the arity window of the Dart method it stands for, so a same-named user method
> with a different argument count falls through to user-defined class method
> dispatch instead of being spliced into the shortcut's template. 416's carve-out
> is gone (the list is no longer empty only because #512 added the four `43x`
> entries covered below — 416 itself is back on the leg). Note what the carve-out's
> removal did **not** get for free: `changed_fixtures` is computed only from
> git-diffed `tests/conformance/*.ball.json`, so a PR that deletes a carve-out
> without touching the fixture leaves its own per-PR compiled-e2e step blind to
> it. Re-run `full_e2e.sh` unfiltered (or `--fixtures <stem>`) yourself before
> claiming a de-carved fixture is green.
>
> The four `43x` constructor fixtures added for #499 are the same case: they
> are the only cross-target lock on "a constructor that builds another
> instance of its own class must not silently get `self` back", and they pass
> on every ENGINE — the Dart reference one plus all six self-hosted ones, the
> C++ included. **That** is the coverage that survives carving them out of the
> Ball -> C++ *compiled* leg. The two Ball -> C++ gaps they expose are filed as
> [#513](https://github.com/Ball-Lang/ball/issues/513) (a read through a
> nullable self-referential field emits a concrete-struct member access on
> `BallDyn`) and [#514](https://github.com/Ball-Lang/ball/issues/514) (a class
> whose only constructor is zero-argument gets a duplicate default one). Both
> are g++ build failures, not Ball -> C++ compile failures.
>
> **Name the leg that actually covers it — measure, do not assume.** An earlier
> draft of the paragraph above also claimed those four fixtures "pass on the
> Rust/Go/Python/C# compiler legs". Measured one fixture at a time, they do not:
> `435_recursive_ctor_construction` and `437_recursive_ctor_tree` (unnamed
> constructors) pass all four, while `436_recursive_ctor_named` and
> `438_ctor_initializer_list_with_body` fail **all four** — Rust
> `[E0425] cannot find value 'Countdown'`, C# `CS0103: The name 'from' does not
> exist in the current context`, a Go `build` error, Python
> `unresolved reference 'Countdown'`. None of those four compilers resolves a
> NAMED constructor (`Class.name(args)`), which the Dart encoder emits as a
> method call on the class reference rather than as a `messageCreation`; that
> pre-existing gap is filed as
> [#527](https://github.com/Ball-Lang/ball/issues/527). CI stays green because
> those legs are **ratcheted** — they fail only on a DROP below a recorded floor
> (73-89 pre-existing failures each), and are explicitly not parity gates. A
> ratcheted leg going green tells you nothing about a specific fixture: run it.
>
> **A new base function can be right everywhere and still not agree everywhere.**
> `434_type_of` (#489's fixture) prints `Set` on line 8 — the real `dart run`
> oracle — on every engine, on the C++ compiled leg, and on the Go and Python
> compiler legs, and prints `List` on the Rust and C# ones. That is not a
> `type_of` defect: neither runtime has a set representation at all
> (`rust/shared`'s `ball_set_create` returns a `BallValue::List`,
> `csharp/shared`'s `SetCreate` returns a `BallList`), so a compiled set *is* a
> list there; both runtimes' `Set` arm keys on the portable
> `{'__ball_set__': [...]}` map form only the self-hosted engines materialise.
> `x is Set` has been answering wrongly in those two targets for as long as it
> has existed, unnoticed, because nothing ever asked — 434 is the first test
> that does. Filed as
> [#528](https://github.com/Ball-Lang/ball/issues/528); the fixture keeps its
> `Set` line, because deleting it would delete the only place the divergence is
> visible.
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
methodology, the load-bearing harness settings, the current baselines and the
honest limits are in `tests/conformance/COVERAGE_STUDY.md`. It is **report-only**
— `coverage-study.yml` has no `pull_request:` trigger — because a floor set
before a baseline exists either goes permanently red and gets ignored or is set
so low it means nothing. Each harness's **own** self-test is gated on every PR
(in that language's `ci.yml` job), so the instrument cannot silently start
skipping the file shapes it exists to look at.

Tier A now exists for **five** languages: Dart (`rq1_study.dart`), Rust
(`rust/tools/rq1-study`), C# (`csharp/coverage-study`), Go
(`tools/coverage-study/go`) and Python (`rq1_study_py.py`). TypeScript is
deliberately deferred — `ts/compiler`'s `compileModule` takes a single Module
*facade* built for the `ball_protobuf` inline-embedding case, not one module of
a loaded multi-module `Program`, so a TS port needs a genuinely new compiler
primitive rather than a wrapper around the facade.

Each port also prints a per-stage **funnel** beside the clean percentage,
because for the four ports the clean number is 0% and the information is
entirely in *where* files stop: the Rust/C#/Go/Python compilers emit
runtime-call-shaped source their syntactic encoders were never built to read
back, so stage 3 (re-encode) is a wall — the same wall the `*-roundtrip` rows
already report as an honest 0/32x on the project's own corpus. A bare 0% would
hide the difference between "the encoder rejected the file outright" (Rust, Go:
0 files even encode) and "58 of 472 files got all the way to the declaration
diff" (C#).


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

**`ts/engine/src/compiled_engine.ts` is the one compiled engine COMMITTED to
git** — Rust/C#/Go/Python/C++ rebuild theirs from source inside their own CI
jobs, so only this artifact can silently fall behind the Dart engine it was
generated from. The six conformance sweeps cannot see that drift on their own:
the corpus is generated from Dart by the Dart encoder, so it only ever emits the
Ball shapes that encoder produces, and a semantic change the corpus does not
happen to exercise leaves every sweep green while the TS engine disagrees with
the Dart reference engine (this is exactly how a stale `_isBareSelfConstruction`
guard shipped under #499 with all 18 checks green). Two gates close it:
`Ball Artifact Freshness`'s `Assert compiled TS engine is up to date` step
regenerates and diffs the artifact, and
`ts/engine/test/compiled_engine_parity.test.ts` locks the behaviour with
hand-built programs chosen to discriminate shapes the corpus never emits.
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
| **The one COMMITTED compiled engine cannot go stale (§5)** | `Ball Artifact Freshness`'s `Assert compiled TS engine is up to date` (regenerates `ts/engine/src/compiled_engine.ts` and diffs) + `ts/engine/test/compiled_engine_parity.test.ts` (behavioural half) | every PR (`Ball Artifact Freshness`, `TypeScript`) |
| **No false coverage (§4)** | `check_fixture_names.dart` | every PR |
| Engine/compiler behavior | `conformance_test.dart`, `conformance_compiler_inprocess_test.dart` | every PR |
| Real subprocess round-trip (engine, `dart run`, `node`, encoder-in-the-loop) | `conformance_roundtrip_test.dart` (`@Tags(['slow'])`) | `slow-conformance.yml`, weekly + manual only |
| C++ CI wall-clock budget (#521) | ci.yml's `cpp` job — step-level `timeout-minutes` on `Run tests` (20 Windows / 8 Linux+macOS, sized against the **cold**-ccache 13m57s / 5m19s / 4m57s and still under the pre-fix 28m33s / 12m12s / 9m56s) + a 25-min job budget | every cpp/infra-touching PR |
| C++ e2e fixture coverage is *visible*, not just asserted (#521) | ci.yml's `cpp` job — `test_e2e` writes `<build>/test/e2e_coverage.txt`, deleted before `ctest` and re-checked after (`expected == executed >= 1`); a passing CTest test prints nothing under `--output-on-failure` | every cpp PR, all 3 OS legs |
| **The C++ e2e fixture LIST cannot silently stop growing** (#63 / #511) | `cpp/test/check_e2e_fixture_list.sh` — every runnable fixture (a `.ball.json` with a sibling `.expected_output.txt`) must be in `cpp/test/e2e_fixture_list.h` or named in the frozen, ratchet-only `cpp/test/e2e_fixture_list_known_gaps.txt`; `--self-test` proves the guard bites | every PR (the always-on `proto` job, no toolchain) |
| The `full_e2e.sh` harness itself (worker dispatch, `xargs -P`, CWD isolation, corpus-ordered aggregation) (#521) | ci.yml's `cpp` job, Linux leg — changed-fixture gate when a PR touches fixtures, else a derived four-fixture harness smoke | every PR (otherwise only the post-merge `C++ Compiled` leg ran it) |
| Cross-engine parity (§5) | `conformance-matrix.yml` (Dart/TS/C++) | push to main + weekly |
| Encoder-reads-back-the-compiler measurement (Ball → `<lang>` → Ball → **Dart** engine → golden) | `conformance-matrix.yml`'s `csharp-roundtrip` / `python-roundtrip` / `go-roundtrip` / `rust-roundtrip` rows (#452) | push to main + weekly + dispatch — **NOT a PR gate** (no floor either: an honest 0/321 is the product) |
| Changed-stacks detection (decides which jobs above run at all) | `.github/actions/detect-changed-stacks` + its `test/truth_table.sh` | every PR (the truth table runs in the always-on `proto` job) |
| **The committed TS self-hosted engine is DERIVED, not trusted** (#517) | ci.yml's `typescript` job — regenerate `ts/engine/src/compiled_engine.ts` from `dart/self_host/engine.ball.json` through the current `@ball-lang/compiler`, then `git diff --exit-code`. It is the only committed compiled engine (Rust/Go/C#/Python gitignore theirs and regenerate unconditionally, so they cannot go stale); `npm run build`/`npm run coverage` consume it as an INPUT and stay green on any drift that is behaviour-neutral for the TS suite | every dart/ts/infra-touching PR (`TypeScript`) |
| **A network command survives a flaky index** (#520) | `.github/actions/dart-pub-get` (bounded retry, loud on exhaustion) + `test/test_dart_pub_get_wiring.sh` — asserts every `dart pub get` in ci.yml routes through it, with a positive invocation-site floor, and drives the retry against stub `dart` binaries | every PR (the wiring test runs in the always-on `proto` job) |
| **The conformance total quoted in the docs is the real one** (#519) | `tools/check_conformance_doc_counts.sh` — derives N from the fixtures that have a golden and fails on any `N passed, 0 failed, N total` in a tracked `.md`/`.yml` that disagrees (so "all the docs agree on the wrong number" still fails); `tools/test/test_check_conformance_doc_counts.sh` pins the guard itself | every PR (both run in the always-on `proto` job — deliberately NOT in `ball-freshness`, which a rust/AGENTS.md-only PR would skip) |
| **Third-party code (§2c)** — Tier A, Dart/Rust/C#/Go/Python | `coverage-study.yml`'s `dart-tier-a` / `rust-tier-a` / `csharp-tier-a` / `go-tier-a` / `python-tier-a` jobs | weekly + manual — **report-only, NOT a PR gate** (issue #493). The one failure mode is a run that scored < 1 file: a harness/checkout failure, never a 0% result |
| Each coverage-study harness's own correctness | `tools/coverage-study/test/rq1_study_self_test.dart` (Dart), `cargo test -p ball-rq1-study` (Rust), `csharp/coverage-study/test` (C#), `go test ./...` in `tools/coverage-study/go` (Go), `tools/coverage-study/test/rq1_study_py_self_test.py` (Python) | every PR (the matching language job) |
| Line coverage ratchet (Dart/TS/Rust/C#) | `coverage.yml` | push to main + manual — **NOT a PR gate** |
| Line coverage ratchet (C++) | `coverage.yml`'s `cpp` job | push to main + manual, **plus cpp-touching PRs** (#63) — reports, does not block (not a required check) |
| **The artifact an outside consumer gets, not the checkout** — Go modules (#361) | `tools/go-module-proxy/smoke.sh` (synthesized `file://` proxy; every module builds standalone with no `go.work`/siblings, then `go install .../go/cli/cmd/ball@vX.Y.Z` into a clean GOPATH and runs) | every PR (`Go`) |
| **The artifact an outside consumer gets, not the checkout** — Python wheel (#496) | `python/tool/wheel_smoke.py` (`python -m build python/`, install into a venv OUTSIDE the repo with no `PYTHONPATH`, run `--version`/`check`/`compile`/`encode`/`run`, `run` diffed against a golden as BYTES) | every PR (`Python`) |
| Compile-on-first-use engine bootstrap (what a pip-installed wheel actually runs) | `python/engine/tests/test_bootstrap.py` (cache hit/miss/invalidation, failure modes, and a conformance fixture through the cache-compiled engine vs. its golden) | every PR (`Python`, with `BALL_REQUIRE_SELFHOST_SOURCE=1` so it cannot silently skip) |
| vcpkg port recipe builds (#368) | ci.yml's `vcpkg` job — generated overlay of the real port, `vcpkg install ball-lang --triplet x64-linux`, installed binary runs | cpp/tools-touching PRs — new infrastructure, not a regression gate (the port had never been built once) |
| **The artifact an outside consumer gets, not the checkout** — vcpkg `ball`'s SELF-HOSTED verbs (#368/#361) | ci.yml's `vcpkg` job — pre-generate `dart/self_host/lib/{cli_rt.h,engine_rt.cpp}` with a real Dart toolchain, tar them as the release asset the portfile downloads, **delete them from the checkout**, then assert the vcpkg-INSTALLED `ball run` against the conformance golden and `ball info` against the Dart-native `cli_core` parity golden. `ball version` alone cannot see this: `BALL_CLI_VERSION` is compiled in unconditionally, so it passes identically in a fully-stubbed build | cpp/tools-touching PRs (`vcpkg port smoke (x64-linux)`) |
| The self-host sidecar's four-file wiring cannot drift (#368/#361) | `tools/vcpkg-port/test/test_selfhost_asset_wiring.sh` — pins the release-asset name against the portfile's `FILENAME`, that the overlay generator swaps **both** network fetches and emits a hermetic overlay (and fails loudly on an unswapped one), that the sidecar is an opt-out-able default feature, that the vcpkg job deletes its pre-generated copies before installing, and — since the port was first built against a real tag — that **neither `SHA512` is the `0` placeholder** and that every literal `vX.Y.Z` in `portfile.cmake` matches `vcpkg.json`'s `version-semver` (the version drives both download URLs, so bumping it without recomputing both hashes ships a port that fails for every consumer) | every PR (runs in the always-on `proto` job) |
| The port installs from a REAL release, not only from a generated overlay (#368) | Manual, recorded in `tools/vcpkg-port/README.md` — `vcpkg install ball-lang` / `ball-lang[core]` against the published `v1.64.0` tag and its `ball-selfhost-cpp-src` asset, then `ball version` / `run` (vs. the conformance golden) / `info` on the installed binary. The CI smoke deliberately replaces both network fetches, so it can never exercise the `REF`/`SHA512` pair or the asset URL | on each port version bump — the always-run test above is what keeps the *result* from silently regressing between bumps |
