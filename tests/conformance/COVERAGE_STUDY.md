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

Tier A exists for six languages. The Dart harness is the reference; the five
ports mirror its five stages exactly (see "The five ports" below).

### Dart — `tools/coverage-study/rq1_study.dart`

For every `.dart` file in the pinned packages' `lib/` trees:

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

### The funnel

Every harness prints a per-stage funnel next to the clean percentage:

```
Funnel (scored files that survived each stage):
  1 encoded: 74/472
  2 compiled back: 73/472
  3 re-encoded: 58/472
  4 declarations kept: 0/472
  5 fixpoint (clean): 0/472
```

It is derived from each file's taxonomy tag, and an **unrecognised tag is an
error, not a default** — a new failure mode cannot be quietly folded into the
wrong row. The funnel is load-bearing for the ports, four of which score 0% clean: without it, "the encoder rejected every file outright" (Rust, Go) and "58
of 472 files reached the declaration diff" (C#) are the same 0%.

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

## The five ports — Rust, C#, Go, Python, TypeScript

| Language | Harness | Stage 1 (encode) | Stage 2 (compile back) | Inventory parser |
| --- | --- | --- | --- | --- |
| Dart | `tools/coverage-study/rq1_study.dart` | `DartEncoder.encode` | `DartCompiler.compileModule` per module | `analyzer` |
| Rust | `rust/tools/rq1-study` (`cargo run -p ball-rq1-study`) | `ball_lang_encoder::encode_library` | `Compiler::compile_library` | `syn::parse_file` |
| C# | `csharp/coverage-study` | `CSharpEncoder.EncodeLibrary` | `CSharpCompiler.Compile` | Roslyn `CSharpSyntaxWalker` |
| Go | `tools/coverage-study/go` | `encoder.EncodeLibrary` / `encoder.Encode` (below) | `compiler.CompileLibrary` | `go/parser` + `go/ast` |
| Python | `tools/coverage-study/rq1_study_py.py` | `ball_encoder.encode` | `ball_compiler.compile_library` | stdlib `ast` |
| TypeScript | `tools/coverage-study/rq1_study_ts.mts` | `@ball-lang/encoder`'s `encode` (`strictBehaviorAffecting`, below) | `@ball-lang/compiler`'s `compileLibrary` | raw TypeScript Compiler API |

**Every inventory column is a parser, never that language's encoder.** The
harness walks the source with the language's own parser so a bug in the
encoder's bookkeeping cannot hide a lost declaration from the instrument
measuring it.

### TypeScript needed a new compiler primitive first (#536)

TypeScript was the last port, and it was genuinely blocked rather than merely
unstarted. Neither of `ts/compiler`'s two pre-existing entry points could be
pointed at a real library file:

* `compile(program)` looks the entry function up **by name** and unconditionally
  appends a zero-arg `main();`. `@ball-lang/encoder` defaults `entryFunction` to
  `"main"` for every file it encodes, so a library that happens to declare
  `main(argv: string[])` gets a wrong-arity call appended, and `argv.length`
  throws at run time.
* `compileModule(module, options?)` takes a single `Module` **facade** and is
  purpose-built for the `ball_protobuf` inline-embedding case: it expands
  `moduleImports[].inline.json` sub-modules, synthesizes a dummy
  `__ball_lib_entry__`/`__ball_lib_main__` pair, and strips it again with
  non-global regexes matched against the compiler's formatted output text.

