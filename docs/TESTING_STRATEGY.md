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

> **Scanning the emit SITES is not the whole population (#488).** Until the
> #488 wrap-up the gate extracted emittable names with two regexes over string
> literals at the emit call sites — but `encoder.dart` routes a large family
> through dispatch TABLES (`collectionRoutes`, `unaryRoutes`, `getterRoutes`,
> `convertTopLevelRoutes`, `cascadeCollectionRoutes`) whose emit site is
> `..function = fnName`, with `fnName` destructured from the table's tuple
> VALUE. Every base function reachable only that way was exempt regardless of
> coverage: `std_collections.map_contains_value` sat in the generated
> `tests/conformance/std_coverage.json` with `coveredByFixtures: []` and
> `carvedOut: false` while this gate printed "No completeness gaps."
> `check_encoder_completeness.dart`'s `_routeTables` now parses those tables'
> value position, and **exits non-zero if a declared table is not found**, so a
> rename cannot silently shrink the population back. A new dispatch table must
> be added to `_routeTables`.

> **Completeness has a COMPILER end too (#488 → #654).** A base function the
> Dart compiler has no `case` for used to fall to a default arm that emitted a
> `/* unsupported: … */` COMMENT where an expression belongs — a build error in
> the compiled-back file, and nothing audited it.
> `dart/compiler/test/base_call_dispatch_completeness_test.dart` is the mirror,
> and since #654 its population is the DECLARED set with **no exclusion**: every
> base function the eight `dart/shared/lib/std*.dart` builders declare, built in
> process from the builders themselves, with a positive floor (>= 300) so a
> builder shape change cannot pass it vacuously. Each name is probed by
> COMPILING a call to it, not by matching switch-arm patterns in `compiler.dart`
> — which is what a source scan cannot do: `std_collections.set_create`'s name
> appears in the file (in the `std` switch, because the Dart encoder emits every
> std call under the module name `std`), so the earlier text-scanning gate read
> it as handled while the declared spelling reached the default arm. Every
> per-module default arm now FAILS LOUD (`_unimplementedBaseCall`), so an
> undeclared name is a compile error rather than broken output; the gate's
> second test asserts that for all eight modules.

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
> compiler`, which lives in `conformance-matrix.yml` — a PR gate since #619, but
> a ratchet (`CSHARP_COMPILER_FLOOR`) that already tolerates its known gaps. "A
> gate exists" and "a gate runs on your PR and would have gone red" are
> different claims, and a ratcheted gate can be green over a real regression it
> was already tolerating.

> **A change of WHICH member a receiver is asked for is behavioural, and only
> an executing leg can see it.** The corpus compares stdout, so for a
> `dart:core` receiver `x.isNotEmpty` and `!x.isEmpty` are indistinguishable —
> same value, every fixture green. For a DELEGATING receiver they are not: a
> wrapper, a mock, a proxy or a `noSuchMethod` forwarder sees the member name.
> That is issue #674, and nothing in the repository could have caught it: no
> fixture forwards a member through a recording receiver, Tier A is structural,
> and Tier B was masked by an unrelated build error on the one real-world file
> that exercises the shape (`collection/lib/src/wrappers.dart`). The gate added
> with the fix is `dart/encoder/test/is_not_empty_member_identity_test.dart`: a
> scratch package whose receiver RECORDS the members it is asked for, encoded
> through `PackageEncoder.prepareStaticTypes()` → `DartCompiler.compileModule()`
> and RUN through `dart run` both as written and as compiled back. When a
> rewrite is value-preserving but identity-changing, "assert the emitted call
> name" is the bug-locking test 2b warns about — execute a receiver that can
> tell the difference instead.

> **A test that pins a REFUSAL is a contract about the encoder, not about the
> program.** `extension_override_test.dart` asserted that a cross-library
> extension override warns and falls to the `/* unsupported: … */` placeholder.
> That test was green, and stayed green, while the shape real code actually
> writes — an extension declared in another file of the same package — could not
> be encoded at all (#670). A refusal assertion says "the encoder declines
> loudly"; it says nothing about whether declining was necessary, so it cannot
> notice when the decline becomes avoidable. Pair every refusal with a probe
> that RUNS the construct three ways — natively, on the engine, and compiled
> back — so the suite states what the program DOES, and the refusal is left
> covering only the cases where those three cannot be made to agree.

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
> and 406 is back, unchanged. `CPP_COMPILE_CARVEOUTS` was empty at that point,
> and it is empty again today (see the #695 note below for the one entry that
> lived there in between).

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
> The four `43x` constructor fixtures added for #499 were the same case: they
> are the only cross-target lock on "a constructor that builds another
> instance of its own class must not silently get `self` back", and they pass
> on every ENGINE — the Dart reference one plus all six self-hosted ones, the
> C++ included. **That** is the coverage that survived carving them out of the
> Ball -> C++ *compiled* leg. The two Ball -> C++ gaps they exposed were filed
> as [#513](https://github.com/Ball-Lang/ball/issues/513) (a read through a
> nullable self-referential field emits a concrete-struct member access on
> `BallDyn`) and [#514](https://github.com/Ball-Lang/ball/issues/514) (a class
> whose only constructor is zero-argument gets a duplicate default one). Both
> are g++ build failures, not Ball -> C++ compile failures. BOTH are now FIXED:
> `435_recursive_ctor_construction` / `436_recursive_ctor_named` /
> `437_recursive_ctor_tree` were de-carved with #513, and
> `438_ctor_initializer_list_with_body` with #514. All four are listed in
> `cpp/test/e2e_fixture_list.h` and run on the compiled leg, and
> `CPP_COMPILE_CARVEOUTS` was EMPTY again at that point (see the #695 note
> below for the one entry that lived there in between).
>
> **A carve-out is the honest disposition when the gap is the TARGET, not the
> fixture — and it is a RATCHET, so it comes back out the moment the target
> catches up.** #651's fixture — `472_initializer_list_field_with_setter`, a
> class declaring a `final` field and its OWN setter of the same name — is the
> counter-case to 406 above. 406 was WITHDRAWN because a different fixture could
> pin the same Dart-side point; 472 cannot be reshaped, because that exact
> declaration pair IS #651's mechanism (a spurious `late final` hands the field
> an implicit setter that collides with the declared one). It runs correctly on
> every engine — Dart, TS, Rust, C#, Go, Python and the C++ self-host engine —
> and it failed only the Ball → C++ **compiled** leg, because C++ has ONE member
> namespace and the emitted data member and setter collided. That was a C++ target
> gap, filed as [#695](https://github.com/Ball-Lang/ball/issues/695) and parked in
> `CPP_COMPILE_CARVEOUTS` plus `cpp/test/e2e_fixture_list_known_gaps.txt` — loud,
> tracked, one entry, and never `continue-on-error`.
>
> **Both entries are gone again**: `main` landed
> [#680](https://github.com/Ball-Lang/ball/pull/680) while this branch was open,
> and its C++ half is exactly the lowering #695 asked for —
> `class_setter_backed_fields_` in `cpp/compiler`, which gives a field declared
> beside its own same-named setter the #501 backing-member treatment and
> synthesizes only the GETTER half, leaving the write side to the declared setter.
> 472 is now listed in `cpp/test/e2e_fixture_list.h` next to
> `470_setter_beside_final_field` (#680's own fixture for the identical
> declaration pair), and `CPP_COMPILE_CARVEOUTS` is empty. **Re-check a carve-out
> against `main` on every merge**: a carve-out that outlives its gap is a silent
> coverage hole, and nothing in CI can tell the two apart — the leg is green
> either way.
>
> C++ is no longer among the failing targets, but it was only the loudest, never
> the only one:
> [#706](https://github.com/Ball-Lang/ball/issues/706) carries the same fixture on
> the Rust, Go, Python and C# COMPILER legs, where Rust and Go build and run it
> and then read the field back as `null`. Those legs are RATCHETED, so they are
> green with it failing and will stay green when it is fixed — which is exactly
> why the per-fixture line, not the leg's colour, is the thing to read.
>
> Adding it also surfaced a hole in the per-PR leg itself. `full_e2e.sh` carries
> a positive floor — `passed == 0 && failed == 0` is a leg that proved nothing,
> so it exits 1 — and that floor is PER-INVOCATION. ci.yml used to hand it only
> the PR's changed fixtures, so a PR whose every changed fixture is carved out
> selected one fixture, skipped it, ran nothing, and went red naming the wrong
> cause: the gate as written forbade ever ADDING a carved-out fixture, which
> contradicts the paragraph above. The fix is the one the floor's own error
> message prescribes — WIDEN THE FILTER: the changed fixtures and the derived
> four-fixture harness slice now share a single `full_e2e.sh` call, so the floor
> always measures real compiles while the carve-out stays loudly reported. Never
> answer that red by deleting the floor, the carve-out, or the fixture.
>
> **Name the leg that actually covers it — measure, do not assume.** An earlier
> draft of the paragraph above also claimed those four fixtures "pass on the
> Rust/Go/Python/C# compiler legs". Measured one fixture at a time, they do not:
> `435_recursive_ctor_construction` and `437_recursive_ctor_tree` (unnamed
> constructors) passed all four, while `436_recursive_ctor_named` and
> `438_ctor_initializer_list_with_body` failed **all four** — Rust
> `[E0425] cannot find value 'Countdown'`, C# `CS0103: The name 'from' does not
> exist in the current context`, a Go `build` error, Python
> `unresolved reference 'Countdown'`. None of those four compilers resolved a
> NAMED constructor (`Class.name(args)`), which the Dart encoder emits as a
> method call on the class reference rather than as a `messageCreation`, and
> none applied a constructor's `metadata.initializers` when the constructor also
> carried a body. Both were fixed in
> [#527](https://github.com/Ball-Lang/ball/issues/527), whose regression cover is
> deliberately a **PR-gated unit test per language** (`cargo test --workspace`,
> `dotnet test Ball.slnx`, `go test ./compiler/...`, `pytest`) rather than the
> fixtures alone — because the fixture leg still does not run on PRs. CI stayed
> green throughout because
> those legs are **ratcheted** — they fail only on a DROP below a recorded floor
> (73-89 pre-existing failures each), and are explicitly not parity gates. A
> ratcheted leg going green tells you nothing about a specific fixture: run it.
>
> **A new base function can be right everywhere and still not agree everywhere.**
> `434_type_of` (#489's fixture) printed `Set` on line 8 — the real `dart run`
> oracle — on every engine, on the C++ compiled leg, and on the Go and Python
> compiler legs, and `List` on the Rust and C# ones. That was not a `type_of`
> defect: neither runtime had a set representation at all
> (`rust/shared`'s `ball_set_create` returned a `BallValue::List`,
> `csharp/shared`'s `SetCreate` returned a `BallList`), so a compiled set *was* a
> list there, while both runtimes' `Set` arm keyed on the portable
> `{'__ball_set__': [...]}` map form only the self-hosted engines materialise.
> `x is Set` had been answering wrongly in those two targets for as long as it
> had existed, unnoticed, because nothing ever asked — 434 was the first test
> that did. Fixed in
> [#528](https://github.com/Ball-Lang/ball/issues/528) by giving both runtimes
> the same portable tagged-map set C++ already shipped; the fixture keeps its
> `Set` line, because deleting it would have deleted the only place the
> divergence was visible. **The lasting lesson is the shape, not the bug:** a
> divergence that only a not-PR-gated, ratcheted leg can see needs PR-gated unit
> tests to close it for good, which is why #528's fix landed with
> `ball_is_type`/`ball_type_of`/alias-mutation/rendering assertions in
> `cargo test --workspace` and `dotnet test Ball.slnx` — legs that DO run on
> every PR.
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
honest limits are in `tests/conformance/COVERAGE_STUDY.md`. It is **not a PR
gate** — `coverage-study.yml` has no `pull_request:` trigger, because these
harnesses clone and build third-party packages — but it is no longer merely
report-only: its `publish` job floors every row against
`tools/coverage-study/baseline.json` and fails the run on a drop. The floors are
**ratchets at the measured numbers** (fail on a drop in the clean ratio, in ANY
funnel stage's ratio, or in the scored denominator; raise the baseline on an
improvement), not the >= 95% / >= 75% issue #493 first proposed — Dart Tier A
measures 61% and four of six Tier A rows measure 0% clean, so an aspirational
floor would be permanently red and therefore muted. The same job publishes the
table in `README.md`. Each harness's **own** self-test, and the renderer/floor's,
are gated on every PR (in that language's `ci.yml` job), so the instrument cannot
silently start skipping the file shapes it exists to look at, nor stop flooring
what it measures.

The instrument has two tiers, and one cannot stand in for the other. **Tier A**
is structural (encode → compile back → re-encode → declaration inventory → IR
fixpoint) and exists for all six languages; by design it scores a construct
`clean` when it round-trips syntactically but changes what the program computes.
**Tier B** (Dart today) is behavioural: it substitutes a library file with the
pipeline's own compiled-back version and runs *that package's own* `dart test`.
The gap between them is not hypothetical — #488's `return set.add(x)` lowers to
the cascade `return set..add(x)`, which parses, keeps every declaration and
reaches the fixpoint, so Tier A scored it clean across two full baselines while
the issue sat open.

**Tier A scores LIBRARY code only** (the owner's 2026-09-14 methodology decision
on issue #491). A package's own test suite is a different population — written
against that package's private internals, compiled under different settings, and
encoded by nobody — so each harness excludes it by that language's own
convention. The rule is never a silent filter: every harness prints
`excluded (test-only): N` (always, zero included) and writes the count plus the
per-file rule into its JSON report; `summarize.sh` FAILS a Tier A job whose log
does not carry that line or whose count is not a bare integer; `coverage_table.py`
fails on a Tier A artifact with no count, publishes it as a README column, and
records it in `baseline.json` (recorded, **not** floored — a pin whose own test
suite grew moves it in either direction and neither is a regression). The count
alone cannot see a PARTIAL readmission, so the harnesses also write the paths
and `tools/coverage-study/excluded.json` commits them per pin: a path that list
excludes and a run SCORED is a breach naming the file (#676). Each
language's self-test pins both directions, including a negative control of
library files named `latest`/`contest`/`attestation` that must stay **scored**,
so a substring rule fails. The per-language rules and the one known limitation
are in `tests/conformance/COVERAGE_STUDY.md`.

The **other** half of the denominator's provenance is the "nothing to measure"
skip, and it has to be decided from the file's SOURCE before the pipeline runs
(#721). Deciding it afterwards — as every harness did, and as Dart/TypeScript/
Rust still do (#811) — makes `scored` a function of the encoder: a
declaration-less file is scored only while it happens to FAIL somewhere, and
leaves the corpus the moment an encoder change lets it through. #646 improved
`python/encoder`, three ZERO-BYTE `pyparsing/**/__init__.py` markers stopped
failing at stage 3, and the Python row's `scored` fell 73 → 70 with not one
file changed; every published ratio moved and the breach message could only
guess at a clone failure. `rq1_study_py.py::has_scorable_material` is the
reference implementation: a file leaves the denominator only when it has
neither a top-level declaration nor any executable top-level statement, a file
that HAS declarations and comes back with none is a scored failure rather than
a skip, and the count is printed on every run, zero included.

Tier A now exists for **all six** languages: Dart (`rq1_study.dart`), Rust
(`rust/tools/rq1-study`), C# (`csharp/coverage-study`), Go
(`tools/coverage-study/go`), Python (`rq1_study_py.py`) and TypeScript
(`rq1_study_ts.mts`). TypeScript was last because it was genuinely blocked:
`ts/compiler`'s `compileModule` takes a single Module *facade* built for the
`ball_protobuf` inline-embedding case, and `compile` appends a zero-arg `main();`
to any declaration sharing the encoder's default entry name, so the port needed a
genuinely new library-mode primitive first (`compileLibrary`, issue #536).

Each port also prints a per-stage **funnel** beside the clean percentage,
because for four of the five ports the clean number is 0% and the information is
entirely in *where* files stop: the Rust/C#/Go/Python compilers emit
runtime-call-shaped source their syntactic encoders were never built to read
back, so stage 3 (re-encode) is a wall — the same wall the `*-roundtrip` rows
report on the project's own corpus. Those rows read a flat `0 passed` for as long
as they existed and went green every time, because nothing floored the count
(#642); each one now carries a measured floor and a ratchet (see the table
below), and the remaining gap is named per target with the issue tracking it
(#689 C#, #690 Python, #691 Go, #692 Rust). A bare 0% would
hide the difference between "the encoder rejected the file outright" (Rust, Go:
0 files even encode) and "58 of 472 files got all the way to the declaration
diff" (C#). TypeScript is the one port with a non-zero first number (4/48), and
its failures are spread across every stage rather than piled on one.


### 2c. A measurement leg is floored the moment it measures anything (#642)

The four `*-roundtrip` rows (`conformance-matrix.yml`: Ball fixture →
`<lang>` compiler → that language's own encoder → the **Dart** reference engine →
golden diff) are the repo's hardest legs by construction, and for as long as they
existed every one of them printed

```
Results: 0 passed, 349 failed, 349 total (4 skipped carve-outs)
```

and reported the row healthy. The only assertion was `total >= 1` — the harness
ran — so an honest "it has always been 0" was indistinguishable from a future
regression, and the rows could not have noticed one.

The rule this repo now follows on any measurement leg:

1. **No positive floor while the leg genuinely passes nothing.** Adding
   `passed >= 1` to a row measuring 0 makes it permanently red for a pre-existing
   gap, and invites the one thing a floor must never buy — a special-cased
   fixture or a weakened fail-loud check, just to clear it. The floor lands in
   the SAME PR as the first passing fixture, never before.
2. **A row at zero must not report "OK".** Until the floor can land, the row
   prints the first failing fixture's error VERBATIM and names its gap with an
   issue number in the step summary. "Expected baseline" is not a status.
3. **Once it measures something, the floor is set AT the measured count** — the
   number that row's own CI job printed, never a prediction, never an
   aspiration — and only ever rises, in the same PR as the fix that earned it.
   `tools/ci/roundtrip_floor.sh` prints the exact new value on an improvement.
4. **The gate is a script, and the script has its own test.** Inline workflow
   bash cannot be unit-tested, and a `[ "$passed" -lt "$floor" ]` with an empty
   or multiline operand exits 2 — which, inside an `if`, SKIPS the branch and
   falls through to a green exit. `tools/test/test_roundtrip_floor.sh` runs on
   every PR and pins all of it, the wiring included.

Measured on PR #646's own matrix (run 34784068344), after teaching each encoder
its own compiler's dispatch shape and fixing the Rust `&mut` alias that made 28
loop fixtures re-encode clean and then hang (#693): Rust **99**, C# **76**,
Python **41**, Go **31** of 352. Those were the floors; Go's moved to **79** on
PR #738's matrix (run 35549906393 — `Results: 79 passed, 281 failed, 360
total`), when `go/encoder` gained the
`std_collections` inverses and the four shapes `go/compiler` emits for every
program (#691). Those are the floors. None of the four is a parity gate — most of
the corpus still does not round-trip anywhere — but a flat zero is red, and a
drop is red.

5. **A fixture that HANGS is its own hard error, never one more `failed` (#693).**
   A count cannot tell a golden mismatch from a program that does not terminate,
   and the ratchet can only notice the latter once enough fixtures hang to push
   `passed` under the floor — which is exactly how 28 loop fixtures hung for as
   long as they did. `roundtrip_floor.sh` reds a row on any per-fixture timeout
   line, anchored on the STATUS field so a fixture merely NAMED `196_timeout` is
   not a hang, and overridable per row (C#'s harness prints `  <name>: TIMEOUT`
   rather than the `FAILING [name] timeout …` the other three share). All four
   rows measured **zero** timeouts before the gate was switched on (run
   34791323674, main) — a gate goes live at a measured value, never at an
   aspiration.
6. **A harness that can hang forever is itself a defect, and its budget is
   self-tested.** Every one of these legs shells out to the Dart CLI per fixture,
   so each needs a per-fixture kill or one runaway wedges the whole job. Having
   one is not the same as knowing it works: Rust's was a hard-coded `const`
   inside an `#[ignore]`d test, reachable from nothing and therefore measured by
   nothing. It reads `BALL_TIMEOUT_MS` now (the spelling Go's leg already used;
   Python's is `BALL_TIMEOUT_S`), fails loud on a non-integer value, and
   `a_runaway_fixture_is_killed_at_the_budget_and_reported_as_a_timeout` proves
   the kill against a **fabricated runaway** — a program built with `rustc` at
   test time that ignores its arguments and never exits — driven through the real
   production path, on every PR.

   **Killing the process is not the same as ending the fixture (#691).** Every
   one of these legs sets `cmd.Stdout` to an in-memory writer, so the runtime
   pipes the child and copies in a goroutine — and the wait does not return until
   that copy ends, which needs EVERY holder of the pipe's write end closed, the
   killed process's own descendants included. Go's round-trip leg killed its
   `dart` and then blocked forever on `cmd.Wait()`, so the sweep printed no
   `Results:` line at all and the row would have died on the job's
   `timeout-minutes` — reporting nothing, rather than reporting a timeout. The
   bound is `cmd.WaitDelay` (`go/engine/conformance/roundtrip.go`), and
   `roundtrip_timeout_test.go` is its negative control: a stand-in `dart` that
   hands its stdout to a grandchild and blocks, measured at 5.6 s with the bound
   and 30.1 s without. It stayed latent because only 31 fixtures ever reached the
   engine; it surfaced the moment #691 raised that to 80.

Python's floor is **63** since PR #733 (run 34800144249, the PR's own row), which
mapped every `ballrt.*` helper with an exact universal-`std` inverse — the
`math_*` family the issue named, the unary string family, field access, index
assignment and the type tests. The lesson that generalises: the row's failure
text was the ONLY witness to that inventory, so the fix ships with a closed-set
drift guard derived from the two sources of truth (`dart/shared/std.json` ×
`python/runtime`'s public helpers), not a list kept beside the table — a measured
floor locks in a gain, but only a derived closed set stops the gap reopening one
helper at a time.

**A closed set over NAMES cannot see a mismatched FIELD name (#771).** The
`std` inventory ladder — #505 (`routed ⊆ declared`), #686 (`declared ⊆ keyed`),
#702 (`dispatched ∪ keyed ∪ executed ⊆ declared`) — and the C#/Rust mirrors that
re-derive from `dart/shared/std.json` all compare a function NAME, and at most an
`outputType`. Not one of them opens a `TypeDefinition`'s `field[]`. A declaration
that spells a field `len` where the handler reads `length` therefore passes the
entire suite while computing the wrong answer on every target, because engines
and compilers extract fields by hardcoded string key and never consult the
descriptor at all: no crash, no diagnostic, no gate — the #55 silent-degradation
shape, one level down. `dart/shared/test/std_field_signature_test.dart` is the
next rung, and it checks BOTH directions (every declared field is read; every key
read is declared, documented as an alias, or part of the universal call
convention). Two properties make it a gate rather than a second copy of the
inventory: the read set is PARSED out of `dart/engine/lib/engine_*.dart` and
`dart/compiler/lib/compiler.dart` — a hand-maintained per-function expectation
table would only prove that two copies of one list agree — and every parse in it
carries a positive floor plus a negative control, so an extraction that silently
stops matching fails instead of passing vacuously. Its first run found three
declared fields no target reads anywhere (`ListReduceInput.initial`, and
`FormatTimestampInput`/`ParseTimestampInput`'s `format`, whose descriptions
promised a custom format string that no engine, compiler or runtime in the
repository has ever implemented) and nineteen alias spellings the Dart engine
accepts that `std.json` never mentioned, so no other target could implement them
and no encoder knew they were safe to emit.

### 3. Fail loud, never degrade silently
A construct the engine/encoder/compiler does not handle must **throw**, not
return `null`/`[]`/a placeholder string. Silent degradation is the amplifier
that turns a missing feature into silent wrong output. Concrete guards now in
place: `collection_for`/`collection_if` throw if dispatched outside a literal
(`engine_std.dart`); the encoder throws on an unknown collection element instead
of emitting `/* unsupported */`.

**A coverage test can PIN the silent degradation it was written to reach
(#742).** `engine_control_flow.dart`'s `_evalAssign`/`_evalNullAwareAssign`
ended in a bare `return val;` for every `std.assign` target shape they could
not write through, so a dropped write was indistinguishable from a successful
one on all seven engines (this is engine source: the self-hosted engines are
this same code compiled). It survived because the corpus cannot see it — no
encoder emits such a target, so §2's completeness gate is structurally blind
here and only a unit test can reach the arm. One existed, and it made the bug
load-bearing: `engine_wave5_control_flow_coverage_test.dart` asserted that
`'abc'[0] ??= 'x'` evaluates to `'x'`, i.e. it asserted the no-op, and the line
was covered. The rule: a test written to REACH an unhandled-shape arm must
assert the arm FAILS LOUD, never assert whatever the arm happens to return
today — otherwise the coverage number and the test suite both certify the
degradation. Where the unhandled set comes from a proto oneof, derive it: the
#742 guard enumerates `Expression_Expr.values` and requires every non-accepted
case to have a rejected-target fixture, so a new Expression case fails the
suite until someone classifies it.

### 3a. A leg's verdict must consume the checker's EXIT STATUS, not only its stdout
Gate-authoring rule, for every shell guard under `tools/` and `cpp/test/`.

A checker that reports "clean" by **printing nothing** and a checker that
**could not run at all** produce the same stdout. So a leg shaped like

```bash
probs=()
while IFS= read -r line; do probs+=("$line"); done < <(check "$file")   # WRONG
if [ "${#probs[@]}" -eq 0 ]; then ok "…"; fi
```

reports PASS — and counts +1 toward its own positive floor — when `python3` is
absent, an import fails, or the checker dies on a traceback (stderr, not
stdout). That is issue #694, reproduced in PR #662's round-1 review by taking
`python3` off PATH: the leg printed `PASS` and the sweep reported its usual
tally, from a check that never happened — while the sibling `--self-test` step,
which does let the status through, correctly went exit 127. Reachability is not
the bar; a gate that can be silently disabled is already broken.

One of these three shapes, always:

1. **The checker's status is the step's status** — make the call the script's
   last command: `check_file "$WORKFLOW"; exit $?`
   (`tools/ci/check_matrix_paths.sh`, `tools/ci/check_ci_regen_wiring.sh`, and
   the trailing `python3 - … <<'PY'` heredoc in
   `tools/ci/check_required_contexts.sh`).
2. **Capture both and classify the status** —
   `out="$(check "$f")"; rc=$?`, then treat every status the checker does not
   define (anything but its clean/found-problems pair) as a **failure that names
   the status**. `freshness_paths_findings` in
   `tools/release/check_go_release_wiring.sh` is the worked example; so is
   `cpp/test/check_compiler_cache_applied.sh`'s `|| requests=""` + `is_uint`.
3. **Make empty output fail closed, and say why it is closed** — a positive
   floor (`[ "$checked" -lt 1 ] && exit 1`), an explicit `[ -n "$x" ]` arm, or a
   comparison against a non-empty expected value, so "nothing came back" cannot
   reach the `ok` branch. Never `|| true` on the line the verdict reads.

And the negative control belongs to the **leg**, not just the checker: cases
that only assert what the checker answers about fabricated inputs cannot see a
checker that answers nothing. Shadow the dependency (a PATH stub that exits 127)
and assert the leg reports FAIL, paired with a positive control on the real tree
so the negative case cannot pass for an unrelated reason.

**This rule is enforced, not merely written down** (issue #705).
`tools/check_verdict_exit_status.py` — the always-on `proto` job, self-test
first — rejects every `done < <(…)` under `tools/**/*.sh` and `cpp/test/*.sh`
unless `tools/verdict_loop_carveouts.tsv` names that exact loop *and states the
reason it is safe*. Anchors are matched against the loop's PRODUCER (the text
inside `<( … )`, however many lines its parentheses span), so an entry stays
attached to the loop it justifies when the file moves around it and a rewritten
producer must be re-justified; an entry matching zero loops is stale and an
error, one matching two is ambiguous and an error, an empty reason is an error,
and inspecting zero loops at all is an error.

It is a carve-out list rather than an analysis on purpose. Deciding from bash
source whether a given loop "feeds a verdict" is dataflow analysis, and a wrong
answer in the permissive direction is precisely the silent hole this section
exists to close. Shape 2 above is unavailable to a process substitution by
construction (`$?` after `done < <(cmd)` is the loop's status, never `cmd`'s),
so what remains is a judgement about the surrounding code — a positive floor, a
pure in-memory transformation — and a judgement belongs in a reviewed, named
list. A loop that genuinely needs a checker's status is restructured, never
carved out.

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
guard shipped under #499 with every required check green). Two gates close it:
`Ball Artifact Freshness`'s `Assert compiled TS engine is up to date` step
regenerates and diffs the artifact, and
`ts/engine/test/compiled_engine_parity.test.ts` locks the behaviour with
hand-built programs chosen to discriminate shapes the corpus never emits.
**Compilers are separate** — the Dart, TS, and C++ Ball→source compilers each
need their own fix and their own verification (the `cpp-compiled` conformance
leg compiles every fixture through the C++ compiler).

### 5b. A base function's RETURN SHAPE — including what it does when there is NOTHING to return — is part of the contract, and is checked
Executing a base function is not enough — a fixture that only calls
`set_add(s, x)` for its side effect never notices that the Dart engine returned
the new SET, the Dart and C++ compilers returned the set, and the TS engine
returned an unconditional `true`. Three of six cells disagreed for as long as
nobody put the result in a **value position** (issue #545). Nothing could see
it: `outputType` was `''` on every universal std declaration, so the contract
was not merely unchecked, it was unstated.

Two gates now cover this class:

* **Cross-target** — `tests/conformance/459_set_add_remove_bool` prints the
  result of all four return-value branches (fresh insert / duplicate insert /
  present removal / absent removal). Because it is a conformance fixture it gates
  every engine and every compiled leg in the matrix at once. It uses a FRESH set
  per case, so it pins the RETURN VALUE only.
* **Cross-target, in place** — `tests/conformance/462_set_mutation_in_place` is
  the other half, added with the fix for issue #557: one set, added to, removed
  from, then READ BACK (printed whole, measured, and probed with `set_contains`
  for both the added and the removed element). It is what catches a mutation that
  is silently lost — the C#, Rust and C++ self-hosted engines all printed
  `{1, 2}` for the whole set while every bool AND `set_length` still looked right,
  because their compiled `_ballSetItems` handed back a COPY of the backing list.
  Only reading the same set back after a mutation can see that, which is exactly
  why 459's fresh-set-per-case form could not. Do not rewrite it to use a fresh
  set.
* **Declaration** — `dart/engine/test/std_output_type_contract_test.dart` reads
  the canonical builders, and for every base function that declares a non-empty
  `outputType` it runs the Dart reference engine and asserts the answer's
  runtime type. A declaration with no probe FAILS (a frozen, both-ways-checked
  carve-out list holds the pre-existing host-facing `std_time`/`std_fs`/
  `std_convert`/`std_concurrency` declarations, and no universal
  `std`/`std_collections` declaration may join it), so `outputType` can never be
  decoration again.

Fixture 459 also exposed a pre-existing gap the corpus had never reached: the
**`dart-roundtrip`** leg (Ball → Dart → *encoder* → Ball' → Dart) cannot survive
it. Re-encoding the compiled `a.add(3)` needs the receiver's TYPE to tell
`Set.add` (bool) from `List.add` (void), and the syntax-only `encode(String)` API
has none, so the call routes to `list_push` and compiles back to the cascade
`a..add(3)` — the SET, not the bool. That is issue #488's receiver-type seam, not
a #545 regression: the fixture's `engine`, `dart-compiled` and `ts-compiled` legs
all pass. Fixture 462 hits the same seam on the same leg for the same reason
(its first line is a `set_add` result in a value position). The two are the only
entries in the harness's `_knownUnroundtrippable` map — a ratchet, not a
baseline: an entry that starts passing fails the suite, an entry naming no real
`fixture:leg` fails the suite, and every unlisted failure fails the suite exactly
as before. Issue #488 owns the seam; both entries go together when it lands.

#### The NO-MATCH half: a function that can fail to produce a value (#597)

`outputType` says what a base function returns **on a hit**. It says nothing
about the other branch, and neither does any gate built on it — the #545
declaration probe calls each function with inputs that SUCCEED, by construction.
So a higher-order lookup that can find nothing (`list_find`, and by the same
reasoning `list_reduce` on an empty list) had a completely unstated contract for
its failing branch, and six targets drifted apart on it while the corpus stayed
green:

| target | `list_find` with no match, before #597 |
|---|---|
| Dart reference engine | `throw StateError('No element')` ← canonical |
| TS self-hosted engine | `null` — a hand-written `engine_setup.ts` override SHADOWED the compiled engine's own (correct) handler |
| TS compiler | `undefined` — a bare `Array.prototype.find` |
| C++ compiler | a default-constructed (null) `BallDyn` |
| C# compiler | no case at all → a RUN-TIME `BallRuntimeException` the program's own `try` could not even catch |
| Dart / Go / Python compilers | refused to compile (fail-loud, safe — but the target could not run a program every engine ran) |

The canonical answer is the reference engine's, and the declaration already said
so in prose: `dart/shared/lib/std_collections.dart` documents `list_find` as
"Find first: list.firstWhere(callback)", and Dart's `firstWhere` **without**
`orElse` throws by definition.

**Why no existing gate could see it.** `check_encoder_completeness.dart` forces
every base function the DART encoder can emit into an executed fixture — and the
Dart encoder routes no Dart syntax to `list_find` at all (zero hits in
`dart/encoder/lib/`; `.firstWhere(...)` falls through to the generic method-call
encoder). A function no source-level encoder can emit is invisible to that gate
by construction, and `generate_conformance.dart` cannot reach it from any
`tests/conformance/src/*.dart` either. The #545 declaration probe checks the
return TYPE on a hit. Nothing was positioned to ask what happens on a miss.

So, as a named gap class: **a base function that can fail to find/reduce a value
must have its FAILING branch exercised by an explicit conformance fixture**, and
that fixture has to be hand-authored through
`dart/encoder/tool/gen_std_gap_fixtures.dart` whenever no encoder can emit the
call. `tests/conformance/463_list_find_no_match` is the worked example: a hit
(the element), a miss on a non-empty list, and a miss on an empty one, each
caught by the program's own `on StateError catch`.

One portability constraint that fixture had to respect — and that **no longer
applies** (#615): every `try` in it carries exactly one catch clause, because the
Go, C# and Rust compilers all dispatched only the first catch clause with no type
matching, so a multi-clause `try` whose first arm named a non-matching type would
have failed those compile legs for a reason unrelated to the function under test.
All three now walk `catches[]` in **source order**, run an `on <Type> catch`
clause only when the thrown value's type tag matches, fall back to the first
untyped `catch (e)`, and re-raise when every typed clause misses — the reference
engine's `_evalLazyTry` contract. A new fixture may use as many clauses as it
needs; `tests/conformance/464_typed_catch_clause_dispatch` is the cross-target
guard for that, and each compiler carries its own **per-shape** unit test
(`go/compiler/catch_clause_dispatch_test.go`,
`csharp/compiler/test/CatchClauseDispatchTests.cs`,
`rust/compiler/tests/catch_clause_dispatch.rs`,
`python/compiler/tests/test_catch_clause_dispatch.py`) — see the gate lesson
below for why the corpus leg alone is not enough.

`python/compiler` carried the identical defect for another wave (#724): it was
not in #615's scope, and the reason nothing since then noticed is worth naming
as its own gap class. **A target whose only corpus row is its SELF-HOSTED engine
has no coverage of its compiler's user-program lowerings.** The `python-engine`
row compiles the Dart engine and runs the corpus *through* it, so every fixture's
`try` is interpreted by `_evalLazyTry` — Ball code — and the compiler's own `try`
lowering is exercised only by whatever shapes the engine SOURCE happens to
contain. The engine has no typed `on T catch` anywhere, so a lowering that
ignored `type` entirely ran the whole corpus green. The closing move is the same
one `go/compiler/user_thrown_builtin_error_test.go` makes: a leg that COMPILES a
conformance fixture through the compiler under test and diffs its golden —
`python/compiler/tests/test_conformance.py`'s `PROVEN` list, which #724 extended
with `464_typed_catch_clause_dispatch` and `473_caught_user_thrown_builtin_error`. That the throw is genuinely TYPED —
reachable by `on StateError`, not only by an untyped catch-all, which is what
Rust's bare `panic!` gave before #597 — is pinned per runtime too, next to each
target's implementation.

**The gate lesson #615 adds: a RATCHETED gate is green over the regression it
already tolerates.** The corpus fixture that would have gone red
(`146_nested_try_catch_types`) already existed and was never carved out, yet it
had been failing the Go/C#/Rust compiler rows since those pipelines came online.
Two compounding reasons, and #619 only fixed the first:

1. Until #619 those rows ran on push-to-main, the weekly cron and manual dispatch
   only. A post-merge red on a non-blocking workflow stops and reopens nothing,
   and a lane that never dispatched saw **no row at all**, which reads as green.
   `conformance-matrix.yml` is a PR gate now, so that half is closed.
2. **They are ratchets, not parity gates** — `*_COMPILER_FLOOR` fails only on a
   *drop* in a passing count. 146's failure sat inside each floor from day one. A
   count cannot name the fixture that is failing, so the row stayed green over a
   real, permanent defect and would have stayed green even as a PR gate.

So "a gate exists" and "a gate would have gone red on this" remain different
claims even now. When a compiler documents a lowering gap in a doc comment — which
is how #615 was found, off prose, not off any CI signal — that gap needs a test
that fails *for that shape*, not a leg whose floor already absorbs it.

#### "Observed" means the VALUE, not the fact that something threw (#616)

463 above is the worked example of the no-match half, and it was still only
three-quarters of a contract. Its two `on StateError catch` bodies print a
HARDCODED literal (`"caught StateError: no match"`), so it pins that a throw
happened and that a typed clause matched it — and pins nothing at all about what
the catch variable READS. Every target answered that question differently, and
the corpus stayed green. Measured on `origin/main` before #616, one program,
`print(to_string(e))` in the catch body:

| target | `to_string(e)` for a caught `list_find` StateError, before #616 |
|---|---|
| Dart reference engine | `Bad state: No element` ← canonical (and real Dart's `StateError('No element').toString()`) |
| TS self-hosted engine | `{message: No element}` |
| Go self-hosted engine | `main:StateError` |
| Go / C# / Rust compilers | the bare type tag, or the map form — never Dart's string |

The ROOT CAUSE is structural, not a typo in three literals. `_evalLazyTry` binds
`e is BallException ? e.value : e.toString()`, and the reference engine raised a
HOST `StateError`, so the catch variable collapsed to that string. Every
self-hosted engine is that same source compiled through the Ball pipeline, where
`StateError('No element')` is a construction of a class the program never
declares — so its catch variable bound a target-shaped object instead, and each
target's `to_string` rendered it its own way. The fix makes the engine throw a
`BallException` whose value IS the canonical string, so the same portable value
travels every target; each compiled runtime then renders its own typed error
payload with Dart's `toString()` spelling (`Bad state: <message>`).

`tests/conformance/465_state_error_message` is the guard, and the rule it states
generalises past StateError: **a fixture that catches must print the caught
VALUE.** A hardcoded string in a catch body proves only that control reached it.
The same fixture also covers `list_first` on an empty list, where the bug was
worse than a message drift — Rust, Go, C# and Python all raised an UNTYPED fault
there (a bare `panic!`, a `Thrown{Value: string}`, a native
`BallRuntimeException`, Python's own `IndexError`), so `on StateError catch`
never ran at all, and the TS engine's `engine_setup.ts` override returned `null`:
the exact shadowing defect #597 had already removed one line above it, for
`list_find`.

When a base function's result is meaningful — a predicate, a "was it there"
answer, anything a caller would branch on — declare the `outputType`, add the
probe, and write the fixture so the value is PRINTED, not discarded. When it can
FAIL to produce a result, write the fixture so the failure is OBSERVED, not
assumed — and observed means printing what the catch variable holds.

**#630 adds the third shape: a base function whose result is an OBJECT carries a
contract about that object, and neither `outputType` nor a printed value can see
it.** `std.sink_create` returns a text sink, and two properties of that value
are load-bearing on every target:

* `std.type_of(sink)` must answer `"Sink"` — the same string everywhere, never
  the host builder's own type name. A target backing the sink with a bare
  `String`/`StringBuilder`/`strings.Builder`/`io.StringIO` answers `"String"`/
  `"StringBuilder"`/`"Builder"`/`"StringIO"` instead, so a Ball program
  branching on `type_of` takes a different arm per target — a divergence that
  compiles, runs, and prints plausible output everywhere.
* The sink is **reference-semantic**: appending to it inside a callee is visible
  to the caller. A by-value backing loses exactly that append and nothing else —
  the silent shape of issue #300 (Rust's by-value `Vec<BallValue>` clone lost
  every list append) and of the C++ self-host's by-value `std::map` copy.

Neither is a *return shape*, so the #545 probe cannot reach them; the second is
also invisible to any fixture that only uses the value in the function that
created it. The gates are therefore split in two, and BOTH are required:

* **Cross-target behaviour** — `tests/conformance/466_string_sink` builds a sink,
  appends to it **across a function call**, reads it back, and also exercises
  `.length`/`.isEmpty`/`writeln`/`writeCharCode`/the `StringBuffer('x')` seed.
  The cross-call append is the whole point of the fixture.
* **The type tag, per target** — a conformance golden *cannot* assert
  `type_of(sink) == "Sink"`, because a golden is produced by running the
  fixture's Dart source natively and real Dart answers `"StringBuffer"`. So each
  target pins it in its own unit test, beside its own backing:
  `dart/engine/test/engine_test.dart`, `dart/compiler/test/base_calls_test.dart`,
  `ts/compiler/test/string_sink.test.ts`, `cpp/test/test_compiler.cpp`,
  `rust/shared/src/runtime.rs`, `csharp/shared/test/SinkContractTests.cs`,
  `go/runtime/sink_contract_test.go`, `python/compiler/tests/test_sink.py`.

The general rule: **when a base function returns a value with an identity — a
type tag, a shared backing, an ordering — name that contract in the declaration's
doc comment and gate it per target, because the corpus can only see what the
source language can express.**

#### A rendering TABLE is only closed when a TEST says so (#641)

#616's per-target fix left each compiled runtime with an explicit
`name -> prefix` table (`dart_error_to_string` / `dartErrorToString` /
`DartErrorToString` / `__ball_err_prefix`) whose doc comment asserts it is
"EXPLICIT and closed over the type names this runtime raises". That claim was
prose. Three of the four tables had no `TypeError` arm while every one of those
runtimes raises a `TypeError` for a failed cast, and the fourth rendered it with
a prefix Dart does not spell — so the same caught cast read four different ways,
and no gate could see it, because the only fixture that reaches a cast pattern
(`302_cast_patterns`) prints a hardcoded literal from its catch body.

Two instruments close it, and they are different in kind:

* `tests/conformance/467_caught_type_error_to_string` — the cross-target
  observable, printing `$e` / `e.toString()` / an interpolated form after a
  failed cast pattern, and ending with an `on TypeError catch` clause so a
  target whose cast throws something untyped fails too.
* `tools/check_error_rendering_tables.py` (`Proto Checks`, every PR) — the
  STRUCTURAL half a fixture cannot supply. It extracts, per target, the Dart
  error names that target raises as a Ball throw and the names its table covers,
  then asserts closure, coverage and prefix agreement, with positive floors so a
  regex that stops matching fails instead of passing vacuously. Its own
  self-test (`tools/test/test_check_error_rendering_tables.py`) runs first.

  Its C++ raise-site glob covers `cpp/shared/*.h` as well as
  `cpp/shared/include/*.h` since #708. The loose header there is the COMMITTED,
  generated `ball_protobuf_rt.h` — real linked code that raises
  `FormatException`/`ArgumentError`/`TypeError` through the very `BallException`
  ctor this extractor reads — and it sat outside every check above, so a Dart
  error name added to `dart/ball_protobuf/lib/**` and cross-compiled into it
  would have reached a `catch` with no rendering entry anywhere. The self-test's
  `a raised name in the generated ball_protobuf runtime is in scope` case is the
  negative control: with the glob narrowed back it exits 0 instead of 1.

The canonical string comes from **real Dart**, and that is a property of how the
corpus is built rather than a preference: `dart/encoder/bin/generate_conformance.dart`
captures `dart run <source>`'s stdout, so any fixture generated from
`tests/conformance/src/` is golden-locked to the SDK's own answer — here
`type 'String' is not a subtype of type 'int' in type cast`, with **no**
`TypeError: ` prefix, because `_TypeError.toString()` IS its message. When a new
built-in error becomes reachable from a Ball program, measure its `toString()`
against the SDK, add it to the checker's contract, and add its arm to every
table — the checker fails until all of that is done.

**The literal-throw half (#658).** Every check above is keyed on what a runtime
RAISES, and that is not the only way one of these values reaches a `catch`. A
program's own `throw StateError('boom')` is built by the COMPILER from a
`messageCreation` the encoder produced, so no raise site exists for the closure,
coverage or agreement checks to see — and the corpus had never put a USER-thrown
exception in a value position either (`463`/`464` print hardcoded literals or
`e.message`; `465`/`467` print a caught value, but only a runtime-raised one,
whose payload already carries the canonical string). Two defects lived in that
blind spot: the Dart REFERENCE engine — the implementation every self-hosted
engine is compiled from — returned the raw `message` field rather than Dart's
prefixed `toString()`, and `ArgumentError`, which Dart spells
`Invalid argument(s): <message>` and which no runtime in the repo raises, was in
no target's table at all.

Two instruments close it, mirroring the pair above:

* `tests/conformance/473_caught_user_thrown_builtin_error` — the cross-target
  observable. It prints a caught `StateError`/`FormatException`/`ArgumentError`
  through an untyped catch, a typed `on T catch`, and a non-matching typed clause
  that falls through, and it reads `.message` alongside `'$e'`. Those two are
  DIFFERENT strings — the raw constructor argument versus the prefixed form — so
  a "fix" that rewrote the stored field would pass one half and break the other,
  which is exactly why both are in one fixture.
* `LITERAL_THROWABLE` in `tools/check_error_rendering_tables.py` — the structural
  half. Every explicit rendering table must cover
  `StateError`/`FormatException`/`RangeError`/`ArgumentError` whether or not that
  target raises one, and TWO tables join the checker here for the first time. The
  Dart reference engine is one (a runtime-raised error reaches its catch variable
  verbatim; a user-thrown one does not, so `coverage_exempt` exempts it from the
  raised half only). The other is `ts-engine` — `ts/engine/src/engine_setup.ts`'s
  hand-written `__bts`, which SHADOWS the compiled engine's `to_string`, so the
  TS self-hosted engine never reaches the arm the Dart source defines. It had no
  Dart-error arm at all, and its generic map branch filters every `__`-prefixed
  key, so the caught value printed as `{arg0: boom, message: boom}` — the type
  tag not even visible. **A shadowing override is a second implementation of a
  cross-target contract**: when one exists, the checker must know about it, or a
  fix to the reference source plus a regen silently does not reach that target.

The ctor-argument KEY is deliberately NOT checked structurally. Every encoder
stores the argument positionally (`{arg0: 'boom'}` — a Dart built-in carries no
`TypeDefinition`, so the `argN` → parameter-name remap has nothing to resolve
against) while every table reads `message`, and each target already closes that
in a different, correct place: C++ renames in its compiler's throw lowering
(#640), Go/Rust/C#/the Dart engine alias it in `std.throw` itself (#615). A
source-pattern check would either demand one shape of all of them or rubber-stamp
whatever each does; the fixture measures the observable instead.

#### A by-NAME ROUTE is only bounded when a test derives its cases from the route table (#697)

The Dart encoder diverts ten getter names — `isEmpty`, `isNotEmpty`, `sign`,
`isNaN`, `isFinite`, `isInfinite`, `runes`, `isEven`, `isOdd`, `reversed` —
onto `std` / `std_collections` base calls, because without type resolution the
name is all it has. Routing by name is a claim about the receiver, and nothing
checked it: a class declaring `int isEmpty` encoded `b.isEmpty` as
`std.string_is_empty(b)`, so the program contained **no `fieldAccess` for the
user's member anywhere**. `dart run` prints `44`; every engine printed `false`.

No existing gate could see it, and each for its own reason — which is why the
instrument had to be a new KIND:

* `check_encoder_completeness.dart` asks "is every emittable base function
  executed by some fixture". `string_is_empty` was executed — from the *right*
  receiver. A completeness gate cannot see a route firing on the *wrong* one.
* Tier A is structural: the pipeline round-trips this source syntactically
  clean, so the row reads clean.
* A cross-engine differential is blind by construction: the defect is in the
  ENCODER, so every engine is faithfully running the same wrong program and
  they all agree.

The gate is `dart/encoder/test/builtin_accessor_user_member_test.dart`, and its
cases are **derived from `DartEncoder.builtinAccessorGetters`** — the encoder's
own route table, not a list retyped into the test. Per name it asserts both
directions: a user field, a user getter, an instance-creation receiver and an
inherited-in-unit member all resolve to the member, and a `dart:core` receiver
still routes (a fix that merely deleted the route would pass half of that).
Adding a route without teaching it the receiver seam fails the gate with **no
test edit**, which is the property a hand-listed test set does not have.
`tests/conformance/476_user_member_named_like_builtin_accessor` is the
cross-target half, pinning every engine row against `dart run`.

**Deriving the NAMES is only half of it — the receiver SHAPES have to be
derived-or-enumerated too.** The first cut of this gate derived its ten names
from the table and then hand-listed the receiver shapes under a separate
heading, and `this.` / `super.` were simply absent from that hand-list. They
are the two receivers whose type is *trivially* provable (the enclosing
declaration, and its `extends` clause), so the seam declined them and the
original wrong answer survived at full strength — `this.isEmpty` inside the very
class that declares `isEmpty` still encoded as `std.string_is_empty(self)`. A
shape that is absent from a hand-list is indistinguishable, in a green run, from
a shape that is handled. The fix puts every PER-NAME receiver shape inside the
derived loop (FIELD / GETTER / INSTANCE-CREATION / INHERITED / `this.` /
`super.` / the `dart:core` control) and keeps only the genuinely one-off shapes
outside it — and every DECLINE is pinned by a case asserting the route still
fires, so "not handled" can never be mistaken for "deliberately declined".

The **floor on the derived set must sit at its MEASURED value** for the same
reason. `expect(builtinAccessorGetters.length, greaterThanOrEqualTo(6))` while
the set holds ten leaves four routes deletable in silence: the per-name matrix
would shrink with the table and the suite would stay green on a smaller
population. A floor is a claim about what was measured, not a round number
below it.

**A floor at the measured value is still only a COUNT, and a count cannot see a
substitution** (#786). Raise that bound to `greaterThanOrEqualTo(10)` and a
deletion does fail — but a SWAP does not move the number at all: `isEven` out,
`isBlank` in, ten names before and ten after, and the derived matrix quietly
iterates a different population than the one this document,
`.claude/rules/dart.md`, `dart/encoder/AGENTS.md` and fixture 476 all name by
literal string.
A rename has the same arithmetic signature, and an addition lands with no
acknowledgement anywhere, so the "ten getter names" prose drifts from the code
in silence. (It is the same shape as the coverage study's `excluded.json`
(#676): a count could not tell a partial readmission from a pin whose test
suite shrank by three while its library grew by three, so the *identities* had
to be committed.) The gate is therefore exact SET EQUALITY against an
independently restated name list, reporting the missing and the unexpected
names separately so a failure states the mutation rather than a number.

**And the gate has to be a FUNCTION the suite can feed a table it should
reject.** An assertion written inline against the table it is bounding can
demonstrate only that today's table passes — which is the very same green a
gate with no teeth prints, and is exactly what the count-only version printed
for three of the four mutations above. `closedSetComplaints` in that file is a
plain `Set<String> -> List<String>`, and the suite hands it a deletion, a swap,
a rename and an addition (each of which must be rejected) plus the real table
and the expected literal (each of which must be accepted — the positive
control that stops the other four passing because the gate rejects
everything). Prove the instrument, then point it at the code.

The same rule generalises, in two halves that read the table differently on
purpose: whenever a component decides something by NAME — a route table, a
method-arity window, a rendering table (#641) — the test that enumerates the
INPUT SHAPES must read the table itself, not a copy of it, so a new entry gets
its cases with no test edit; and the test that bounds MEMBERSHIP must compare
that table against an independent copy, so an entry that leaves it, or is
swapped for another, cannot pass as a smaller-but-green population. Reading
only the table catches no mutation OF the table at all; holding only a copy
catches every one of them and still leaves a new entry's input shapes
unexercised.

#### A guard whose table is flattened for one member kind and not another

The C++ compiler's own by-name shortcut (`declared_by_receiver`) is the same
decision made at the other end of the pipeline, and it carried a matching hole
for a different reason: `class_getters_by_sname_` is FLATTENED over the
inheritance chain when the metadata is built, while `class_own_fields_by_sname_`
is strictly own-fields. So an inherited `int get length` proved the receiver and
an inherited plain `int length;` did not — `child.length` on a subclass whose
BASE declares the field compiled to `ball_length(child)`. **No engine row can
fail this**: the engines resolve a plain `fieldAccess` own-key-first through the
`__super__` chain, so only the `C++ Compiled` row sees it, which is precisely
why the guard belongs in the shared conformance fixture rather than in a
target-local test alone. When two tables answer one predicate, check they have
the same REACH before treating either as proof.

#### A guard applied to SOME of the shortcuts it should cover

`declared_by_receiver` reached seven names after #664 and #697 (`length`,
`isEmpty`, `isNotEmpty`, `isNaN`, `isFinite`, `isInfinite`, `isNegative`) — and
`compile_field_access` carried **six more shortcuts of exactly the same shape**
that it did not reach: `.first`, `.last`, `.runtimeType`, `.entries`, `.keys`,
`.values` (#787). Nothing was red, because the seven that were guarded had
fixtures and the six that were not had none. A guard is not proven by the names
it covers; the measurable claim is about the SET the guard is applied to, and
the only instrument that can see a missing member of that set is an enumeration
of the set itself. The failure modes differed within the six, which is why
per-name coverage mattered rather than one representative: `.entries` / `.keys`
/ `.runtimeType` answered the wrong VALUE, while `.first` / `.last` lowered to
`obj.front()` / `obj.back()` and the program did not COMPILE at all — a shape a
"wrong output" expectation would not even have described.
`tests/conformance/479_user_member_named_like_collection_accessor` is the gate,
and it carries both declaration shapes (field and getter) because the
compiler's fall-through resolves them through different paths — and `.values`
is served correctly for a getter and wrongly for a field, so a fixture with only
one shape would have pinned the wrong half of it.

**Writing the enumeration is itself the instrument.** Two of the six names
turned out to be broken on OTHER targets, in ways nothing in the corpus had ever
asked about: a field named `entries` on a class with a method takes every
self-hosted engine down (#860 — the engine binds an instance's fields into a
method scope by iterating `selfMap.entries`, a name a user program may also
declare), and a field named `runtimeType` throws on the TS engine at
construction (#863 — `Object.prototype.runtimeType` is installed as a getter
with no setter). Neither is reachable from the guard this fixture was written
for; both were invisible until a fixture named the shapes. Each is carved out of
the fixture with its issue number and its removed lines carried verbatim in the
issue body — the same discipline #800 established for `476_…` — so the carve-out
is a tracked reproduction rather than a silently narrowed test.

### 5c. A whole MODULE with no fixture is a hole the parity number cannot see

`std_concurrency` shipped nine declared base functions, a dispatch arm in the
Dart reference engine, and a `compile_concurrency_call` in the C++ compiler —
and **zero** executed fixtures. Every one of the nine read
`"coveredByFixtures": [], "carvedOut": false` in
`tests/conformance/std_coverage.json`, and `grep -rE 'Isolate|Thread|mutex|
Atomic' tests/conformance/src/` returned nothing. The whole-corpus
`Results: N passed, 0 failed` line said nothing whatsoever about threads,
mutexes or atomics, on any of the seven engines.

What was living in that hole (issues #606/#607/#608), all three found by reading
rather than by any gate:

* **The Dart compiler never routed the module at all.** `_isBaseModule`
  enumerated eight module names by hand and this one was missing, so every call
  compiled to a bare `thread_spawn(...)` — a user-function call naming an
  identifier the generated Dart never defines — with no diagnostic.
* **The C++ compiler implemented three functions no builder declares**
  (`thread_detach`, `unique_lock`, `atomic_fetch_add`), producible by no
  encoder, implemented by no engine, and exercised only by unit tests asserting
  on emitted source TEXT. Its `thread_spawn`/`mutex_create` also emitted
  DECLARATION STATEMENTS where a value was expected, so their declared `-> int`
  could not be honoured.
* **The engine fabricated answers.** `atomic_store` discarded the write,
  `atomic_load` echoed its own input, `atomic_compare_exchange` returned an
  unconditional `true`, and `thread_spawn` returned the literal `0`. Because the
  other six engines are self-hosted from that source, all seven agreed on the
  wrong answer.

Three rules generalise out of it:

1. **A module's fixture coverage is a first-class reading of
   `std_coverage.json`.** A row of `coveredByFixtures: []` that is also
   `carvedOut: false` is an untested function, not a quiet one — and a whole
   MODULE of them is a hole no parity number can see.
2. **Pin the failing case, not just the working one.** `477_std_concurrency_handles`
   prints a CAS that must FAIL and the cell value after it; that is the line no
   placeholder can pass. A fixture that only exercised a matching CAS would have
   been green against the unconditional `true`.
3. **Pin the contract, not the representation.** A handle is opaque, so the
   fixture asserts handles are DISTINCT and never prints one. Misuse (joining
   twice, unlocking an unlocked mutex, naming an unminted handle) is fail-loud
   and asserted in `dart/engine/test/std_concurrency_test.dart` instead — what a
   caught host error reads as is §5b's contract, and folding it in here would
   make this fixture about error rendering.

The drift that let #607 happen has its own gate now:
`cpp/test/check_declared_base_functions.py` (ci.yml's always-on `proto` job)
compares every name a module-scoped `compile_*_call` implements against
`tests/conformance/std_coverage.json`, the all-module canonical inventory. It is
the C++ sibling of `dart/shared/test/std_routed_declarations_test.dart` (#505),
and it carries a MEASURED frozen known-gaps list plus a positive floor, so a
regex that stops matching fails instead of passing vacuously.

### 6. Engine code must be self-host-portable
Because the engine is itself encoded to Ball, its Dart source must avoid
constructs the syntactic encoder mishandles. The one that bit #55's fix:
`List.addAll` routes to the non-mutating `list_concat`, so a spread splice
written with `result.addAll(items)` works on Dart but silently drops elements on
TS/C++. Append per-item with `.add`. Same caution for `Map.addAll`, `.keys`.
See [.claude/rules/dart.md](../.claude/rules/dart.md).

## CI produces the fix (issue #619)

Two things used to force local toolchain work on every change:

**1. The conformance matrix is now a PR gate.**
`.github/workflows/conformance-matrix.yml` used to run on push-to-main, a weekly
cron and manual dispatch only, so every contributor had to
`gh workflow run conformance-matrix.yml --ref <branch>` by hand and read the run
back — and anyone who forgot simply saw no row, which reads as green. It now
also has a `pull_request:` trigger sharing the SAME path filter as `push`
(one list, `&matrix_paths` / `*matrix_paths`; GitHub Actions has supported YAML
anchors in workflow files since 2025-09-18). `tools/ci/check_matrix_paths.sh`
compares the two lists after the parser expands the alias and fails on drift —
a path present in one trigger only would silently un-gate exactly the PRs that
touch it. Concurrency is per `github.ref` with `cancel-in-progress`, so a second
push to a PR supersedes the run still in flight.

**2. `Ball Artifact Freshness` hands you the regenerated bytes.**
That job regenerates every committed Ball artifact (`std.json`, `ball_proto.json`,
`ball_protobuf.json`, the conformance corpus, `std_coverage.json` +
`STD_COVERAGE.md`, `compiled_engine.ts`, `compiled_cli.ts`, `compiled_engine.go`,
`compiled_cli.go`) and `git diff --exit-code`s each family. The gates are
unchanged — same fail-loud shape, same exit 1 — but when an **`Assert …` gate**
fails the job uploads the regenerated files, at their exact repo-relative paths,
as the `regenerated-artifacts` workflow artifact. Only from an Assert gate: a
failed *Regenerate* step means a generator died part-way under `set -euo
pipefail`, so the file it was writing may be truncated, and uploading that would
hand you a corrupt artifact labelled "the fix" (#625). Each step's `if:` names
the per-artifact `steps.<assert-id>.outcome`, and the collect step builds its
pathspec list from the same outcomes, so a Regenerate failure contributes no
paths at all. Applying them needs **no Dart/TS/Go toolchain**:

```bash
bash tools/ci/apply_regenerated.sh <pr-number>     # or: --run <run-id>
git commit -m "chore: apply the CI-regenerated Ball artifacts"
```

The script resolves the PR's latest `ci.yml` run, downloads the artifact, copies
it into the checkout and stages it. It **refuses** to apply a run whose head SHA
is not your current `HEAD` (the artifacts are a function of the sources at that
commit, so applying them elsewhere commits bytes the tree does not produce), and
it fails loud on an empty artifact rather than letting a lane commit nothing.
Its cases run on every PR from the always-on `proto` job.

**Optional auto-push (`REGEN_PAT`).** If the repository secret `REGEN_PAT`
exists, the job additionally commits the regenerated files and pushes them to
the PR's own branch, so nobody applies anything by hand. It is off by default and
skipped with an explicit log line when the secret is absent; it never pushes to a
fork (`github.event.pull_request.head.repo.full_name == github.repository`).

It must be a PAT, not `GITHUB_TOKEN`: *"When you use the repository's
GITHUB_TOKEN to perform tasks, events triggered by the GITHUB_TOKEN will not
create a new workflow run, with the following exceptions"* — `workflow_dispatch`
and `repository_dispatch` always create a run, and `pull_request`
opened/synchronize/reopened creates one in an **approval-required** state. Neither
exception covers a push to a branch, which is what this step does —
[Triggering a workflow](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow).
A `GITHUB_TOKEN` push would leave the PR sitting on a commit with **no CI at
all**: a PR that looks settled and was never checked.

*One-time owner setup:* create a **fine-grained** personal access token scoped to
this repository only, with Repository permissions → **Contents: Read and write**,
then `gh secret set REGEN_PAT --repo Ball-Lang/ball`. (`RELEASE_PAT` no longer
exists in this repo's secrets; do not reuse that name.)

**Auto-push loop-breaker (#625).** A PAT push triggers CI *by design*, so the job
that produced the regeneration commit runs again on it. `git diff --cached
--quiet` stops only the identical-bytes case; a **nondeterministic** generator
would drift, push and re-trigger forever. The regeneration commit therefore
carries a `Ball-Regen-Autopush: ball-artifact-freshness` trailer, and
`tools/ci/regen_loop_breaker.sh` refuses to push onto a head that already has it:
**one auto-push per human commit**, then a loud failing job summary naming the
nondeterministic generator as the thing to fix. `tools/ci/check_ci_regen_wiring.sh`
keeps that wiring honest — it parses the job and asserts the collect/upload/push
steps gate on `steps.<assert-id>.outcome == 'failure'` (never a bare `failure()`,
which cannot tell a stale artifact from a generator that died mid-write) and that
the push still consults the loop-breaker. Both run on every PR from `Proto
Checks`, self-test first.

Since #655 the set of artifact families it checks is **derived, not listed**: a
family is an `Assert …` step whose `run` contains `git diff --exit-code`, which
is precisely what distinguishes a regenerate-and-diff gate from the four checker
steps (`assert-fixture-sources`, `assert-encoder-completeness`,
`assert-fixture-names`, `assert-node-shapes`) that own no artifact. Every derived
id must appear in all three `if:` gates **and** own a pathspec block in the
collect step's table that adds at least one path — the table was the second
ungated half, and a family whose gate names it but whose table forgot it would
upload a partial fix. The six ids that exist today stay as a positive floor, so a
predicate that stopped matching fails loud instead of silently shrinking the set
being checked. Adding a seventh committed artifact therefore fails the PR that
adds it until all four places agree.

## The required status checks

The list is not a convention: since 2026-09-14 it is enforced by the
repository's `Protect main` ruleset, whose **19 required status check contexts** are
(see the #59 comment of that date):

<!-- BEGIN REQUIRED-CONTEXTS repo=Ball-Lang/ball ruleset=17056238 -->
- `Ball Artifact Freshness`
- `C#`
- `C++ (macos-latest)`
- `C++ (ubuntu-latest)`
- `C++ (windows-latest)`
- `C++ Self-Host Tally (every fixture must pass)`
- `CLI Verb Parity`
- `Dart`
- `Dart Coverage Ratchet`
- `Dart Regression Gate (engine + encoder + compiler)`
- `Detect changed stacks`
- `Go`
- `Proto Checks`
- `Protobuf Codegen (gen + rpc)`
- `Python`
- `Rust`
- `TS Regression Gate (engine + compiler)`
- `TypeScript`
- `Upstream Conformance (Editions)`
<!-- END REQUIRED-CONTEXTS -->

A PR is BLOCKED until all 19 report success, so "the checks are green" is a
mechanical statement about that list, not a judgement call. `Dart Coverage
Ratchet` is on it too — it is easy to overlook because it is an independent job
(`dart-coverage` in `ci.yml`) rather than part of the `Dart` job; the
`coverage.yml` workflow next to it owns NO required context.

### Per-PR job fan-out (issue #666)

Runner concurrency is the measured bottleneck of this repo's PR sweep. The org
is on the GitHub Free plan — **20 concurrent jobs, 5 of them macOS**
(<https://docs.github.com/en/actions/reference/limits>) — and on 2026-09-13, with
a dozen lanes in flight, `gh run list --status queued` showed **30 runs queued
and 0 in progress**. Every workflow already carries a `concurrency` group with
`cancel-in-progress`, so nothing superseded is wasting a slot: the fan-out
itself is the cost.

**The policy.** Every job reachable on `pull_request` in `ci.yml`,
`conformance-matrix.yml`, `regression-gates.yml`, `ball-audit.yml` and
`coverage.yml` must be one of:

1. the owner of one of the 19 required contexts — it has to report anyway;
2. conditioned by a job-level `if:` on a `changes` output (the
   `./.github/actions/detect-changed-stacks` composite action, single source of
   truth since #458);
3. inside a workflow whose `pull_request:` trigger carries a `paths:` filter;
4. the `changes` classifier itself;
5. listed in `tools/ci/pr_job_fanout_allowlist.txt` **with a reason**.

`tools/ci/check_pr_job_fanout.sh` enforces it from the always-on `Proto Checks`
job, and its `--self-test` drives a fabricated unconditional job as the negative
control. An exemption without a stated reason is rejected.

**A required context must APPEAR, and a skipped MATRIX job does not report
one.** This is the sharp edge of "never require path-filtered jobs" above, and
it is not hypothetical. A job-level `if:` that evaluates false normally still
satisfies a required check — GitHub records the check as skipped. But when the
job is a MATRIX job whose `name:` interpolates `${{ matrix.<key> }}`, GitHub
emits exactly ONE check run, under the **un-expanded** name. `ci.yml`'s `cpp`
job carried such an `if:`, so a diff that touched neither `cpp/**` nor `infra`
produced a lone `C++ (${{ matrix.os }})` and **none** of the three required
`C++ (ubuntu-latest)` / `(windows-latest)` / `(macos-latest)` contexts —
measured on PR #647 at `bc0c367a`, whose check-run set is exactly that. Such a
PR can never merge. The fix is to gate the **steps**, never the job: every leg
starts, reports under its real name, and costs ~20 s when there is nothing to
do. The guard fails the build if a job-level `if:` is put back on a required
matrix job.

**What is conditioned on what.**

| Workflow | Conditioning | Notes |
| --- | --- | --- |
| `ci.yml` | per-job `if:` on `changes` outputs; `cpp` gates its STEPS | `changes`, `proto`, `cli-verb-parity`, `dart-coverage` are always-on and each owns a required context |
| `conformance-matrix.yml` | workflow `paths:` filter **and**, since #666, a per-row `if:` | PR runs only the rows the diff can move; push/schedule/dispatch still run the FULL matrix |
| `regression-gates.yml` | per-job `if:` on `changes` outputs | already so before #666 |
| `ball-audit.yml` | workflow `paths:` (`**.ball.json`, `**.ball.bin`) | owns no required context |
| `coverage.yml` | workflow `paths:` (`cpp/**`) + `github.event_name != 'pull_request'` on the other four | owns no required context |

**The conformance matrix's per-row conditions.** Each row runs when the diff
touches `tests/conformance/**` (`corpus`), any of
`dart/{engine,shared,compiler,self_host}/**` (`dart_core` — the Dart sources
every self-hosted engine is compiled from), the matrix's own definition
(`matrix_self` — `conformance-matrix.yml` or `tools/ci/roundtrip_floor.sh`), or
that row's own language dir.
Measured on PR #644 (`d853854b`): 18 matrix jobs ran, 15 of them for languages
the diff did not touch. The `infra` fail-safe is deliberately NOT part of those
conditions — it is true for any file outside the language dirs (docs, `tools/`,
`ci.yml`), which would put all 18 rows back on every CI-lane PR. Leaving it out
is safe **here and only here** because this workflow's trigger is already
`paths:`-filtered, so every file that can start it maps onto one of those
signals. The per-row conditions are all
`github.event_name != 'pull_request' || …`, so the post-merge and weekly
full-matrix safety net does not move.

**"Every filter path maps onto a row signal" is a correctness invariant, and it
is guarded three ways.** Leaving `infra` out of the row conditions is only safe
while that holds. An entry in the filter that lights up no signal a row reads is
SILENTLY GREEN: the workflow starts (the path matched), all 17 rows evaluate
false, and a summary that correctly treats `skipped` as benign prints a full
table of SKIPs and exits 0 — a green Conformance Matrix that executed zero rows.
So:

- **Statically**, `tools/ci/check_matrix_paths.sh` (always-on `proto` job) now
  does more than compare the two triggers' lists. For each entry in the filter
  it synthesizes a concrete path that entry matches, runs the REAL
  `detect-changed-stacks` classifier over it, and fails unless at least one
  signal some row's `if:` reads comes back `true`. The signal set is scraped out
  of `conformance-matrix.yml` itself (`needs.<classifier>.outputs.<name>`), so
  there is no second table to keep in sync, and `--self-test` drives the
  negative control — adding `proto/**` to the filter is RED.
- **At run time**, `conformance-matrix.yml`'s `Parity Matrix` fails a
  `pull_request` run that executed ZERO engine rows, whatever the cause (an
  unmapped filter path, a row condition that stopped matching, a classifier that
  returned all-false). Push, schedule and dispatch runs are exempt because their
  rows are unconditional. `tools/test/test_parity_matrix_floor.py` (also the
  `proto` job) renders that summary step out of the workflow and executes it
  under bash across eleven scenarios plus two structural checks, including a
  negative control that strips the floor and asserts the same all-skipped run
  then goes green.
- **Also at run time**, the same `Parity Matrix` step fails a run in which a
  language's rows executed only PARTIALLY — `rust-engine` ran, `rust-roundtrip`
  did not. The zero-row floor above cannot see that case: `engine_rows_run` is
  1, `skipped` is benign, and the run is green while the skipped row's ratcheted
  floor (`RUST_ROUNDTRIP_FLOOR`, raised to 100 by #687/#725) was never evaluated
  on the diff that could break it. Every row of a language carries the identical
  condition, so a partial group means one drifted; the floor asserts the OUTCOME
  those conditions must produce rather than restating them, and it applies on
  every event (on push/schedule/dispatch the conditions are unconditionally
  true, so a partial group is unreachable there and it cannot fire spuriously).
  `test_parity_matrix_floor.py` drives it, its negative control (strip the block
  ⇒ the same partial run goes green), and a structural check that the group
  table covers EVERY matrix row job — the row set read from the workflow's own
  `jobs:`, so a row added to `needs:` but forgotten in the table is RED rather
  than silently exempt. A second structural check proves the negative control
  itself is honest: these scripts run under `set -uo pipefail`, not `-e`, so a
  strip that deleted the helper but left an invocation behind would print
  `group_check: command not found` and still exit 0 — the control would pass
  for the wrong reason. It asserts no invocation survives, the surrounding
  gates do, and a non-trivial span was taken.

The detect-changed-stacks truth table pins `corpus`/`dart_core`/`matrix_self`
themselves.

### The `std_inventory` signal's closed-set assumption, and its guard (#774)

`detect-changed-stacks`' `std_inventory` signal is what re-enables the
`rust`/`csharp`/`python` jobs when the canonical Dart std inventory moves —
those three suites read `dart/shared/lib/std*.dart` / `dart/shared/std.json`
**off disk** as their source of truth, so a dart-only inventory edit is
precisely the commit each of them exists to catch and precisely the commit on
which their jobs used to skip.

The signal rests on a **closed-set assumption in two directions**, and the truth
table can check neither. It drives the classifier with synthetic inputs, one row
per path that already exists; it cannot see a file that does not exist yet.

1. **Which files ARE the inventory.** This used to be a hand-written *shape*
   regex, `^dart/shared/lib/std(_[a-z_]+)?\.dart$`. All eight builders happen to
   fit it. A ninth named outside that shape — a digit, a capital, a `_std.dart`
   suffix order — would have failed to trip the signal silently.
2. **Which stacks READ the inventory.** The exclusion of `ts/`, `go/` and `cpp/`
   came from one grep at review time. A new off-disk reader in any of them would
   simply have started running stale on every std-only PR.

`tools/ci/check_std_inventory_signal.sh` (always-on `proto` job) closes both by
deriving, never describing:

- The builder set comes from the `Module buildStd*Module(` **declarations**
  themselves, and the artifact names from `dart/shared/bin/gen_std.dart`'s own
  `$outputDir/<file>` writes — so renaming `std.json`/`std.bin` moves the signal
  with it. `detect.sh` carries that pattern in a **generated, marker-delimited
  block**; the gate re-derives it on every PR and fails on drift, and
  `--write` regenerates it. A builder added under any filename is drift.
- The stacks to scan are derived too: the stack set from `detect.sh`'s `infra`
  prefix list, the OR-list from its own `$std_inventory` references. Adding a
  stack to the OR-list removes it from the scan automatically, so there is no
  second table to keep in sync.
- Both of those are static and would still pass if `std_inventory` were computed
  and read by nobody, so a third invariant runs every derived path through the
  REAL classifier (sourced — the contract `truth_table.sh` and
  `check_matrix_paths.sh` also use) and requires `rust=true csharp=true
  python=true`. Non-builder `dart/shared/lib` siblings are the negative control,
  so the pattern cannot quietly widen into `^dart/shared/`.

**Known limit, stated rather than implied.** The cross-stack scan is a literal
scan over tracked source files after comment- and docstring-stripping. It counts
a reference in two shapes, both restricted to **path-shaped** tokens (no
whitespace):

- a token containing a **full-path needle** — `dart/shared/lib/std…`,
  `dart/shared/std.json`, `dart/shared/std.bin` — in a string literal
  (`` `${root}/dart/shared/std.json` ``), in a `//go:embed` directive, or
  unquoted in a shell/CMake/YAML/TOML file;
- a token naming the inventory's **directory** rather than one concrete file,
  because the filename is then decided elsewhere: `join("dart/shared/lib",
  name)`, `join(root, "dart/shared", "std.json")`, `"dart/shared" +
  "/std.json"`, `` `${root}/dart/shared/lib/${name}` ``, `dart/shared/lib/$f`,
  `//go:embed dart/shared/lib/*.dart`, and the **segmented** join
  `os.path.join(root, "dart", "shared", …)` (including the half-segmented
  `("dart", "shared/lib/std.dart")`). Concretely: `dart/shared` at a segment
  boundary whose tail is empty, `/lib`, or carries a `$ { } % * ?` marker.

Two carve-outs keep that from becoming `^dart/shared/` under another name, and
each has a self-test case. A needle inside a literal that also contains
whitespace is a *sentence* — `ts/compiler` and `cpp/compiler` carry five such
diagnostic messages today, and flagging them would make the gate noise instead of
a signal. And a token naming ONE concrete **non-inventory** sibling is not a read
of the inventory: `ts/` and `cpp/` reference `dart/shared/lib/ball_file.dart` and
`dart/shared/ball_protobuf.json` in code today, and must keep being able to.

What remains out of reach is a path assembled from *separate* fragments at run
time — `"dart" + "/shared/lib/std.dart"`, where no single token carries either
shape. That is the grade of check this is, and the reason invariant 3 exists
beside it.

**The matrix gates changes to itself** (#642). `conformance-matrix.yml` and
`tools/ci/roundtrip_floor.sh` are in the filter, so a PR that only moves a row's
floor re-runs the matrix — before #642 such a PR started no matrix run at all,
and an absent check reads as green, which is how the four round-trip rows were
first floored by a commit nothing re-measured. Those two paths map onto
`infra` alone, which no row reads, so the guards above made adding them a real
decision rather than a one-line edit: they also required a signal,
`matrix_self`, which EVERY row ORs in (a change to the matrix definition can
move any row). The classifier truth table pins it both ways — the two paths set
it, a neighbouring workflow and a neighbouring `tools/ci` script do not, so it
cannot decay into `infra` under another name.

**That list is gated, not trusted** (issue #655). It used to be hand-copied
prose about a setting edited in a web UI: it matched the live ruleset on
2026-09-14 and nothing would have noticed the day it stopped — in either
direction, and the worse one is a doc that names a check the ruleset no longer
requires, because a lane then believes a PR is gated on something that blocks
nothing. `tools/ci/check_required_contexts.sh` reads the list between the
`REQUIRED-CONTEXTS` markers above, reads ruleset `17056238` live over the REST
API, and fails on any difference — plus the prose counts, the sort order, a
ruleset that stopped enforcing, and one that requires zero checks. It runs on
every PR from the always-on `Proto Checks` job, its offline negative controls
(`tools/test/test_check_required_contexts.sh`) first.

The marker names the repo and ruleset id, so the guard cannot silently compare
against a different ruleset than the one this doc documents. No extra credential
is involved: `GET /repos/{owner}/{repo}/rulesets/{ruleset_id}` needs only
`"Metadata" repository permissions (read)` and *"can be used without
authentication or the aforementioned permissions if only public resources are
requested"*
([REST docs](https://docs.github.com/en/rest/repos/rules?apiVersion=2022-11-28#get-a-repository-ruleset)),
and this repository is public — so the workflow's own `GITHUB_TOKEN` reads it.
**To change the required checks, change the ruleset first, then this list**; the
guard will fail the PR until they agree.

### Unquoted-hash name-scalar truncation (issue #704)

YAML starts a comment at a `#` preceded by whitespace, even inside a plain
(unquoted) scalar — so a step written as
`- name: C++ e2e fixture-list drift guard (#63 / #511)` parses as
`name: "C++ e2e fixture-list drift guard (#63 /"`. The visible name silently
truncates at the first unquoted `<space>#`, in both the Actions UI and anything
that reads the parsed YAML. #671 (closing #666) quoted two step names that
truncated this way; its own review found three more; and this guard's first run
against `main` found a **fourth** — `ci.yml`'s "Engine-row doc drift guard
(#610, #613)" step, added by #652 before #671 even opened, so #671's reviewer
never had a chance to see it. A one-time human sweep of "every workflow name"
does not stay true; nothing re-checked it after the fix landed, which is why a
guard exists now instead of another one-off quoting pass.

**What is checked and where.** `tools/ci/check_name_scalar_hash_guard.sh` scans
every plain-scalar `name:` mapping — the workflow's own top-level `name:`, a
job's `name:`, and a step's `- name:` — in `.github/workflows/*.yml` and
`.github/actions/*/action.yml`. A value is flagged when it is not already
quoted and either starts with `#` (an accidentally empty name) or contains an
unquoted `<space>#`/`<tab>#` anywhere after that. It is deliberately
**PyYAML-free** — a plain line/regex scanner, tracking block scalars (`key: |`
/ `key: >`) by indentation so a `run: |` step body that happens to contain the
literal text `name: ... #` is never mistaken for a real mapping key — unlike
`tools/ci/check_pr_job_fanout.sh` above, which needs a real YAML parse for
matrix expansion and anchors/aliases. The two guards read the same files
through two independent toolchains, so neither's blind spot is the whole
repo's.

**Job names are the dangerous case, step names are cosmetic.** A step's display
name truncating is a UI-only cosmetic bug; a **job's** `name:` truncating this
way would silently change one of ruleset 17056238's 19 required status
contexts, which blocks every future PR forever rather than just looking odd in
a log. Every finding is tagged `workflow` / `job` / `step` by structural
position (a dash-prefixed `- name:` is always a step; an un-dashed `name:` at
column 0 is the workflow's own name; anything else un-dashed is a job's).
Today's four offenders are all `step` — quoting them cannot move a required
context, and `tools/ci/check_pr_job_fanout.sh` (run on every PR, right before
this guard in `Proto Checks`) independently re-derives and asserts the full
19-context set from the parsed job `name:` values regardless, so a future
`job`-tagged finding would still be caught even if this guard were somehow
bypassed.

`--self-test` drives nine cases first: a quoted sibling containing the same
hash-space content is left alone; the fabricated unquoted offender is rejected;
quoting it in place (the only fix this guard asks for) goes green; an unquoted
job-level and an unquoted workflow-level offender are each rejected and tagged
correctly; an immediate `name: #comment` (value is entirely a comment) is
rejected; name-shaped text inside a `run: |` body is NOT flagged (the
block-scalar tracking actually works, not just "no false positives in these
particular fixtures"); an empty directory pair is a hard error, never a silent
pass; and an offender inside an `action.yml` is caught by the same scan. Runs
from the always-on `Proto Checks` job, no toolchain beyond `python3` (stdlib
only — no PyYAML import).

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
upward, never down — across **all five stacks**, uploaded to Codecov with
per-stack flags (`dart`/`typescript`/`cpp`/`rust`/`csharp`) via OIDC (no token).
Gate: `.github/workflows/coverage.yml`.

**Read a coverage run at the STEP level, and never let transport speak for the
measurement (#638).** A coverage job used to end by uploading its own lcov to
Codecov, so one exit code answered two unrelated questions. Run
[34746079045](https://github.com/Ball-Lang/ball/actions/runs/34746079045) is what
that cost: its `C++ coverage` job passed step 11 (`C++ line coverage floor`,
93.9% ≥ 91%) and step 12 (`C++ per-target coverage floors`, 94.6/99.0/94.3 ≥
92/97/92), then failed step 13 on a `codecov/codecov-action` OIDC
`Failed to get ID Token … Request timeout`. Result: a red on main's coverage
history with no coverage regression behind it — on exactly the history the C++
floor derivation and #599's cache ceiling read as "N consecutive green runs".

Two things changed, and one rule stayed:

- **Transport moved out.** Each language job now publishes its lcov as a
  `coverage-lcov-<flag>` artifact and **ends on its floor steps**, so the job's
  conclusion *is* the measurement. A separate `codecov-upload` job `needs:` all
  five and carries the bytes. (The Dart job measures and gates in one
  `coverage_dart.dart --floor` invocation, so its artifact is taken after the
  gate under `if: ${{ !cancelled() }}` — a coverage DROP must still be published,
  or the report gets a hole exactly at the commit worth looking at.)
- **The upload retries, then fails loud.** `codecov/codecov-action@fb8b358…` is
  v7.0.0, a *composite* action: `fail_ci_if_error` only reaches its last step
  (`dist/codecov.sh`), while the token comes from an earlier, un-retried
  `Get OIDC token` step, and v7.0.0 exposes no retry input at all. So the upload
  job fetches the OIDC token itself against `ACTIONS_ID_TOKEN_REQUEST_URL` with a
  bounded 3-attempt retry and passes it through the action's `token` input, then
  uploads with `fail_ci_if_error: true`. A transient timeout retries; a
  persistent failure reds the **upload** job — honest, and distinct from a
  coverage drop. Never `continue-on-error`.
- **The rule that outlives the fix:** judge a coverage.yml run by the named floor
  STEPS and the numbers they print, not by a job or workflow conclusion. That was
  true before the fix and stays true after it (PR #643's advisory 1: the earlier
  "judge by the C++ JOB's conclusion" wording would, applied literally, have
  thrown out the very run it was defending).

`tools/ci/check_coverage_upload_isolation.sh` — ci.yml's always-on `Proto Checks`
job, 21-case self-test with two positive controls — parses coverage.yml and
holds all of that in place: measurement and transport in different jobs, the
flag set matching the artifact set, nothing masking a floor verdict, the bounded
retry present, and no `continue-on-error`/`|| true` in the upload path.

Its floor-step count is set **at** the measured number, 5 across 4 measurement
jobs (the `cpp` job carries two floors; `typescript` carries none), not below it
(#700). Every rule in that guard is scoped to the steps its name regex found, so
a floor step renamed out of that set silently leaves all of them — and with a
floor of 4 against 5 real steps, renaming exactly one was absorbed. The
one-rename mutation is a self-test case now.

**A measurement job's conclusion is a lower bound on its floor, not the floor.**
The floor step cannot be *hidden* by anything after it, which is what the guard
enforces; but a later `!cancelled()`-gated artifact upload carrying
`if-no-files-found: error` can still red the job on a transport flake with no
coverage regression. Read the named floor STEP and the number it printed.

**The Dart ratchet is a PR gate (#605).** `ci.yml`'s always-on `Dart Coverage
Ratchet` job runs `dart run tools/coverage_dart.dart --floor 99.9` on every pull
request and blocks the merge when the workspace total drops below the floor. It
is its OWN job, not a step inside `Dart`, on measured cost: the ratchet re-runs
every package suite under the VM coverage collector (2m31s on coverage.yml run
34734567108) while the `Dart` job takes 3m40s end to end, so folding it in would
have made Dart the PR critical path; as a sibling job it runs in parallel. It
carries no `needs: changes` filter, deliberately — the measurement is
whole-workspace, its inputs are not only `dart/**`, and a *skipped* check
reports **success**, which is the exact failure mode that let the ratchet sit red
on main for a week (2026-09-06 → 2026-09-13, 17140/17167 = 99.84%) while every
required check stayed green. `coverage.yml`'s Dart job keeps its own copy of the
ratchet because it produces the lcov the Codecov upload carries (#638) and is the
push-to-main measurement; the two floors must move together.

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
floors (`cpp/build-cov-floor.sh`) were **reported, not enforced** while CI had
never measured them — a false red on main is worse than an unenforced number.
CI has measured them since, so they are now **gated**: the `C++ per-target
coverage floors (compiler/encoder/shared — gated)` step runs that script and
takes its exit code, and the floors have been ratcheted to compiler 92 /
encoder 97 / shared 92 against six consecutive agreeing main runs (#63; the run
ids and the derivation live in that script's header, which is where the numbers
belong). That script's parser is pinned by
`cpp/test/test_build_cov_floor_parsing.sh` (it used to pass silently when it
could not parse a summary at all). Every percentage that suite feeds is DERIVED
from the committed `FLOORS` table — including its future-ratchet simulation,
whose scratch floors are `committed + 2` since #700, so the control keeps
simulating a ratchet the table has not reached yet rather than the numbers it is
already running at. The script itself is PCRE-free (`sed -E`, never
`grep -P`), so that suite runs on native Windows Git Bash as well as on CI.

> A failing/ungated package suite (e.g. `ball_protobuf`, issue #75) is measured
> but surfaced as a loud WARNING and under-counted — `coverage_dart.dart`
> MEASURES coverage, it is not the test gate (that is `ci.yml`).

## CI gates (where each invariant lives)

| Invariant | Gate | Trigger |
|---|---|---|
| Oracle = native Dart | `generate_conformance.dart` + drift check | every PR (`ball-freshness`) |
| Reverse sourcing | `check_conformance_sources.dart` | every PR |
| **Completeness (§2)** — Dart encoder only | `check_encoder_completeness.dart` | every PR |
| **Routed-but-undeclared std functions (#505)** — the REVERSE of completeness: every `std`/`std_collections` function `encoder.dart`'s `collectionRoutes` table routes to must be declared by `buildStdModule()`/`buildStdCollectionsModule()` | `dart/shared/test/std_routed_declarations_test.dart` (carries a positive floor so a regex that stops matching cannot pass vacuously) | every PR (`Dart`, `cd dart/shared && dart test`) |
| **Dispatched/keyed/executed-but-undeclared std functions (#702)** — the other half of the #505 PAIR, and the one that catches a consumer the `collectionRoutes` table cannot see. Three populations, each derived from its own source of truth with a positive floor: every base function the Dart engine's `StdModuleHandler` DISPATCHES (`_buildStdDispatch()` in `engine_std.dart`), every key of `buildCapabilityTable()`, and every `isBase` function an executed `tests/conformance/*.ball.json` fixture declares must be declared by a `buildStd*Module()` builder. Read the two rows together: #505 is `routed ⊆ declared`, #702 is `dispatched ∪ keyed ∪ executed ⊆ declared`, and #686's `capability_table_closed_set_test.dart` is `declared ⊆ keyed` — together they close the inventory in both directions. It found 30 undeclared functions (`std.map_create` in 29 fixtures, `std.typed_list` in 13, `std.switch_expr` in 8, …) plus 3 capability keys naming nothing at all | `dart/shared/test/std_reverse_closed_set_test.dart` | every PR (`Dart`, `cd dart/shared && dart test`) |
| **Declared-vs-read std FIELD names (#771)** — the next rung after #505 -> #686 -> #702, and the first that looks INSIDE a `TypeDefinition`. Those three (and the C#/Rust mirrors) compare function NAMES and at most an `outputType`; none reads `field[]`. So `_type('ListGenerateInput', [_exprField('len', 1), …])` passes every one of them while `engine_std.dart`'s `_stdListGenerate` reads `m['length'] ?? m['count'] ?? m['arg0']` and never sees a field spelled `len` — no crash, no diagnostic, a silently wrong value for every caller on every target. Two directions, each derived from PARSED engine/compiler source (never a hand-maintained expectation table, which would only prove two copies of one list agree): **A** — every field a std input type declares is read by name on the Dart handling path (engine `_buildStdDispatch()` entries + lazy `case 'fn':` arms + the compiler's `'fn' => …` base-call arms, expanded two members deep, unioned per input type because `BinaryInput`/`NumFormatInput` serve a family); **B** — every key an eager std handler reads is declared by a type of that module, named in BACKTICKS in that function's own description as an accepted alternative spelling (the convention `std.dart` already states), or part of the universal call convention (`self`, `arg0`…, `__…__` runtime markers). Comments are stripped first, so a dispatch entry whose COMMENT names `_evalCall` cannot drag that method's reads into the region. It found 3 dead declared fields no target reads (`ListReduceInput.initial`, `FormatTimestampInput.format`, `ParseTimestampInput.format` — the last two while the descriptions PROMISED a custom format string) and 19 undocumented alias reads | `dart/shared/test/std_field_signature_test.dart` (positive floors on every parse — member index, dispatch extraction, declaration derivation and read extraction — plus three NEGATIVE CONTROLS, one of them the #771 `len` example verbatim, so a check that stops firing fails instead of passing vacuously) | every PR (`Dart`, `cd dart/shared && dart test`) |
| **Encoder/compiler std-name consistency (§2)** — TS | `ts/compiler/test/std_name_consistency.test.ts` | every PR (`TypeScript`) |
| **Compiler-side dispatch completeness (§2, #488/#654)** — every base function the `dart/shared/lib/std*.dart` builders DECLARE must have a case in `dart/compiler/lib/compiler.dart`, and every per-module default arm must fail loud, so nothing can compile to a `/* unsupported: … */` comment | `dart/compiler/test/base_call_dispatch_completeness_test.dart` (population built in process from the builders, probed by compiling; positive floor >= 300) | every PR (`Dart`, `cd dart/compiler && dart test`) |
| **Interpreted ≡ compiled for the encoder-unreachable base functions (#654)** — a name no Dart source encodes to can have no `tests/conformance/src/*.dart` fixture, so the equivalent proof is one hand-authored Ball program run BOTH ways (reference engine, and `dart run` over the compiled Dart) against one expected transcript | `dart/compiler/test/declared_base_call_equivalence_test.dart` | every PR (`Dart`, `cd dart/compiler && dart test`) |
| **Compiled-back code type-checks under NON-DEFAULT analysis options (#488)** — the `async` safety return must be legal under `analyzer: language: strict-casts: true`, which `dart-lang/async`'s own `analysis_options.yaml` sets. No other gate in this repository runs `dart analyze` under anything but the defaults: Tier A and Tier B compile and RUN, never lint | `dart/compiler/test/strict_casts_safety_return_test.dart` — its silence-is-a-pass assertion is preceded by a NEGATIVE CONTROL that feeds the pre-fix line through the same helper and requires the diagnostic back, so a `dart analyze` that never ran cannot pass it vacuously | every PR (`Dart`, `cd dart/compiler && dart test`) |
| **The `async` safety return is measured by RUNNING it, at both instantiations (#766)** — whether a bare type-parameter result (`Future<T>`) may return `null` is decided by the CALLER's type argument, so the compiler cannot read it off the spelling; the throwing and returning shapes are indistinguishable by grepping the emitted source for a `throw` | `dart/compiler/test/generic_async_safety_return_test.dart` — compiles the Ball program, RUNS the emitted Dart at `T = int?` (must print `null`, exit 0) and at `T = int` (must still fail loud), behind an instrument control that proves the probe runner can tell the two apart and a positive floor on the marker the body prints | every PR (`Dart`, `cd dart/compiler && dart test`) |
| **Constructs are executed, not just named (§2b)** — TS | `ts/encoder/test/roundtrip.test.ts` | every PR (`TypeScript`) |
| **Self-hosted engine survives a compiler change** — TS | `ts/compiler/test/engine_runtime.test.ts` (regenerates `engine.ball.json` on demand; never skips) | every PR (`TypeScript`) |
| **The one COMMITTED compiled engine cannot go stale (§5)** | `Ball Artifact Freshness`'s `Assert compiled TS engine is up to date` (regenerates `ts/engine/src/compiled_engine.ts` and diffs) + `ts/engine/test/compiled_engine_parity.test.ts` (behavioural half) | every PR (`Ball Artifact Freshness`, `TypeScript`) |
| **EVERY committed generated artifact is regenerated and diffed, including the C++ one (#708)** — `cpp/shared/ball_protobuf_rt.h` is Ball's own `ball_protobuf` runtime compiled Ball → C++ in `--library` mode, it is linked into `ball_shared` via `ball_rt_decode.cpp`, and it carries a SPLICED COPY of the compiler's runtime preamble — so a preamble change leaves it stale. It was the one committed generated artifact no job regenerated, and it drifted for four months (frozen at #398 with the two-argument `ball_cast_assert` #659 replaced and none of #630's `sink` handling) | `ci.yml`'s `cpp` job (Linux leg): `Regenerate the committed ball_protobuf C++ runtime` (with a line-count floor measured at 9575, so a stubbed emit cannot pass the diff) + `Assert the committed ball_protobuf C++ runtime is up to date`. Its INPUT paths are gated too: `detect-changed-stacks`' `ball_protobuf_src` signal ORs `dart/ball_protobuf/lib/**` and `dart/shared/ball_protobuf.{json,bin}` into `cpp`, with truth-table rows both ways | every PR (`C++ (ubuntu-latest)`) |
| **No false coverage (§4)** | `check_fixture_names.dart` | every PR |
| **A base function's NO-MATCH branch is observed (§5b, #597)** — `std_collections.list_find` throws a catchable `StateError` when nothing matches, on every engine and every direct compiler; no target may answer `null`/`undefined`/an empty value, and none may refuse to compile it | `tests/conformance/463_list_find_no_match` (cross-target) + per-runtime tests: `dart/compiler/test/base_calls_test.dart`, `ts/engine/test/index_wrapper.test.ts`, `ts/compiler/test/std_call_dispatch.test.ts`, `cpp/test/test_compiler.cpp`, `csharp/compiler/test/ListFindContractTests.cs`, `rust/shared/src/runtime.rs`, `go/runtime/list_find_contract_test.go` + `go/compiler/list_find_contract_test.go`, `python/compiler/tests/test_conformance.py` | every PR (each language's own job) + every engine row of `conformance-matrix.yml` |
| **A base function's returned VALUE carries a contract (§5b, #630)** — `std.sink_create`'s sink is a `__type__`-tagged, REFERENCE-semantic value: `std.type_of` answers `Sink` on every target (never the host builder's type), and an append performed inside a callee is visible to the caller. A conformance golden cannot assert the tag (the oracle is native Dart, which says `StringBuffer`), so the behaviour and the tag are gated separately. Design record: `SINK_DESIGN.md` | `tests/conformance/466_string_sink` (cross-target; the `appendWord(out, 'c')` line is the reference-semantics leg) + per-target tag tests: `dart/engine/test/engine_test.dart`, `dart/compiler/test/base_calls_test.dart`, `ts/compiler/test/string_sink.test.ts`, `cpp/test/test_compiler.cpp`, `rust/shared/src/runtime.rs`, `csharp/shared/test/SinkContractTests.cs`, `go/runtime/sink_contract_test.go`, `python/compiler/tests/test_sink.py` | every PR (each language's own job) + every engine row of `conformance-matrix.yml` |
| **A declared base-function RETURN SHAPE is real (§5b, #545)** — every base function with a non-empty `outputType` is probed against the Dart reference engine; a declaration with no probe fails, and no universal `std`/`std_collections` declaration may sit in the frozen carve-out list | `dart/engine/test/std_output_type_contract_test.dart` (carries a positive floor so an empty inventory cannot pass vacuously) | every PR (`Dart`, `cd dart/engine && dart test`) |
| **A caught Dart error's STRING FORM is one answer, and each target's rendering table is CLOSED (§5b, #641)** — a caught failed cast reads Dart's own `type 'X' is not a subtype of type 'Y' in type cast` on every target (no `TypeError: ` prefix: `_TypeError.toString()` IS its message), and every Dart error name a runtime RAISES has a rendering entry in that runtime's table, with the prefix Dart spells | `tests/conformance/467_caught_type_error_to_string` (cross-target) + `tools/check_error_rendering_tables.py` (structural, all 7 targets, with positive floors) and its self-test `tools/test/test_check_error_rendering_tables.py` + per-runtime tests: `go/runtime/type_error_contract_test.go`, `go/compiler/type_error_contract_test.go`, `csharp/compiler/test/TypeErrorContractTests.cs`, `rust/shared/src/runtime.rs`, `python/compiler/tests/test_runtime.py` | every PR (`Proto Checks` for the checker + self-test; each language's own job for its unit test) + every engine row of `conformance-matrix.yml` |
| **A USER-thrown built-in Dart error reads the same on every target (§5b, #658)** — a caught `throw StateError('boom')` reads Dart's own `Bad state: boom` everywhere, INCLUDING the reference engine, while `.message` still reads the raw ctor argument; and every explicit rendering table covers every literal-throwable built-in (`ArgumentError` → `Invalid argument(s)`), raised or not | `tests/conformance/473_caught_user_thrown_builtin_error` (cross-target) + `tools/check_error_rendering_tables.py`'s `LITERAL_THROWABLE` check and its self-test + per-target tests: `dart/engine/test/user_thrown_builtin_error_test.dart`, `go/runtime/dart_error_rendering_test.go`, `go/compiler/user_thrown_builtin_error_test.go`, `csharp/compiler/test/UserThrownBuiltinErrorTests.cs`, `rust/shared/src/value.rs`, `python/compiler/tests/test_runtime.py` | every PR (`Proto Checks` for the checker + self-test; each language's own job for its unit test) + every engine row of `conformance-matrix.yml` |
| Engine/compiler behavior | `conformance_test.dart`, `conformance_compiler_inprocess_test.dart` | every PR |
| Real subprocess round-trip (engine, `dart run`, `node`, encoder-in-the-loop) | `conformance_roundtrip_test.dart` (`@Tags(['slow'])`; its `_knownUnroundtrippable` ratchet holds the one leg the Dart encoder provably cannot express, and fails if that leg starts passing or names nothing real) | `slow-conformance.yml`, weekly + manual only |
| C++ CI wall-clock budget (#521) | ci.yml's `cpp` job — step-level `timeout-minutes` on `Run tests` (20 Windows / 8 Linux+macOS, sized against the **cold**-ccache 13m57s / 5m19s / 4m57s and still under the pre-fix 28m33s / 12m12s / 9m56s) + a 25-min job budget | every cpp/infra-touching PR |
| C++ e2e fixture coverage is *visible*, not just asserted (#521) | ci.yml's `cpp` job — `test_e2e` writes `<build>/test/e2e_coverage.txt`, deleted before `ctest` and re-checked after (`expected == executed >= 1`); a passing CTest test prints nothing under `--output-on-failure` | every cpp PR, all 3 OS legs |
| **The C++ e2e fixture LIST cannot silently stop growing** (#63 / #511) | `cpp/test/check_e2e_fixture_list.sh` — every runnable fixture (a `.ball.json` with a sibling `.expected_output.txt`) must be in `cpp/test/e2e_fixture_list.h` or named in the frozen, ratchet-only `cpp/test/e2e_fixture_list_known_gaps.txt`; `--self-test` proves the guard bites | every PR (the always-on `proto` job, no toolchain) |
| **Implemented-but-undeclared base functions in the C++ compiler (#607)** — the C++ half of the #505/#702 declaration closure. `cpp/compiler/src/compiler.cpp` dispatches base functions by hardcoded `fn == "..."`, and nothing compared those names against the canonical builders, so `compile_concurrency_call` grew three (`thread_detach`, `unique_lock`, `atomic_fetch_add`) that no builder declares, no encoder can emit and no engine implements | `cpp/test/check_declared_base_functions.py` — every name a module-scoped `compile_*_call` implements must be declared for that module by `tests/conformance/std_coverage.json` (the ALL-module inventory) or be a still-live entry in the frozen, ratchet-only `cpp/test/declared_base_functions_known_gaps.txt`; a positive floor on the extracted name count is checked FIRST, and `--self-test` proves all six cases bite | every PR (the always-on `proto` job — BOTH inputs can move it, so a cpp-path-filtered job would let a declaration-only PR skip it; no toolchain) |
| **Dispatched-but-undeclared base functions in the Python compiler (#743)** — the Python half of the #505/#702/#607 declaration closure. `python/compiler/ball_compiler/compiler.py` dispatches base functions by hardcoded name (`fn == "x"`, `fn in TABLE`, `TABLE[fn]`), and nothing compared those names against the canonical builders, so the `str_1` string table grew a `string_from_char_codes` (plural) arm that no builder declares, no encoder emits and the Dart reference engine does not dispatch — unreachable in BOTH directions, so neither this suite nor the corpus nor `check_encoder_completeness.dart` could ever see it. #702's reverse closed set structurally cannot either: its three populations are the Dart engine's dispatch map, the capability table and the fixture corpus, and a name only the Python compiler mentions is in none of them | `python/compiler/tests/test_declared_base_functions.py` — AST-parses the compiler (a regex would miss the dict/set tables), DERIVES the dispatcher set from the source, and asserts four things: every dispatch site is mapped to a module or named as an exclusion (so a new dispatcher cannot appear unnoticed); every dispatched name is declared for a module that dispatcher serves by `tests/conformance/std_coverage.json` (the ALL-module inventory, pinned against `dart/shared/std.json` by a sibling test so a stale artifact cannot shrink it) or is a still-live entry in the frozen, ratchet-only `python/compiler/tests/declared_base_functions_known_gaps.txt`; that ratchet holds no stale entries; and a positive floor (150) plus a per-dispatcher non-empty check is evaluated FIRST. The fall-through dispatcher `base_expr` serves every universal module it does not delegate away, so its module set is derived from its own `mod == "..."` delegations. Ten negative controls prove each rule bites | every PR (the `python` job, `cd python/compiler && python -m pytest`) |
| The `full_e2e.sh` harness itself (worker dispatch, `xargs -P`, CWD isolation, corpus-ordered aggregation) (#521) | ci.yml's `cpp` job, Linux leg — ONE `full_e2e.sh` call over the PR's changed fixtures **plus** a derived four-fixture slice. One call, not two steps: the harness's positive floor (`passed == 0 && failed == 0` ⇒ exit 1) is per-invocation, so a PR whose every changed fixture is a tracked `CPP_COMPILE_CARVEOUTS` entry would otherwise run nothing and go red naming the wrong cause (#651/#695) | every PR (otherwise only the post-merge `C++ Compiled` leg ran it) |
| Cross-engine parity (§5) | `conformance-matrix.yml` (Dart/TS/C++/Rust/C#/Go/Python) | **every PR touching a filtered path** (#619) + push to main + weekly |
| Encoder-reads-back-the-compiler measurement (Ball → `<lang>` → Ball → **Dart** engine → golden) | `conformance-matrix.yml`'s `csharp-roundtrip` / `python-roundtrip` / `go-roundtrip` / `rust-roundtrip` rows (#452), all four through `tools/ci/roundtrip_floor.sh` (#642) | every PR touching a filtered path (#619) + push to main + weekly + dispatch — **floored and ratcheted since #642**: harness health (a parseable `Results:` line, integer counts, `total >= 1`) PLUS `passed >= 1` PLUS `passed >= <LANG>_ROUNDTRIP_FLOOR`. The four rows printed `0 passed` on every run for as long as they existed and went green every time; they are not parity gates (most of the corpus still does not round-trip anywhere), but a flat zero is now RED. Each row's floor moves only in the PR that earns it — the job prints the exact new value; e.g. `rust-roundtrip` went 0 → 68 (#642) → 99 (#693) → 109 (#692). A floor is on the PASSED count alone, never a ratio: the corpus grows under every row, so `109 of 358` and `109 of 360` are the same measurement two fixtures apart |
| **A Python re-encode that only the REFERENCE ENGINE can refute (#785)** — the fast Python round-trip guards (`python/encoder/tests/test_ballrt_inverse.py`, `test_ballrt_namespaced.py`) run the re-encoded fixture in-process under `ballrt` and compare to the golden. Python's runtime is tolerant where the reference engine is strict — `ballrt.getfield` answers `None` for an absent key (proto3-default tolerance) while the engine raises `BallRuntimeError: Field "…" not found` — so a re-encode that reads an absent key under the eager `std.null_coalesce` prints the golden there and DIES on the engine. The whole-corpus `python-roundtrip` row does use the engine, but it is a path-filtered floor/ratchet measurement, not a per-fixture gate on the suite that certifies those fixtures | `python/encoder/tests/test_reference_engine_roundtrip.py` — for every fixture those two suites certify (the set **derived from their own lists**, so a fixture added there is covered the same day) it runs the ORIGINAL `.ball.json` *and* the RE-ENCODED program on `dart run dart/cli/bin/ball.dart run` and asserts byte-identical stdout, with the fixture's own golden as the third leg so a failure names the guilty side. A negative control encodes two compiler-shaped programs `ballrt` cannot tell apart and the engine can, so the instrument is proven rather than trusted; a positive floor on the derivation stops an empty set from reading as green. No skip: an unresolvable `dart` FAILS (the #730/#764 precedent), which is why `ci.yml`'s `python` job sets Dart up BEFORE its test steps | every PR (the `python` job, `cd python/encoder && python -m pytest`) |
| **The round-trip floor itself bites** (#642) | `tools/test/test_roundtrip_floor.sh` — a flat zero is RED, a drop below the floor is RED, an empty or non-integer floor is a hard error rather than a `[` that exits 2 and gets SKIPPED inside an `if`, two `Results:` lines resolve to the last; plus the WIRING (all four rows actually invoke the script) | every PR (the always-on `proto` job, no toolchain) |
| **No round-trip fixture may HANG** (#693) | `tools/ci/roundtrip_floor.sh`'s timeout gate — any per-fixture timeout line reds the row, even one otherwise at or above its ratchet, because a program that does not terminate is the #55 class and a failure COUNT cannot tell it from a golden mismatch. Pinned by `tools/test/test_roundtrip_floor.sh` (a timeout is red; red even while the leg is IMPROVING; red under C#'s own `  <name>: TIMEOUT` pattern; and a fixture merely NAMED `196_timeout` is NOT a hang), plus the wiring assertion that a row overriding the fail pattern overrides the timeout pattern too — otherwise its gate would be switched off while the job stayed green | every PR (the always-on `proto` job, no toolchain) |
| **The per-fixture kill actually kills** (#693) | `rust/engine/tests/roundtrip_conformance.rs`'s `a_runaway_fixture_is_killed_at_the_budget_and_reported_as_a_timeout` — builds a fabricated runaway with `rustc` at test time (ignores its arguments, never exits), drives it through the real `run_dart` path, and asserts the `__timeout__` sentinel comes back inside the `BALL_TIMEOUT_MS` budget. The only non-`#[ignore]`d test in that target, so the whole-corpus sweep beside it never shares its process | every PR (the `rust` job's `cargo test --workspace`) |
| **§3a itself is enforced, not merely documented** (#705) | `tools/check_verdict_exit_status.py` — every `done < <(…)` under `tools/**/*.sh` + `cpp/test/*.sh` must be named in `tools/verdict_loop_carveouts.tsv` WITH the reason it is safe (anchored on the loop's producer, so a rewritten producer is re-justified). A stale entry, an ambiguous anchor, an empty reason, an undelimitable substitution and a scan that inspected zero loops are each an error. A reviewed LIST rather than an inference: a wrong answer in the permissive direction is the exact hole §3a exists to close. `tools/test/test_check_verdict_exit_status.py` drives 18 offline cases first — an uncarved offender, a carved one, a floored-but-uncarved one, the stale/ambiguous/empty-reason refusals, the multi-line shape, a `)` inside a multi-line quoted string (quote state must carry across lines or the producer handed back is not what runs), the undelimitable shape, the scanned scope in both directions, the zero-loops floor — and ends on the real tree as the positive control | every PR (the always-on `proto` job, stdlib-only) |
| Changed-stacks detection (decides which jobs above run at all) | `.github/actions/detect-changed-stacks` + its `test/truth_table.sh` | every PR (the truth table runs in the always-on `proto` job) |
| **The canonical std INVENTORY is a cross-stack input, and its consumers' gates must RUN on it** — `rust/shared/src/std_dart_parity.rs`, `csharp/shared/test/StdModuleBuilderTests.cs` and `python/encoder/tests/test_ballrt_inverse.py` each read `dart/shared/lib/std*.dart` / `dart/shared/std.json` off disk as their source of truth, and each exists to notice the DART side moving (#505, #545/#557). Mapped by top-level dir alone those paths set `dart` only, so the one commit that moves the inventory was the one commit on which those three jobs skipped — the drift then surfaces later on an unrelated PR in one of those stacks, misattributed. `detect-changed-stacks`' `std_inventory` signal ORs the std builders and `dart/shared/std.{json,bin}` into `rust`/`csharp`/`python`, the sibling of `ball_protobuf_src` above and just as narrow (ts/go/cpp reference these files only in prose — an exclusion that is ENFORCED since #774, see the next row). One truth-table row per builder — all eight, not a sample — plus `ball_proto` negative controls so it cannot widen into `^dart/shared/` | `.github/actions/detect-changed-stacks/test/truth_table.sh` | every PR (the always-on `proto` job, no toolchain) |
| **That signal's match set is DERIVED from source, and its ts/go/cpp exclusion is enforced** (#774) — the signal used to be a hand-written SHAPE regex (`std(_[a-z_]+)?\.dart`) plus a hand-reasoned exclusion checked once, by grep, at review time. Both are closed-set assumptions about source that the truth table structurally cannot re-check: it drives the classifier with synthetic inputs for files that ALREADY exist, so a ninth builder named outside that shape never trips the signal (and rust/csharp/python then run their parity gates against a stale inventory), and a new off-disk reader in ts/, go/ or cpp/ never joins the OR-list. Same failure shape as #719 and #708 | `tools/ci/check_std_inventory_signal.sh` — three derived invariants. (1) The builder set comes from the `Module buildStd*Module(` DECLARATIONS under `dart/shared/lib/` (cross-checked against `ball_base.dart`'s re-exports) and the artifact names from `gen_std.dart`'s own `$outputDir/<file>` writes; the resulting pattern must equal the GENERATED, marker-delimited block in `detect.sh` (`--write` regenerates it), so a builder added under ANY filename is drift. (2) Every stack NOT already ORing `std_inventory` — the stack set and the OR-list both scraped from `detect.sh`, never a second table — is scanned over `git ls-files` for a CODE reference to the inventory; adding a stack to the OR-list removes it from the scan automatically. (3) Every derived path is run through the REAL classifier and must come back `rust=true csharp=true python=true`, with non-builder `dart/shared/lib` siblings as the negative control, because (1) and (2) are static and would both pass if the signal were computed and read by nobody. `--min-builders` is the MEASURED count (8); zero builders, zero scanned files, zero checked paths and zero negative controls are hard errors. `--self-test` drives 15 cases | every PR (the always-on `proto` job, no toolchain) |
| **The matrix's two triggers cannot drift apart** (#619) | `tools/ci/check_matrix_paths.sh` — `on.push.paths` and `on.pull_request.paths` compared after the YAML parser expands the `*matrix_paths` alias; a path in one trigger only un-gates exactly the PRs that touch it, and an absent check reads as green. `--self-test` proves the guard bites (anchor form, identical copies, a dropped path, a reordered copy, a missing trigger, an empty filter, unparseable YAML) | every PR (the always-on `proto` job, no toolchain) |
| **Every path in that filter maps onto a row signal** (#666) | the same `tools/ci/check_matrix_paths.sh` — for each filter entry it synthesizes a matching path, runs the real `detect-changed-stacks` classifier over it, and fails unless a signal some row's `if:` reads comes back true (signal set scraped from the workflow, so there is no second table). Without it a filter entry that maps to nothing starts the workflow with every row skipped — a green matrix that ran nothing. `--self-test` drives the negative control (`proto/**` added ⇒ RED) | every PR (the always-on `proto` job, no toolchain) |
| **The matrix summary cannot report green on a run that executed nothing** (#666) | `conformance-matrix.yml`'s `Parity Matrix` — on a `pull_request`, ZERO executed engine rows is a hard failure (push/schedule/dispatch are exempt: their rows are unconditional). `tools/test/test_parity_matrix_floor.py` renders that step out of the workflow and runs it under bash across 11 scenarios, with a negative control that strips the floor and asserts the same all-skipped run goes green | every PR (the always-on `proto` job) + every matrix run |
| **A language's matrix rows run whole, or not at all** (#687/#725 review) | `conformance-matrix.yml`'s `Parity Matrix` — a group whose rows ran PARTIALLY (e.g. `rust-engine` executed, `rust-roundtrip` skipped) is a hard failure on every event. The zero-row floor above cannot see it: one engine row ran, `skipped` is benign, and the skipped row's ratcheted floor was never evaluated. `tools/test/test_parity_matrix_floor.py` drives the partial group (RED), its negative control (block stripped ⇒ the same run GREEN), a partial group on `push`, and a structural check that the group table covers every job in the workflow's own `jobs:`, and a second one proving the strip removes helper AND calls (under `set -uo pipefail` a leftover call exits 0, so the control would otherwise pass for the wrong reason) | every PR (the always-on `proto` job) + every matrix run |
| **The CI-produced regeneration is applicable** (#619) | `tools/ci/apply_regenerated.sh --self-test` — apply + stage, byte-exact LF, the empty-artifact floor, the path-traversal refusal, and the head-SHA equality guard. The script only ever runs on a RED freshness run, which is exactly when it must not be broken | every PR (the always-on `proto` job, offline) |
| **The regeneration flow is gated per artifact family, and the family set is DERIVED** (#625/#655) | `tools/ci/check_ci_regen_wiring.sh` — parses `ball-freshness`, derives every family from the `git diff --exit-code` predicate (floored against the six that exist today), and asserts each derived id is in all three `if:` gates AND owns a pathspec block in the collect table that adds a path; plus the loop-breaker call, well-formed `${{ }}`, and no `continue-on-error`/`\|\| true`. `--self-test` drives 21 cases, including a fabricated seventh family broken in each of the four places | every PR (the always-on `proto` job, offline) |
| **The documented required-status-check list is the LIVE one** (#655) | `tools/ci/check_required_contexts.sh` — the `REQUIRED-CONTEXTS`-marked list in this doc vs. `GET /repos/Ball-Lang/ball/rulesets/17056238`, failing on any difference in either direction, plus the prose counts, sort order, a non-enforcing ruleset and one requiring zero checks; `tools/test/test_check_required_contexts.sh` drives 17 offline negative controls first | every PR (the always-on `proto` job) |
| **The published JSON Schema MIRRORS the proto, field for field** (#609) | `tools/check_proto_schema_drift.py` — `ball.schema.json` is the Draft 2020-12 mirror `docs/BALL_JSON_SPEC.md` points JSON-only implementers at, and every `$defs` object sets `additionalProperties: false`, so a proto field added without the matching schema edit does not merely go undocumented: the repo's own schema REJECTS the JSON this repo emits (`CallSite.resolved_module` did exactly that to `ball audit --output`). The checker parses `proto/ball/v1/ball.proto` with a deliberately STRICT reader (any line in a message/enum body that is not a comment, a field, a `oneof` or a brace is a hard error — never a silently skipped field) and asserts every message, field and enum value has the matching `$defs` entry of the matching JSON shape (`repeated` → `array`/`items`, `map<string,V>` → `object`/`additionalProperties`, `int64` → `$defs/Int64String`, …). The schema may be STRICTER than the proto (`ModuleImport.integrity` adds a `pattern`); it may never contradict or omit. Measured positive floors (34 messages / 153 fields / 2 enums) make "the reader found nothing" exit 2 rather than pass. `tools/test/test_check_proto_schema_drift.py` drives 11 offline cases first, including this defect from BOTH directions and three fake-green controls (unreadable proto line, below-floor proto, missing schema file). The corpus half — `scripts/validate_ball_schema.py`, every `.ball.json` against the schema — is a LOCAL check (it needs `pip install jsonschema`; the always-on job is deliberately hermetic and the `python` job that has pip is path-filtered to `python/**`), and it is structurally blind to this axis anyway: no corpus file is a `BallCapabilityReport`, a `BallManifest` or a `BallLockfile` | every PR (the always-on `Proto Checks` job, stdlib-only) |
| **The Go module release lane stays machine-driven, and its own YAML-parsing leg cannot be silently disabled** (#361/#656/#694) | `tools/release/check_go_release_wiring.sh` — 27 legs over the lane's shape (one semantic-release config, the commit carrying every file the bump rewrites, `tag_go_modules.sh` as the single tagging path, no silent v2), of which the go-freshness `pull_request.paths` leg parses YAML rather than grepping because the claim is that a LIST IS EXACTLY A SET. `--self-test` drives 11 cases: 9 on the checker's verdicts (widened, narrowed, unfiltered, `paths-ignore`, no PR trigger, unparseable) and 2 on the **leg**, which run the whole guard with and without a `python3` that works — the §3a control, added after the leg was found reporting PASS with the checker unable to run | every PR (the always-on `proto` job, offline) |
| **The committed TS self-hosted engine is DERIVED, not trusted** (#517) | ci.yml's `typescript` job — regenerate `ts/engine/src/compiled_engine.ts` from `dart/self_host/engine.ball.json` through the current `@ball-lang/compiler`, then `git diff --exit-code`. It is the only committed compiled engine (Rust/Go/C#/Python gitignore theirs and regenerate unconditionally, so they cannot go stale); `npm run build`/`npm run coverage` consume it as an INPUT and stay green on any drift that is behaviour-neutral for the TS suite | every dart/ts/infra-touching PR (`TypeScript`) |
| **A network command survives a flaky index** (#520) | `.github/actions/dart-pub-get` (bounded retry, loud on exhaustion) + `test/test_dart_pub_get_wiring.sh` — asserts every `dart pub get` in ci.yml routes through it, with a positive invocation-site floor, and drives the retry against stub `dart` binaries | every PR (the wiring test runs in the always-on `proto` job) |
| **The nine docs that state an engine verdict cannot drift from the matrix** (#610/#613/#709/#765) | `tools/ci/check_engine_row_docs.sh` — derives the engine languages from the **parity table** `conformance-matrix.yml`'s `summary` job prints (its `print_row` calls, which is where a new engine is declared a full-parity row, and which excludes the ratcheted compiler / measurement round-trip legs by construction; a parity row reporting a job outside `summary.needs` is a hard error, because such a row can never fail the matrix), then asks every doc the same two questions in whatever unit that doc uses. **Table docs** (`tests/editions/portability_matrix.md`'s `## Engines`, `plugins/ball/skills/embed/SKILL.md`'s `## Per-target honest status`): one data row per derived engine, a row naming each of them, and no row claiming a parity-table engine cannot execute a program; the portability doc may additionally freeze no fixture or engine tally. **Section doc** (`plugins/ball/skills/embed/references/embedding-per-target.md`, #709): a `## <Language>` section, carrying prose, per derived engine, none of them claiming it cannot execute — that file is where the retired "C# — not embeddable yet" verdict lived. **Prose docs** (#765: `CLAUDE.md`, `tests/AGENTS.md`, `dart/encoder/AGENTS.md`, `dart/self_host/AGENTS.md`, `docs/SELF_HOST_STATUS.md`, `dart/ball_protobuf/README.md` — the six PR #652 hand-corrected for the same stale claim and then left ungated): no frozen engine tally and no exhaustive enumeration that omits a derived language, and no SENTENCE of the UNFOLDED paragraph naming a derived language that claims it cannot run a program — the sentence, not the physical line, because five of the six wrap at ~95 columns and a hard wrap is a typesetting artifact, not a claim boundary (a line-sized unit read `A binary installed from the old Go module tags` / `cannot run a program at all.` as a clean pass); the physical line is judged as well, as a strict addition. The DISCLOSED limit of that unit: a verdict whose subject is only a pronoun in an adjacent sentence stays out of reach, and widening to the whole paragraph to reach it would fire on CLAUDE.md's true "...cannot run a program; Go tags are immutable..." clause pair (about a stale module tag, not the Go engine) — `swept_wrapped_ok` is the negative control pinning both boundaries. A PARTIAL enumeration with no exhaustiveness marker ("the TS/C#/Go/Python engine regeneration commands") is deliberately out of scope and ships as a negative control. The verdict test is a NEGATION × EXECUTION vocabulary, never a phrase allowlist (#765) — the five hand-picked strings it shipped with read "the engine is non-functional" and "still cannot produce output" as clean passes; narrowness lives on the other axis instead, so "Trusted only", "no public constructor", "no NuGet package yet" and "does not compile for Flutter web" all keep passing and each ships in a clean fixture. Matching is scoped to each doc's smallest claim-bearing unit — row, section, line — never the whole file: a whole-file name scan is a fake green, since an engine's name survives in prose long after its row is gone. `--self-test` drives 34 cases first and must report EXACTLY that many (the last of those 34 reads this row back and fails unless it states the same number, so a case added without updating this sentence reds — a frozen tally in the row documenting the anti-frozen-tally guard is what this PR itself shipped between commits 2 and 3), each asserting the failure MESSAGE as well as the exit code — including the mutation #709 names (an 8th engine row added to the workflow against otherwise-clean docs, which must red the per-target doc alongside the two tables), both #765 wordings of #613's verdict, and the two positive floors that gating zero swept docs or a swept doc that is not there must fail loud | every PR (the always-on `proto` job, offline) |
| **The conformance total quoted in the docs is the real one** (#519) | `tools/check_conformance_doc_counts.sh` — derives N from the fixtures that have a golden and fails on any `N passed, 0 failed, N total` in a tracked `.md`/`.yml` that disagrees (so "all the docs agree on the wrong number" still fails); `tools/test/test_check_conformance_doc_counts.sh` pins the guard itself | every PR (both run in the always-on `proto` job — deliberately NOT in `ball-freshness`, which a rust/AGENTS.md-only PR would skip) |
| **Third-party code (§2c)** — Tier A, Dart/Rust/C#/Go/Python/TS + Tier B (Dart) | `coverage-study.yml`'s seven measuring jobs | weekly + manual — **NOT a PR gate** (issue #493). Each job fails on a run that scored < 1 file: a harness/checkout failure, never a 0% result — and, for Tier A, on a log missing its `excluded (test-only): N` line, which would mean the library-code-only rule vanished (issue #491) |
| **Third-party numbers do not slide back, and are published** (#493) | `coverage-study.yml`'s `publish` job — `tools/coverage-study/coverage_table.py` floors all eight rows against `tools/coverage-study/baseline.json` (clean ratio, EVERY funnel stage's ratio — stage 3 `reencoded` by name since #632, because it is the only stage whose INPUT is this repo's own output, so a construct a compiler emits that its own encoder refuses stops there and nowhere else, which is what `rust/compiler`'s `panic!` dispatcher arm did while a stage-1-only floor stayed green — and the scored denominator; a missing or zero-scored report is a hard failure, never a 0% pass), raises the baseline on an improvement, diffs the per-file exclusion list in `tools/coverage-study/excluded.json` and fails naming any file that list excludes and the run scored (#676), and regenerates the README table, committing all three to main with `[skip ci]` | weekly + manual, after the seven jobs above (`if: always()`, so a broken upstream job is a loud red rather than a skipped — i.e. green-looking — check) |
| Each coverage-study harness's own correctness | `tools/coverage-study/test/rq1_study_self_test.dart` (Dart), `cargo test -p ball-rq1-study` (Rust), `csharp/coverage-study/test` (C#), `go test ./...` in `tools/coverage-study/go` (Go), `tools/coverage-study/test/rq1_study_py_self_test.py` (Python), `tools/coverage-study/test/rq1_study_ts_self_test.mts` (TypeScript), `tools/coverage-study/test/rq1_tierb_self_test.dart` (Tier B) | every PR (the matching language job) |
| The coverage-table renderer and its ratchet floors | `tools/coverage-study/test/coverage_table_self_test.py` — below fails and names both numbers, at passes, above raises, a missing artifact fails loud, a non-integer tally fails, a shrunk denominator fails even with a better ratio, and regenerating twice is byte-identical. Since #632 also: a stage-3 drop fails (on a fixture holding `scored`, `clean` and stage 1 fixed, so it can only be failing on that stage), a stage-3 gain raises and names it, a Tier A row missing any stage key fails loud rather than defaulting it, a Tier B row carrying one fails loud, and a non-monotone baseline funnel is rejected | every PR (`Python`) |
| **Line coverage ratchet (Dart)** | ci.yml's `Dart Coverage Ratchet` job — `tools/coverage_dart.dart --floor 99.9` over all 9 packages (#605) | **every PR**, always-on (no path filter) |
| Line coverage ratchet (Rust/C#) + the Dart push-to-main measurement | `coverage.yml`'s `dart`/`rust`/`csharp` jobs | push to main + manual — **NOT a PR gate** |
| Line coverage ratchet (C++), aggregate **and** per-target | `coverage.yml`'s `cpp` job — the `C++ line coverage floor` and `C++ per-target coverage floors (compiler/encoder/shared — gated)` steps, the latter taking `cpp/build-cov-floor.sh`'s exit code | push to main + manual, **plus cpp-touching PRs** (#63) — reports, does not block (not a required check) |
| **The Codecov upload cannot red a green measurement** (#638) | `tools/ci/check_coverage_upload_isolation.sh` — measurement and transport in different jobs, the uploaded flag set equal to the measured artifact set, nothing masking a floor verdict, a bounded-retry OIDC token fetch, `fail_ci_if_error: true`, and neither a `continue-on-error` key nor a short-circuiting `true` guarding the upload path. Floor-step count set AT the measured 5 across 4 measurement jobs, with the one-rename mutation as a case (#700). 21-case self-test with two positive controls | every PR (the always-on `proto` job, no toolchain) |
| **The artifact an outside consumer gets, not the checkout** — Go modules (#361) | `tools/go-module-proxy/smoke.sh` (synthesized `file://` proxy; every module builds standalone with no `go.work`/siblings, then `go install .../go/cli/cmd/ball@vX.Y.Z` into a clean GOPATH and runs) | every PR (`Go`) |
| **The artifact an outside consumer gets, not the checkout** — Python wheel (#496) | `python/tool/wheel_smoke.py` (`python -m build python/`, install into a venv OUTSIDE the repo with no `PYTHONPATH`, run `--version`/`check`/`compile`/`encode`/`run`, `run` diffed against a golden as BYTES) | every PR (`Python`) |
| Compile-on-first-use engine bootstrap (what a pip-installed wheel actually runs) | `python/engine/tests/test_bootstrap.py` (cache hit/miss/invalidation, failure modes, and a conformance fixture through the cache-compiled engine vs. its golden) | every PR (`Python`, with `BALL_REQUIRE_SELFHOST_SOURCE=1` so it cannot silently skip) |
| vcpkg port recipe builds (#368) | ci.yml's `vcpkg` job — generated overlay of the real port, `vcpkg install ball-lang --triplet x64-linux`, installed binary runs | cpp/tools-touching PRs — new infrastructure, not a regression gate (the port had never been built once) |
| **The artifact an outside consumer gets, not the checkout** — vcpkg `ball`'s SELF-HOSTED verbs (#368/#361) | ci.yml's `vcpkg` job — pre-generate `dart/self_host/lib/{cli_rt.h,engine_rt.cpp}` with a real Dart toolchain, tar them as the release asset the portfile downloads, **delete them from the checkout**, then assert the vcpkg-INSTALLED `ball run` against the conformance golden and `ball info` against the Dart-native `cli_core` parity golden. `ball version` alone cannot see this: `BALL_CLI_VERSION` is compiled in unconditionally, so it passes identically in a fully-stubbed build | cpp/tools-touching PRs (`vcpkg port smoke (x64-linux)`) |
| The self-host sidecar's four-file wiring cannot drift (#368/#361) | `tools/vcpkg-port/test/test_selfhost_asset_wiring.sh` — pins the release-asset name against the portfile's `FILENAME`, that the overlay generator swaps **both** network fetches and emits a hermetic overlay (and fails loudly on an unswapped one), that the sidecar is an opt-out-able default feature, that the vcpkg job deletes its pre-generated copies before installing, and — since the port was first built against a real tag — that **neither `SHA512` is the `0` placeholder** and that every literal `vX.Y.Z` in `portfile.cmake` matches `vcpkg.json`'s `version-semver` (the version drives both download URLs, so bumping it without recomputing both hashes ships a port that fails for every consumer) | every PR (runs in the always-on `proto` job) |
| The port installs from a REAL release, not only from a generated overlay (#368) | Manual, recorded in `tools/vcpkg-port/README.md` — `vcpkg install ball-lang` / `ball-lang[core]` against the published `v1.64.0` tag and its `ball-selfhost-cpp-src` asset, then `ball version` / `run` (vs. the conformance golden) / `info` on the installed binary. The CI smoke deliberately replaces both network fetches, so it can never exercise the `REF`/`SHA512` pair or the asset URL | on each port version bump — the always-run test above is what keeps the *result* from silently regressing between bumps |