`compileLibrary(program, options?)` (#536) is the missing analog of Dart's
`compileModule(moduleName)` and of `compile_library`/`CompileLibrary` in
Rust/Go/Python: it takes the whole already-loaded `Program`, never looks up or
invokes `entryFunction`, does not require an entry module to exist, exports every
top-level declaration **structurally** through ts-morph rather than by rewriting
emitted text, and emits none of `compile()`'s engine-specific post-processing
(which would otherwise inject declarations the source never had and make a
fixpoint impossible). `ts/compiler/test/compile_library.test.ts` pins all of it.

### The load-bearing setting every port inherits, and the one TypeScript adds

The ports inherit the Dart harness's "never reach for the entry-point-requiring
API" rule: Rust uses `encode_library`/`compile_library` (issue #491), C# uses
`EncodeLibrary` (issue #492) with `Compile`, which already emits `Main` only
when the entry function exists, Python uses `compile_library`, and TypeScript
uses `compileLibrary` (issue #536), which had to be built first.

**Go now matches them.** It used to be the one exception: `go/encoder` had no
library mode, so `Encode` failed loud with "a Ball Program requires a `func
main()` entry point" on every entry-point-less file — i.e. every real library
file — and the Go harness appended an **empty `func main() {}`** before encoding
rather than score them all as one blanket `encode-error` (which would have
measured the missing library mode, not construct coverage). Issue #537 added
`encoder.EncodeLibrary` and `ball encode -lib`, so that accommodation is gone:
the harness dispatches to `EncodeLibrary` when the parsed file declares no
top-level `func main` and to `Encode` when it does, and synthesizes nothing.
`TestEntryPointLessFilesAreEncodedThroughLibraryMode` pins that. A real `func
main` is still excluded from the declaration inventory on both sides, for the
separate reason that library-mode compilation deliberately renames it to
`ball_main`.

**TypeScript adds one accommodation.** Every sibling encoder throws on a
construct it cannot represent, so its harness gets an honest `encode-error`
for free. `@ball-lang/encoder` does not: by default it records a warning and
emits an "unhandled" placeholder literal, which changes what the program
computes while still producing a `Program` the funnel would happily carry all
the way to `clean`. The TS harness therefore encodes with the encoder's own
`strictBehaviorAffecting: true`, which turns a behaviour-changing loss into a
hard `EncodeError` while still tolerating the erasure-only ones
(`TypeAliasDeclaration`, `InterfaceDeclaration`, `EmptyStatement`). Those are
not swept under the rug either: the declaration inventory counts an erased
`type`/`interface` as a lost declaration, so they surface at stage 4 instead.
An encoder that failed loud by default would remove the need for the setting.

### What every port's self-test asserts, and what it deliberately does not

Each port carries a self-test gated in that language's `ci.yml` job. They assert
the harness cannot inherit the blind spot it exists to close:

1. entry-point-less files are **scored**, never silently skipped, and the scored
   denominator is >= 1;
2. a plain library file survives **at least** encode and compile-back (the
   funnel is real, not a blanket stage-1 failure);
3. every verdict carries a taxonomy tag the funnel recognises;
4. a construct the encoder explicitly rejects is scored, not clean, tagged
   `encode-error`, and stops **strictly earlier** in the funnel than the plain
   file — so the harness cannot pass by painting every file with one reason;
5. the declaration-inventory walker sees type members and actually **misses** a
   removed declaration, so stage 4 is not a rubber stamp.

The TypeScript self-test adds three more, for hazards specific to this port: a
library declaration NAMED like the entry point (`main(argv)`) is scored rather
than crashed on or handed a synthesized invocation (#536); an unrecognised
taxonomy tag makes the funnel throw instead of quietly scoring 0; and the
stage-4 syntax gate rejects deliberately broken output — TypeScript's parser is
error-tolerant, so without an explicit `getSyntacticDiagnostics` check an
emitter producing unparseable TypeScript would sail through the whole funnel.

Assertion 2 is where the ports differ from the Dart original, which asserts a
plain file is reported **clean**. That works for Dart because its round trip is
closed — the Dart compiler emits idiomatic Dart the Dart encoder reads back. It
is not true for the five ports: their compilers emit source shapes their
syntactic encoders were never built to consume — runtime calls
(`ball_lang_shared::runtime::*`, `BallRuntime.*`, `ballrt.*`, `try/except`
wrappers) in four of them, and in TypeScript a re-emitted `const input =
<param>;` alias that makes generation 2 differ from generation 1. There is
therefore no source in those languages this harness can honestly *promise* stays
clean, and asserting one would mean weakening the harness until something
passed. Assertion 2 states the strongest thing that is true today, and
strengthens by itself the moment the round trip closes.

These self-tests validate the **harness**. They are not regression tests for
#488/#489/#491/#492: the Tier A run is report-only, so a pipeline regression it
measures reddens no PR.

### First baselines (2026-09-03; TypeScript 2026-09-05)

Honest first numbers. They are not cherry-picked: the pin lists are ordinary
hermetic libraries chosen before any number was seen, and no pin was dropped
after measuring.

| Language | scored | clean | 1 encoded | 2 compiled | 3 re-encoded | 4 decls kept |
| --- | --- | --- | --- | --- | --- | --- |
| Dart | 106 | 65 (61%) | 106 | 106 | 106 | 106 |
| C# | 472 | 0 (0%) | 74 | 73 | 58 | 0 |
| Python | 73 | 0 (0%) | 5 | 5 | 0 | 0 |
| Rust | 110 | 0 (0%) | 0 | 0 | 0 | 0 |
| Go | 21 | 0 (0%) | 0 | 0 | 0 | 0 |
| TypeScript | 48 | 4 (8%) | 29 | 28 | 21 | 16 |

Read these as a map of where each pipeline stops on real code, not as a grade:

* **Rust and Go stop at stage 1.** Every scored file is an `encode-error`; the
  encoders' documented gaps (item-level `const`/`static`/`type`, unmapped
  macros like Rust's `write!`, methods with receivers, top-level `var`/`type`
  declarations) are present in essentially every real library file. Rust's
  tuple/unit-struct gap closed under #491 without moving this table's Rust row
  by a single file: all 14 files it had first-blocked simply landed on their
  *next* independent gap. **Expect that of any single closed category here** —
  a real crate file stacks several, and this instrument reports only the first
  one it hits.
* **C# gets furthest.** 74 of 472 files encode and 58 survive a re-encode, and
  the wall is stage 4 — `declaration-drift`, i.e. the round trip keeps the file
  parseable but loses declarations.
* **Python's wall is stage 3.** Files that encode compile back fine, but the
  emitted `try/except` + `ballrt.*` shapes are outside the encoder's surface.
* **TypeScript is the only port with a non-zero number**, and its wall is
  spread across the whole funnel rather than piled on one stage: 19
  `encode-error` (regex flags, `.slice`/`.indexOf` receiver ambiguity,
  `yield`, `,`-operator), 7 `reencode-error`, 5 `declaration-drift` (every
  `interface` is erased), 10 `fixpoint-drift` and 2 `fixpoint-error`. The
  dominant fixpoint cause is that the compiler re-emits its own
  `const input = <param>;` alias on each generation, so generation 2 of even a
  one-line function differs from generation 1.
* **Dart is the only closed round trip**, which is exactly why its number is a
  percentage worth floor-checking later and the others are a funnel worth
  watching.

This corroborates, on third-party code, what the `csharp-roundtrip` /
`go-roundtrip` / `python-roundtrip` / `rust-roundtrip` rows in
`conformance-matrix.yml` already report as an honest 0/32x on the project's
**own** corpus. Tier A is the independent, third-party-code confirmation that
the encoders cannot read back their own compilers' output.

## Tier B — substitution into a package's own test suite (Dart)

Tier A is structural, and it says so: a construct that round-trips syntactically
clean but changes what the program computes scores `clean`. Tier B is the
instrument that sees that class. For each of the same five hermetic pins, it
swaps a library file for the pipeline's own compiled-back version and runs **that
package's own `dart test`**, comparing against a baseline run of the untouched
checkout. A construct that changes behaviour shows up as a test that stops
passing.

Two harnesses, two questions, meant to be read together:

* `tools/coverage-study/rq1_tierb.dart` — **per-file isolation.** One
  substitution at a time; the original bytes go back before the next file, so
  runs never compound. Answers "can this one file survive the round trip?"
* `tools/coverage-study/rq1_tierb_all.dart` — **whole-package.** Every eligible
  file substituted at once, no restore in between, one `dart test`, one verdict
  per package. The stricter signal: a pipeline can be right on most files and
  still not produce a working library, because `clean` compounds
  multiplicatively.

### The taxonomy is the point

Mirrors Tier A's `encode-error`/`fixpoint-drift`/`skipped` split.

| tag | meaning | scored? |
| --- | --- | --- |
| `clean` | substituted, the suite still passes exactly as it did | yes |
| `behavioral-drift` | substituted, the suite regressed | yes |
| `not-compiled` | never reached Tier A stage 2 — nothing to substitute | no |
| `test-timeout` | the substituted suite did not finish inside the bound | no |
| `baseline-unstable` | the package's UNMODIFIED suite is not a usable yardstick | no |

`test-timeout` and `baseline-unstable` stay **out** of the drift count rather
than folded into it. A flaky or network-touching third-party suite would
otherwise manufacture drift one file at a time and charge it to the encoder —
the same rule Tier A applies to an unreachable pin. `not-compiled` is excluded
because it is already a Tier A finding; counting it here would double-count one
defect across two tiers. A package is `baseline-unstable` when `dart pub get`
fails, it has no tests, it does not pass 100%, **or two consecutive runs of the
untouched checkout disagree** — a yardstick has to be reproducible, not merely
green once.

### Load-bearing settings — do not "simplify" these away

* **`dart test --reporter=json`, not the human `+N -M` line.** A suite that
  fails to *compile* prints no tally at all, and scraping the human output
  would score that as "0 failures" — silently turning the loudest possible
  failure into a pass.
* **`dart test --concurrency=1`.** This is a correctness knob, not a
  performance one. `dart test` runs VM suites as isolates inside one process, so
  a suite that mutates process-global state makes an *unrelated* suite flaky.
  dart-lang/path — a pin this study measures — sets `io.Directory.current` in
  `test/io_test.dart`, and path equality reads it. Run unserialized, the harness
  reported `503 → 502 passing, 1 failing` for `src/path_exception.dart`,
  `src/utils.dart` and `src/path_map.dart`, every failure a `path_map`/`path_set`
  equality test ("considers unequal two distinct paths"): six invented encoder
  regressions, charged to files that cannot affect path equality at all. With
  `--concurrency=1` those same six files score `clean` and only the four genuine
  drifts remain. A measuring instrument that manufactures its own findings is
  worse than no instrument.
* **Per-module `compileModule` and format-before-use** — the same two settings
  Tier A documents above, for the same reasons.

### Restoration integrity

A run that leaves a checkout dirty compounds substitutions across files and
silently corrupts every later verdict, so this is the harness's first
obligation, not an afterthought. The original bytes are snapshotted before the
write, restored in a `finally`, and the restored file's SHA-256 is compared
against the snapshot's. A mismatch **throws** — it is never reported as a
verdict. The self-test asserts it by hash, and the CI job re-asserts it from
outside the harness with `git status --porcelain` on every checkout before the
whole-package mode reuses the same trees.

### What the self-test proves

`tools/coverage-study/test/rq1_tierb_self_test.dart` builds a synthetic
two-file package with a real passing `dart test` suite and asserts, against the
real pipeline: substitution restores every file byte-for-byte; a file whose
compiled-back Dart still passes is scored `clean` (the harness cannot pass by
calling everything dirty); a directives-only facade is `not-compiled` and **not
scored**; a package whose unmodified suite is already red is `baseline-unstable`
and excluded from the denominator; at least one file was actually scored and a
`Results:`-shaped line was printed (an exit code plus a zero failure count
cannot tell "everything passed" from "nothing ran").

The load-bearing assertion is the pair: a file carrying the #488 shape —
`return seen.add(name)` on a `Set<String>` — is measured through the
receiver-type-aware seam and scored `clean`, **while the resolution-free
`compileBack` still emits the broken `return seen..add(name)` cascade for the
very same source**, both asserted side by side in one test. That self-test runs
as a **gated** step in `ci.yml`'s Dart job, exactly like Tier A's — the
instrument is gated even though the study is not.

That assertion INVERTED in #488 slice 2, and the inversion is the point. Tier B
originally called `DartEncoder().encode(source)` per file, whose `parseString`
AST leaves every `Expression.staticType` null. Every receiver-type-aware branch
in the encoder is gated on a non-null `staticType`, so from Tier B's vantage
they were **structurally unreachable** — the harness could not see the fix for
the very defect it was built to measure. Slice 1's `Set.add` fix had already
landed on `main` and Tier B still scored `path/lib/src/path_set.dart` as
`behavioral-drift`, with the byte-identical `return_of_invalid_type` error.

The harness now runs ONE `PackageEncoder.prepareStaticTypes()` + `encode()` +
`DartCompiler` per package (`preparePackageCompileBack`) and looks each file's
text up from that result; a checkout it cannot resolve falls back per file to
the old resolution-free `compileBack`, so a `pub get`-less tree still measures
something rather than nothing. Two extra self-test assertions pin the seam
itself: that the per-package context is actually built (a silent fallback would
score `clean` by luck), and that it compiles `Set<T>.add(x)` as a plain call.

### No floor, deliberately

`dart-tier-b` in `.github/workflows/coverage-study.yml` is `workflow_dispatch` +
the weekly Monday cron, like every other job in that file. It has **no
`pull_request:` trigger and will not become a PR gate** in this slice. The only
thing it fails on is the shared positive floor in
`tools/coverage-study/summarize.sh`: a run that scored zero files is a
checkout/harness failure, never a 0% result. No quality floor is set until
several scheduled runs establish the variance — the project has been burned by
floors set before a baseline existed. #488's own ad-hoc prototype measured
88/106 files clean per-file and 1 of 5 packages clean whole-package; treat that
as the sanity check a first scheduled run should land near, not as a committed
number.

Two smoke measurements of one pin exist, both `path` @ `7e3d5d8`, per-file,
labelled rather than baselined:

| when | result | what changed |
| --- | --- | --- |
| while building this harness (#560) | **9/13 clean (69%)**, 0/1 whole-package | — |
| after #488 slice 2 | **12/13 clean (92%)** | the harness was wired to the receiver-type seam (`path_set.dart` → clean), and the dropped-optional-operand family was fixed (`style/windows.dart`, `style/url.dart` → clean) |

The one file still scored `behavioral-drift` is `src/context.dart`, and it is a
different mechanism: Dart's flow-sensitive promotion through REASSIGNMENT
(`from = from == null ? current : absolute(from);` promoting a `String?`
parameter for the rest of the body). Ball's IR is untyped and carries no
representation of it, so nothing survives the round trip to let the recompiled
Dart re-derive the promotion. That is tracked as #573, not as part of #488.

Neither number is a committed baseline — the checkout was byte-identical to its
pinned commit after every run, but one pin on one machine is a sanity check, not
variance. The per-file run takes ~530 s for 13 files plus the two baseline runs
— roughly 35 s per `dart test`, which is what sizes the job's 180-minute bound.
The first real numbers come from a scheduled run over all five pins.

### Fixing what it finds is not this instrument's job

Tier B reports; it does not repair. An encoder or compiler bug it surfaces gets
its own issue and its own PR — #488 above all. A harness that also changed the
thing it measures could not be trusted to measure it.

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

# The five ports. `tools/coverage-study/clone_pins.sh <pins.json> <dir>` clones
# each pin at its recorded commit (what every coverage-study.yml job runs), and
# `tools/coverage-study/summarize.sh <label> <log>` applies the positive floor.
bash tools/coverage-study/clone_pins.sh tools/coverage-study/packages/rust.json /tmp/co
cd rust && cargo run -p ball-rq1-study --bin rq1-study -- \
  --pins ../tools/coverage-study/packages/rust.json --checkouts /tmp/co

dotnet run --project csharp/coverage-study/Ball.CoverageStudy.csproj -c Release -- \
  --pins tools/coverage-study/packages/csharp.json --checkouts /tmp/co

cd tools/coverage-study/go && go run ./cmd/rq1study \
  --pins ../packages/go.json --checkouts /tmp/co

python3 tools/coverage-study/rq1_study_py.py \
  --pins tools/coverage-study/packages/python.json --checkouts /tmp/co

# TypeScript imports @ball-lang/{encoder,compiler} straight from source, so
# `npm ci` in ts/encoder and ts/compiler first; the harness has no deps of
# its own.
node --experimental-strip-types tools/coverage-study/rq1_study_ts.mts \
  --pins tools/coverage-study/packages/ts.json --checkouts /tmp/co

# Every harness also takes --package <name> --source-dir <dir> for a one-off.

# ── Tier B (Dart) ──────────────────────────────────────────────────────────
# Its self-test is gated in ci.yml's Dart job too.
dart run tools/coverage-study/test/rq1_tierb_self_test.dart

# Per-file isolation, then whole-package, over the same five pins.
# --jobs parallelizes across PACKAGES only (files of one package share a working
# tree). --test-timeout bounds every `dart test`; --max-files caps a package's
# file count, which changes the denominator but never a verdict.
bash tools/coverage-study/clone_pins.sh tools/coverage-study/packages/dart.json /tmp/co
dart run tools/coverage-study/rq1_tierb.dart \
  --pins tools/coverage-study/packages/dart.json \
  --checkouts /tmp/co --jobs 4 --test-timeout 600 --json tier_b.json

dart run tools/coverage-study/rq1_tierb_all.dart \
  --pins tools/coverage-study/packages/dart.json \
  --checkouts /tmp/co --jobs 4 --test-timeout 600 --json tier_b_all.json

# One package, no pin file. The checkout must be git-clean afterwards — that is
# the restoration-integrity property, and it is worth checking by hand the first
# time you point the harness at a new tree.
dart run tools/coverage-study/rq1_tierb.dart --package path --checkout /tmp/co/path
git -C /tmp/co/path status --porcelain   # must print nothing
```

## Status and honest limits

`.github/workflows/coverage-study.yml` is `workflow_dispatch` + a weekly
Monday schedule. It has **no `pull_request:` trigger and is not a required
check**, so a regression it finds does not block the PR that caused it. That is
deliberate — floors set before a baseline exists either go permanently red and
get ignored, or are set so low they mean nothing. The job fails only when the
harness itself failed (no summary line, or zero files scored).

Remaining slices of #493:

* Floor the Dart Tier A number once a few scheduled runs establish a baseline.
  Rust, C#, Go and Python are at 0% and have no floor to set yet — a ratchet on
  0 is meaningless; watch the funnel rows instead.
* Floor the TypeScript Tier A number once a few scheduled runs establish a
  baseline — it is the only port that is not at 0%, so it is the second
  candidate for a ratchet after Dart.
* Floor the Dart Tier B numbers (per-file and whole-package) once a few
  scheduled runs establish their variance — the same measure-before-gating rule
  Tier A is waiting on, and the reason `dart-tier-b` ships with only the
  positive floor.
* Port Tier B to the other five languages. Dart is the only one where the
  compiler emits idiomatic source its own encoder reads back; the others emit
  runtime-call-shaped source and are still at 0% on Tier A, so there is nothing
  behavioural to measure until their round trip closes.
* Publish the coverage table next to the engine-parity table in the README.
