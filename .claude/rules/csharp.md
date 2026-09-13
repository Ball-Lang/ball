---
paths:
  - "csharp/**"
---

# C#-Specific Instructions

C# (epic #377) is a **full pipeline** — compiler, encoder, self-hosted engine, and CLI are all in
place and tested. The self-hosted engine runs the whole conformance corpus at **Dart parity**
(`Results: 350 passed, 0 failed, 350 total (4 skipped carve-outs)`; the 4 golden-less
resource-limit/sandbox fixtures are documented carve-outs — #383/#384 closed). Always verify
maturity against CI (`.github/workflows/ci.yml`'s `csharp` job — build/test/format plus the
regenerate-then-run self-hosted engine conformance sweep — and the `csharp-engine` row in
`conformance-matrix.yml`, #386) and `csharp/AGENTS.md`, not stale prose.

## Build System

- .NET 10 SDK is **native on Windows** in this dev environment — no WSL needed (unlike
  Rust/C++'s conformance-runner build). `global.json` pins `10.0.100` (`rollForward:
  latestFeature`); CI uses `actions/setup-dotnet@v5` with `dotnet-version: "10.0.x"`.
- The solution is `csharp/Ball.slnx` — the new XML `.slnx` format `dotnet new sln` generates by
  default on this SDK, not the classic text `.sln`. Add new projects with `dotnet sln Ball.slnx
  add <path>`; never hand-author a `.sln`.
- **Central Package Management** is on (`csharp/Directory.Packages.props`): every `.csproj`
  references packages by name only (no `Version=` attribute) — add new package versions there,
  mirroring how `rust/Cargo.toml` centralizes `[workspace.dependencies]`. Exactly one
  `PackageVersion` per package id may exist; watch for merge-introduced duplicates.
- `csharp/Directory.Build.props` sets shared MSBuild settings (`net10.0`, `Nullable=enable`,
  implicit usings) for every project.

```bash
cd csharp
dotnet build Ball.slnx
dotnet test Ball.slnx
dotnet format Ball.slnx --verify-no-changes   # run `dotnet format` (no flag) to fix
```

## Package Structure

Each package gets a **sibling** `<pkg>/test/` directory (its own `.csproj`), not a top-level
`test/` tree — mirrors `rust/compiler/`, `ts/compiler/` being direct children of the language
root. Main `.csproj`s exclude `test/**/*.cs`/`tool/**/*.cs`/`conformance/**/*.cs` from their own
compile items so the sibling projects never double-compile each other's files.

- `Ball.Shared` (`csharp/shared/`) — `gen/Ball.cs` (buf-generated protobuf bindings, pinned
  `Google.Protobuf 3.35.1` to match the `buf.build/protocolbuffers/csharp:v35.1` gencode line —
  bump both together, see "Generated Files" below) + the runtime value model
  (`BallValue`/`BallList`/`BallMap`/`BallMessage`/`BallFunction`, `src/BallValue.cs` et al.) + std
  module builders (`StdModuleBuilders.cs`) + the `BallRuntime` base-op helper layer the compiler
  dispatches to (`src/BallRuntime.cs`).
- `Ball.Compiler` (`csharp/compiler/`) — Ball → C# compiler. `CSharpCompiler.Compile(Program) ->
  string` emits a single runnable C# source file; `BaseCall.cs` is the base-function dispatch
  table (delegates to `BallRuntime`); `TypeEmit.cs` handles `typeDefs[]` → class/enum emission.
- `Ball.Encoder` (`csharp/encoder/`) — C# → Ball via **Roslyn**. Two entry-point families:
  `Encode(string)`/`EncodeLibrary(string)` are **syntax-only** (`CSharpSyntaxTree.ParseText`, no
  semantic model), and `EncodeProject(dir)`/`EncodeFileInProject(...)` (#492 W12-C slice 1) build
  a real `CSharpCompilation` and ask its `SemanticModel`. Routes every construct through universal
  `std`/`std_collections` — **no `csharp_std` base module**, ever.
- `Ball.Engine` (`csharp/engine/`) — self-hosted engine wrapper (`Loader.cs`/`BallEngine.cs`/
  `BallProto` access patterns in `Ball.Shared`) + generated, gitignored `src/CompiledEngine.cs`.
  `engine/tool/Ball.Engine.Regen.csproj` regenerates it from `dart/self_host/engine.ball.pb`.
  `engine/conformance/Ball.Engine.Conformance.csproj` is the committed conformance harness
  (`engine`/`compiler`/`roundtrip` legs, #384).
- `Ball.Cli` (`csharp/cli/`) — the `ball` binary: `run`/`compile`/`encode`/`check` (via
  `System.CommandLine` 2.0.9) plus the self-hosted cli-core verbs `info`/`validate`/`tree`/
  `version` (generated, gitignored `src/CompiledCli.cs`, compiled from
  `dart/shared/lib/cli_core.dart` via `cli/tool/Ball.Cli.Regen.csproj`).

## Key Patterns

### Compiler

- Every compiled expression evaluates to a `BallValue`; base calls dispatch to `BallRuntime.*`
  (operators) or lower to native C# (control flow); user calls become a direct method call, or
  `BallRuntime.CallFunction(local, input)` for a first-class function value in a local.
- **Two compilation contexts**, because C#'s `if`/`for`/`while`/`switch`/`try` and `{ … }` blocks
  are *statements*, not expressions (unlike Rust's block-expressions):
  - **Statement context** — function bodies and block statements. Control flow lowers to the
    **native** C# statement; `return`/`break`/`continue` become the real C# keyword. Load-bearing:
    a `return` inside an `if`-branch returns from the enclosing function, which a pure-IIFE
    lowering would get wrong.
  - **Expression context** — where a value is required. An `if` becomes a C# ternary; a
    block/loop landing here is wrapped in a `Func<BallValue>` IIFE (`Run(() => { … })`, the C++
    precedent), confined to that narrow case.
- **Lazy control flow (invariant #4):** `if`→native `if`/ternary; `and`/`or`/`??`→native
  `&&`/`||`/conditional; `for`/`for_in`/`while`/`do_while`→native loops. Never eagerly evaluate an
  untaken branch.
- **Single-file emission:** the entry module's functions are `static` methods on one
  `BallProgram` class; every other user module is its own nested `static class`; base modules
  emit nothing (they *are* `BallRuntime`).
- Arithmetic/comparison semantics must match the Dart reference engine: modulo is Euclidean, int
  ops use 64-bit wrapping arithmetic (no overflow exceptions), `equals`/`not_equals` promote
  `Int`/`Double` cross-type.
- **Reference-semantic collections (Dart parity).** `BallList`/`BallMap`/`BallMessage`/
  `BallFunction` are C# reference types — `var b = a;` aliases the same backing. **Copy points
  must snapshot** (`BallList.Snapshot()`/`BallMap.Snapshot()`): list/map literals, `toList()`,
  spread, and `+` concat build a fresh backing — never alias an operand.
- `BallMap` is insertion-ordered via `System.Collections.Generic.OrderedDictionary<string,
  BallValue>` (.NET 9+ BCL type) — never substitute `Dictionary<,>`.
- **`is BallRawMap` is the engine's own raw-map probe, and `BallStd.IsOfType` answers it
  (#557).** The `"Map"` arm deliberately EXCLUDES a tagged set so a user program's
  `{1,2} is Map` is `false` (#528/#553) — but the self-hosted engine's `_ballValueIsSet` needs
  the opposite answer for its OWN representation, and with only `is Map` to ask with it was
  permanently `false` here, so every in-place set mutation the engine performed went to a
  throwaway copy. `BallRawMap` (a typedef in `dart/engine/lib/engine_types.dart`) is that second
  question, answered structurally: `value is BallMap`, no exclusion. Conformance fixture
  `462_set_mutation_in_place` is the guard.
- Documented scope gaps live in `csharp/AGENTS.md`'s "Compiler" section (body-carrying
  constructors, `super` chains, static members, labelled `break`/`continue` were closed during
  the self-host grind; read the current gap list before assuming something is a bug vs. a known
  boundary).

- **`std_collections.list_find` THROWS when nothing matches (#597).** It is Dart's
  `Iterable.firstWhere` WITHOUT `orElse` — what its own declaration in
  `dart/shared/lib/std_collections.dart` says ("Find first:
  list.firstWhere(callback)") and what the Dart reference engine does
  (`engine_std.dart`: `throw StateError('No element')`). Never a `null`/
  `undefined`/empty placeholder, and never an untyped throw: the thrown value
  must carry the type name `StateError` so the program's own `on StateError
  catch` sees it. `tests/conformance/463_list_find_no_match` is the cross-target
  guard; `csharp/compiler/test/ListFindContractTests.cs` (`BallRuntime.ListFind` throws a `BallThrow`, NOT a `BallRuntimeException` — only the former is what the compiled `catch (BallThrow …)` sees, so an unhandled native fault can no longer bypass the program's own `try`) is this target's half. See `docs/TESTING_STRATEGY.md` §5b.

- **`try` dispatches EVERY catch clause, in source order (#615).**
  `CompileTryStatement` emits one `catch (BallThrow __ballEx)` containing an
  `if`/`else if` chain: an `on <Type> catch` clause runs only when
  `BallRuntime.CatchMatches(__ballEx, "<Type>")` accepts the exception's type tag
  (its explicit `BallThrow.TypeName` when the runtime synthesized a typed throw,
  else the payload's own `BallMessage` type name or `BallMap` `__type__`, matched
  by FULL `main:StateError` or BARE `StateError` spelling), the first untyped
  `catch (e)` is the `else`, and a clause list where every typed clause misses
  ends in a bare `throw;` so an enclosing `try` sees the original exception.
  Before #615 only `catches[0]` was compiled — as an unconditional catch-all — so
  `throw StateError(...)` ran an `on ArgumentError catch` body: silently wrong
  output, never an error (its own doc comment recorded the gap, which is how the
  issue was filed — off prose, not off any CI signal). `BallThrow`'s untyped
  constructor also mirrors `std.throw`'s `arg0` -> `message` rename, so a caught
  `e.message` reads the constructor argument instead of `null`. Guards:
  `tests/conformance/464_typed_catch_clause_dispatch` +
  `146_nested_try_catch_types` (cross-target),
  `csharp/compiler/test/CatchClauseDispatchTests.cs` and
  `csharp/shared/test/CatchMatchTests.cs`. Those two are what gate the SHAPE: the
  `csharp-compiler` matrix row is a PR gate since #619, but it is a RATCHET on a
  passing count, and 146's failure sat inside its floor from day one.

### Encoder

- `CSharpEncoder.Encode(source) -> Program` parses with Roslyn syntax trees and walks
  declarations → members → statements → expressions. **Invariant, not optional: no `csharp_std`
  base module** — verified by a CI-checkable xunit assertion (`StdModuleAccumulationTests`).
- **Project mode is the opt-in semantic seam (#492 W12-C slice 1); `Encode`/`EncodeLibrary` stay
  resolution-free.** `CreateProjectCompilation(dir)` builds ONE `CSharpCompilation` over the
  directory (hermetic net10.0 references from the CPM-pinned `Basic.Reference.Assemblies.Net100`,
  never the SDK ref pack — CI pins `dotnet-version: "10.0.x"` so that path's version floats);
  `EncodeFileInProject(project, path)` encodes ONE file's declarations with project-wide
  semantics, and `EncodeProject(dir)` encodes the whole thing into one `Program`,
  abort-on-first-error. **Tier A uses the per-file pair, never `EncodeProject`** — its unit is the
  FILE, and a whole-project encode cannot produce a per-file funnel. The two halves mirror
  `dart/encoder`'s `prepareStaticTypes()` + per-file `encode()` exactly.
  `Encoder._semantics` defaults to `NullSemanticQuery` ("I don't know" to everything), so the
  resolution-free path is byte-identical to before the seam — structurally, not by luck; the
  golden `ProjectEncodingTests.EncodeSingleFile_IsByteIdenticalToACommittedGolden` is the guard
  and must never be relaxed. Route policy: `SymbolInfo.Symbol` **only**, never `CandidateSymbols`
  (`Symbol` is the overload Roslyn itself chose; any other `CandidateReason` means the site is not
  a single determinate target, so it is reported — `ISemanticQuery.BindingFailure` — never
  guessed). A method whose `ContainingType.DeclaringSyntaxReferences` is non-empty is a SOURCE
  symbol and takes the user-call path in front of `Methods.cs`'s table; an extension method routes
  through `ReducedFrom` (its unreduced static signature, receiver bound to the `this` parameter);
  arguments are keyed by `IMethodSymbol.Parameters`. A metadata (BCL) symbol falls through to the
  table unchanged. `nameof(x)` folds via `GetConstantValue`.
- **Project mode fails LOUD where it cannot answer — never a fallback to the name heuristic.**
  An empty `ReferencePaths` list and an unreadable reference path both throw (a partial reference
  set makes the compilation answer *wrongly*, not *not-at-all* — a deliberate divergence from
  `prepareStaticTypes`'s documented fail-soft, because there the fallback is the only behaviour
  that path promised). `GuardReceiverDiscriminatedCall` throws when a receiver-discriminated name
  (`.Contains`/`.IndexOf`) has an unbindable receiver OR one the route does not model; the SAME
  text through `Encode(string)` still returns today's answer, and both halves are asserted.
  Compilation diagnostics about the INPUT are surfaced in `ProjectEncodeResult`, never swallowed
  and never fatal (measured over the pins: 0 / 8 / 284 / 230 — dominated by third-party deps and
  a missing `HAVE_LINQ`, which is why `ProjectEncodeOptions.Defines` exists).
- **Two silent defects the seam closed, both unconditional fixes.** (1) Ball has no namespaces, so
  `A.Foo` and `B.Foo` both encoded to `main:Foo` — two `TypeDefinition`s and two `main:Foo.Method`
  functions in one module, no error; project mode groups by `INamedTypeSymbol` and throws naming
  both FQNs and both files (it fires on 4 real corpus files: `Either`/`Either<,>`, `Maybe`/
  `Maybe<T>`, `Result`/`Result<,>`, `JsonConverter`/`JsonConverter<T>`). (2) `partial` parts
  overwrote each other — `ClassFields[shortName] = fields`, last part wins, plus one
  `TypeDefinition` emitted per syntax part. Parts now accumulate and merge; that half is a
  same-file defect too, so it is not gated on project mode.
- The "one input" convention (invariant #1): unlike `rust/encoder` (which packs 2+-parameter
  functions into `field_access(reference("input"), name)` to work around a compiled-closure
  target), this encoder targets the tree-walking reference engine directly — every
  function/method/lambda parameter, of any arity, is referenced via a plain `reference(name)`,
  since the engine binds every declared parameter directly under its own name
  (`FunctionDefinition.metadata.params`).
- Instance methods use the engine's unconditional `self` convention: a method call's `input`
  carries a `"self"` field with the receiver; the encoder always addresses a field via explicit
  `field_access(reference("self"), field)`, never a bare name.
- Construction is **field-mapping only**, and since #492 slice B a constructor body is *resolved*
  syntactically rather than ignored: `CollectDeclarations` reduces each declared constructor to a
  `CtorShape` (parameter names + the ordered fields it assigns, each from a parameter index or a
  body literal), and a call site selects by **arity**, so several constructors of distinct arities
  work. The `MessageCreation` is keyed by the class's **declared field names**, never the
  constructor's parameter names — keying by the latter was a verified silent-wrong-output bug
  (`new Point(1,2).Sum()` printed `0` instead of `3` on the Dart reference engine whenever
  `private int _x; Point(int x){ _x = x; }`-style names differed). Only `field = param;` and
  `field = literal;` are recognised; anything else throws.
- **`: this(...)` chaining is resolved in a SECOND pass (#492 slice D); `: base(...)` still
  throws.** `CollectDeclarations` collects `CtorDraft`s first and flattens chains afterwards,
  because C# lets a constructor delegate to a sibling declared either before or after it — a
  single textual pass resolves only backward chains and silently mis-shapes forward ones. A
  chaining constructor's shape is the target's assignments re-sourced through the initializer's
  own arguments (same param-reference-or-literal constraint as a plain body), then its own body
  assignments; recursion is guarded so a cycle fails loud. `: base(...)` keeps throwing with a
  this-vs-base message: resolving it needs the superclass's own shapes and fields, and routing it
  through the same-class path would build a message from the wrong class's fields — **silently**,
  since nothing fails loud on a wrong mapping. That is why
  `encoder/test/ConstructorChainingTests.cs` compiles the encoded program back and RUNS it rather
  than only asserting a shape.
- **`enum` declarations encode (#492 slice C) — match the cross-language IR convention exactly.**
  An `enum` becomes an `EnumDescriptorProto` in `Module.Enums[]` (`main:<ShortName>`) plus a
  companion **descriptor-less** `TypeDefinition` tagged `metadata.kind = "enum"`; a member
  reference is `field_access(reference("Color"), "Green")`. That is the same shape
  `rust/encoder/src/types.rs` emits and the one `csharp/compiler/src/TypeEmit.cs::CompileEnum`
  already consumed — never invent a different one, a divergence surfaces only later as a
  round-trip mismatch. Member numbering follows C# (explicit `= N`, then N + 1 onward), and a
  **computed** discriminant (`1 << 0`, `Read | Write`) is the narrowed remaining gap: a
  syntax-only encoder has no constant evaluator, so it fails loud naming the member.
  `Encoder.EnumMembers` is kept separate from `ClassNames` so a `Color.Green`
  receiver is distinguishable from a static-field access and from an unresolved cross-file one,
  and the branch runs before `EncodePropertyAccess` so a member named `Count`/`Length`/`Keys`/
  `Values` is not rewritten into a `std.length`/`std_collections` call.
- **Bodyless members are OMITTED, not thrown on** (#492 slice A): an interface method or an
  `abstract`/`partial`/`extern` declaration is skipped by `EncodeTypeDeclaration` (the
  `TypeDefinition` still round-trips). Do NOT "fix" this by emitting `IsBase = true` — the
  compiler's class-member registration loop drops `IsBase` members *before* the dotted-name split,
  so such a member would vanish from the compiled class silently. Dispatch resolves by the
  receiver's concrete runtime type anyway, so an abstract member is unreachable at run time.
- Documented gaps (see `csharp/encoder/src/Methods.cs`'s module doc comment and
  `csharp/AGENTS.md`'s "Encoder" section): target-typed `new(...)`, a **computed** `enum`
  discriminant, `goto`/switch pattern-matching labels/catch exception filters, chained `?.` beyond
  one level, local functions, interpolation alignment/format specifiers, non-trivial constructor
  bodies, `: base(...)` constructor chaining, same-arity constructor overloads, and a
  namespace-qualified static receiver deeper than `System.X` (`System.Console`/`System.Math` DO
  work — `Encoder.StaticReceiverName`).
- **Library mode (#492 slice 2).** `Encode` requires a `Main` entry point; `EncodeLibrary` (CLI:
  `ball encode --library`) drops **only** that requirement — every other documented gap still
  throws `EncoderException`. Both share the private `AssembleProgram` helper. A library-mode
  `Program` carries `EntryModule = "main"` and an **empty `EntryFunction`**, so it is deliberately
  NOT runnable: `ball check` reports `missing entry_function`, which is the correct, documented
  boundary — never synthesise a fake entry function to silence it. The Rust encoder's
  `encode_library` makes the identical call; keep the two consistent.
- **Real-world coverage is measured, not assumed** (#492): `encoder/test/RealWorldSweepTests.cs`
  feeds one hand-authored fixture per taxonomy bucket through the entry point that bucket declares
  (`Encode`, `EncodeLibrary` for the `Main`-less library bucket, or `EncodeProject` for the
  multi-file cross-file bucket) and prints
  `Results: 10 passed, 1 failed, 11 total` (slice 1's baseline was `0 passed, 7 failed`; slice 2's,
  `1 passed, 6 failed`; slices A/B closed buckets b, c and g; slice C added and closed bucket
  (h), `enum` declarations; slice C's line was `5 passed, 3 failed, 8 total`; slice E closed
  bucket (e), `6 passed, 2 failed, 8 total`; slice 3 added and closed bucket (i), BCL static guard
  calls, `7 passed, 2 failed, 9 total`; slice 3b added and closed bucket (j), the 0-argument LINQ
  terminals, `8 passed, 2 failed, 10 total`; slice 4 added and closed bucket (k), the 2-argument
  `string.Join`; W12-C slice 1 closed bucket (d), the cross-file callee, with the
  `EncodeProject` semantic seam, `9 passed, 2 failed, 11 total` -> `10 passed, 1 failed,
  11 total`, leaving only bucket (f) — the taxonomy grows only when a fresh measurement says so,
  which is how the enum bucket stayed invisible until it was the largest). It never
  asserts the **global** passed count (only a positive floor and a fixture set checked against a
  real directory listing, so adding a fixture without wiring it in fails) — but every bucket a
  slice has CLOSED carries a real per-bucket `MustEncode` assertion, so a regression fails rather
  than quietly lowering the printed baseline. **Do not "fix" it by weakening a fixture**: buckets
  (b)/(g) write `System.Console.WriteLine(...)`, and closing their own gap alone would have left
  them red on the unrelated namespace-qualified-receiver gap — that was fixed properly
  (`Encoder.StaticReceiverName`) so both flip on their unmodified committed fixtures.
  Note the corrected throw-site taxonomy in `csharp/AGENTS.md`: an interface reaches
  `EncodeTypeDeclaration`, never the "unsupported type declaration kind" site, so an
  interface fixture must carry a method.
  Bucket (e) (slice E) is the second worked instance of that rule: its fixture carries **two**
  independent gaps (a `PredefinedTypeSyntax` receiver, `int.Parse`, and the 0-arg `.Count()`
  METHOD spelling of the `.Count` property) and both had to be fixed for it to flip unmodified.
  Bucket (i) (slice 3) is the third: one fixture carrying `ArgumentNullException.ThrowIfNull`
  plus both `Debug.Assert` arities. Bucket (j) (slice 3b) is the fourth: `.Last()` and 0-arg
  `.Any()` in one fixture, printing from a non-empty AND an empty receiver so an inverted route
  fails the round-trip run.
- **`PredefinedType` static receivers** (#492 slice E): `EncodeMemberInvocation` intercepts a
  `PredefinedTypeSyntax` receiver BEFORE `StaticReceiverName` and routes it through
  `EncodePredefinedTypeStaticCall` — `int`/`long`.`Parse` → `std.string_to_int`,
  `double`/`float`.`Parse` → `std.string_to_double` (the only two conversions `StdModuleBuilders`
  declares; `float` widening to a double is a documented approximation). Anything else on a
  keyword type throws loud NAMING the receiver. `TryParse` is deliberately not routed — dropping
  its out-parameter failure branch would compile, run, and be silently wrong.
- **`string.Join(separator, values)`** (#492 slice 4): the same function's second arm — `string`
  is a `PredefinedTypeSyntax` keyword exactly like `int`, and a keyword can never be shadowed, so
  this arm needs no `DeclaresSameFileStatic` guard. The **2-argument** shape routes to the
  already-declared/compiled/interpreted `std_collections.string_join` (call `MarkCollectionsUsed()`
  like every other `std_collections` route). **The field order is INVERTED** — C# is
  `(separator, values)`, `StringJoinInput` is `list` = 1, `separator` = 2 — so build it with
  NAMED fields; a positional build still "encodes" and joins with the wrong operand. `params`
  overloads (3+ args) and the 1-arg spelling stay LOUD; a `char` separator needs no special case
  (a character literal already encodes as its one-character string). A `null` ELEMENT is a
  documented approximation (C# renders empty, `string_join` renders `null`) — an element value, not
  a syntax shape. Measured yield: stage 1 stayed 123/472, the `unsupported static call` bucket fell
  **19 → 8** and all 12 files advanced to a different first error.
- **`.Equals(a, b)` is NOT routed and that is deliberate** (#492 slice 4): every measured
  2-argument occurrence carries an `IEqualityComparer`/`StringComparison`, and no `std` function
  models a comparer, so a bare `std.equals` would silently drop the semantics. Zero comparer-free
  occurrences exist, so there is nothing to partially route. Same for the 2-arg
  `ArgumentNullException.ThrowIfNull(value, paramName)`: zero occurrences, so the `nameof` model it
  needs buys no verified yield.
- **BCL static guard calls** (#492 slice 3): `ArgumentNullException.ThrowIfNull(x)` →
  `std.assert(std.not_equals(x, null), "<x> must not be null")`, `Debug.Assert(cond[, msg])` →
  `std.assert` 1:1 (1-arg and 2-arg as separate arity arms). `std.assert` was already declared,
  compiled and interpreted — this was purely an encoder-side gap, no new base function. Two
  invariants: the new `switch` arms are guarded on the same-file class table
  (`DeclaresSameFileStatic`) so a user class named `Debug` still wins, and the 2-arg
  `ThrowIfNull(value, paramName)` overload stays a LOUD error because `paramName` is `nameof(x)`,
  a shape this encoder cannot resolve. `String.IsNullOrEmpty` is a documented deferral (routing it
  would falsify `string_is_empty`'s "never emitted for a non-string" assumption in the Dart engine).
- **0-argument LINQ terminals** (#492 slice 3b): `.Last()` → `std_collections.list_last` (same
  throw-on-empty contract as C#'s own `.Last()`, so it is a route and not an approximation) and
  0-arg `.Any()` → `std.not(std_collections.list_is_empty(...))` — the 0-arity halves of arity
  windows that already carried their 1-argument arms (`list_find`/`list_any`). Both target
  functions were already declared/compiled/interpreted; this was purely a dispatch-table gap, and
  its measured Tier A yield is **zero** (stage 1 stayed at 123/472 — Tier A reports only a file's
  FIRST error), so it is justified by targeted tests plus a round-trip run, never by a funnel
  number. No `*OrDefault` name is routed — see the next bullet.
- **No `*OrDefault` LINQ terminal is routed** (#588): `FirstOrDefault` used to share `First`'s two
  arity windows (`list_first` at 0 args, `list_find` at 1), both of which THROW when there is
  nothing to return — right for `.First()`/`.First(pred)`, the exact opposite of the
  `default(T)` contract. Reproduced at BOTH arities by running the encoded `.ball.json` on the
  Dart reference engine (`Bad state: No element` where real C# prints `0`), so the defect is in
  the IR, not one target's runtime. The fix is a SUBTRACTION, not a nullable `list_first_or_null`:
  `default(T)` is `null` for a reference `T` but `0`/`0.0`/`false`/a zeroed struct for a value `T`,
  and a syntax-only encoder cannot see `T` at a `.FirstOrDefault()` call site (unlike #578's
  `default(int)`, where the keyword IS the syntax) — a nullable route would be right for some `T`
  and silently wrong for others. `First` keeps both routes; `FirstOrDefault`/`LastOrDefault`/
  `SingleOrDefault` are all loud `EncoderException`s. Measured Tier A effect: **zero** (funnel
  identical at `123/472`; one already-failing file's first error merely moved). **#597 has since
  RESOLVED, in favour of Dart's contract**: `list_find` throws a catchable `StateError` on every
  engine and every direct compiler (the TS engine's `null`, the TS/C++ compilers' `undefined`/null
  placeholders, and this compiler's missing `list_find` case — which emitted an
  `UnsupportedBaseCall` that threw a native `BallRuntimeException` at run time, bypassing the
  program's own `try` — were all bugs, now fixed). So `.First(pred)` -> `list_find` is CONFIRMED
  correct: real LINQ `First` throws `InvalidOperationException` on no match, and `list_find` now
  throws everywhere too. Nothing to revisit.
- **`default(T)` is the type's zero, not always null.** The `DefaultExpressionSyntax` arm used to
  encode every `default(T)` as a null literal, so `default(int)` printed `null` where C# prints
  `0` — silent wrong output. A predefined value-type keyword now yields its real zero
  (`int`/`long`/… → `0`, `double`/`float` → `0.0`, `bool` → `false`); a reference type, a generic
  parameter, or a keyword Ball has no counterpart for (`char`, `decimal`) keeps the honest null.
- **Round-trip proof, not encode-only.** A bucket flip is proven by compiling the ENCODED fixture
  back to C# and RUNNING it (`encoder/test/PredefinedTypeCallTests.cs` asserts exactly `43\n`).
  That is what caught the compiler's callback-field bug below — an encode-only assertion would
  have declared bucket (e) closed while its output crashed at run time.

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++/Rust: compile
  `dart/self_host/engine.ball.pb` through `Ball.Compiler` into `src/CompiledEngine.cs`.
- **Status: complete, runs at Dart parity** (#383/#384 closed). `Results: 350 passed, 0 failed,
  350 total (4 skipped carve-outs)` — the whole conformance corpus, matching Dart's output
  byte-for-byte. Gated behind the off-by-default `-p:SelfHost=true` MSBuild property (the C#
  analog of Rust's `self_host` cargo feature) because the generated `CompiledEngine.cs` is a
  gitignored build artifact not present in a fresh checkout — a default build stays green without
  it. Regenerate + run:
  ```bash
  cd dart && dart run compiler/tool/compile_engine_cpp.dart   # writes engine.ball.pb
  cd ../csharp && dotnet run --project engine/tool/Ball.Engine.Regen.csproj
  dotnet test engine/test/Ball.Engine.Tests.csproj -p:SelfHost=true --filter "FullyQualifiedName~SelfHostRunTests"
  ```
- Fixes to compiled-engine behavior belong in `csharp/compiler/` or `Ball.Shared`
  (`BallRuntime`/`BallProto`) — **never** hand-edit `CompiledEngine.cs`.
- The committed conformance harness (`csharp/engine/conformance/`, a standalone console app, not
  an xunit project — needs a reliable `Results:` line on stdout regardless of pass/fail) has three
  legs selected via `--leg=`: `engine` (320/320, Dart parity — CI-gated by the `csharp-engine` row
  in `conformance-matrix.yml`), `compiler` (258/335 as of #527/#528 — ratcheted by that file's
  `csharp-compiler` row against `CSHARP_COMPILER_FLOOR`; it is the compiler's own honest scope-gap
  count, a DROP fails, never a parity gate), `roundtrip` (0/320 — an honest, expected zero given
  the syntactic encoder doesn't yet recognize compiler-emitted `BallRuntime.*` shapes). Since #452
  item 1 the round-trip leg is ALSO run in CI, by the `csharp-roundtrip` measurement row: no floor
  (a ratchet on 0 is meaningless), but it asserts the harness produced a parseable `Results:` line
  with integer counts and `total >= 1`, so the leg can no longer silently rot. Since #452 item 3
  the Python/Go/Rust targets have identical rows (`python-roundtrip`/`go-roundtrip`/
  `rust-roundtrip`) built to the same shape and reporting the same honest zero. Do not treat the
  numbers here as live — read them off those rows. NOTE: since #619 every row in
  `conformance-matrix.yml` (these, the engine rows, and the `*_COMPILER_FLOOR` ratchets alike) DOES
  gate a PR — the workflow has a path-filtered `pull_request:` trigger sharing the `push` filter, so
  no dispatch is needed. What each row gates still differs: the engine rows gate full Dart parity,
  the `*_COMPILER_FLOOR` rows are ratchets that tolerate their known gaps, and the `*-roundtrip`
  rows gate harness health only.
  See `csharp/AGENTS.md`'s "Conformance harness" section before treating a non-`engine`-leg number
  as a regression.

### CLI

- `System.CommandLine` 2.0.9 (verify current stable on nuget.org before bumping — it only went GA
  2025-11-11). Exit-code contract: `0` success, `1` runtime error, `2` invalid/unparseable
  program, `3` I/O error — mirrors `rust/cli/src/error.rs`.
- `.ball.bin` is `Any`-wrapped (`Any.Pack(program).ToByteArray()`) — the Dart-canonical binary
  shape. This **deliberately diverges** from `rust/cli`, which writes a bare `Program`; do not
  copy that choice here.
- Two Windows-specific console fixes are load-bearing and easy to reintroduce accidentally: force
  `Console.OutputEncoding` to UTF-8, and force `Console.Out.NewLine`/`Console.Error.NewLine` to
  `"\n"` (never the platform `Environment.NewLine`) — see `csharp/AGENTS.md`'s "CLI" section.
- cli-core verbs (`info`/`validate`/`tree`/`version`) are gated behind `-p:CliCore=true`,
  **independent** of `-p:SelfHost=true` — cli-core's functions are pure data transforms, not the
  interpreter.

## Generated Files — NEVER Edit

- `csharp/shared/gen/Ball.cs` — protobuf bindings (`buf generate proto`, plugin
  `buf.build/protocolbuffers/csharp:v35.1`, root `buf.gen.yaml`).
- `csharp/engine/src/CompiledEngine.cs` — gitignored, regenerated via `dotnet run --project
  csharp/engine/tool/Ball.Engine.Regen.csproj`. Only participates in the build under
  `-p:SelfHost=true`.
- `csharp/cli/src/CompiledCli.cs` — gitignored, regenerated via `dotnet run --project
  csharp/cli/tool/Ball.Cli.Regen.csproj`. Only participates in the build under `-p:CliCore=true`.

## Testing

- **Third-party coverage study, Tier A (#493).** `csharp/coverage-study` (a separate
  Exe project in `Ball.slnx`, mirroring `engine/tool`) runs real pinned libraries
  through `EncodeFileInProject` -> `CSharpCompiler.Compile` -> `EncodeLibrary`, diffs the
  declaration inventory with a **Roslyn `CSharpSyntaxWalker` directly** (never
  `Ball.Encoder`'s own walk) and checks a second-generation fixpoint. Honest
  baseline **0/472 clean**, but the funnel is the story: **141 files encode, 140
  compile back, 58 re-encode**, and the wall is stage 4 (`declaration-drift`) — the
  furthest any port gets. Stage 1 is measured with **`--project-mode`** since #492
  W12-C slice 1 (one `CSharpCompilation` per pinned subtree, one `SemanticModel` per
  file); the UNIT is unchanged — one verdict per file, same 472 denominator, same
  taxonomy tags — which `TierASelfTests`'
  `Project_mode_keeps_the_per_file_basis_and_resolves_a_cross_file_callee` CHECKS
  rather than assumes. Measured both ways on the same pins: `123/122` -> `141/140`,
  clean `0/472` either way, 18 files advanced and 0 regressed, and the
  `unsupported method call` first-blocker family fell 101 -> 53. The flag defaults
  OFF in the harness and is passed explicitly by `coverage-study.yml`, because a
  basis change must be an explicit, reported choice.
  Tier A reports only a file's FIRST error, so
  a correct per-shape fix routinely leaves stage 1 unchanged — #578 and #492 slices 3,
  3b and 4 each did — while the file advances to its next gap. Verify a shape with a
  targeted test, and only ever move `tools/coverage-study/baseline.json`'s floor to
  a number the harness actually printed. `dotnet test csharp/coverage-study/test/...` (the harness's own
  self-test) IS gated on every PR in the `csharp` job; the RUN is the
  `csharp-tier-a` job in `coverage-study.yml`, which has **no `pull_request:`
  trigger** (its row is floored by ratchet in that workflow's `publish` job). Methodology: `tests/conformance/COVERAGE_STUDY.md`.

- `dotnet test Ball.slnx` from `csharp/` runs every default-build test project. `Ball.Engine`'s
  and `Ball.Cli`'s self-hosted/cli-core-gated test classes are feature-gated off by default, so
  this stays green without requiring the generated, gitignored `CompiledEngine.cs`/`CompiledCli.cs`.
- `csharp/compiler/test/` — xUnit v3. `EndToEndTests` compile-and-run real fixtures via
  in-memory Roslyn and assert **byte-exact** stdout; prefer extending these (or conformance
  fixtures) over C#-only unit tests, per the repo-wide "prefer conformance tests" rule. But note
  `EndToEndTests` is **four hardcoded fixtures**, not a corpus sweep — the only leg that compiles
  the whole corpus through `CSharpCompiler` is `engine/conformance --leg=compiler`, a ratchet on a
  workflow with no `pull_request` trigger. A rule that depends on a specific IR shape needs a
  targeted test (`AccessorEdgeCaseTests.cs`, #461, is the worked example — both its shapes are
  unreachable from any generated fixture).
- **Captured stdout is per-execution-context — never `Console.SetOut` (#611).** `CSharpRunner.Run`
  (`csharp/compiler/test/TestSupport.cs`, LINKED into `encoder/test/`) captures a compiled
  program's stdout through `ConsoleCapture.Capture`: `Console.Out` is swapped **once** for a router
  that forwards each write to the capture registered for the CALLING execution context
  (`AsyncLocal<TextWriter?>`), else to the real console. The old spelling — a global
  `Console.SetOut(stringWriter)` behind a `lock` — captured every write in the process, and a lock
  cannot restrain a writer that never takes it: `RealWorldSweepTests`' bare `Console.Write(report)`
  (a different class, therefore a different xUnit collection, therefore parallel by default —
  <https://xunit.net/docs/running-tests-in-parallel>) landed inside
  `BucketIFixtureEncodesCompilesAndRuns`'s capture, which expected `"BALL\n"` and got
  `"Results: 9 passed, 2 failed, 11 total\n…"` (CI run 34732470492). Do NOT "fix" a future
  collision with `[Collection]` + `DisableParallelization` (opt-in per class — it serialises the
  suite and leaves the hole open for the next Console writer) and never hand a test a bare
  `Console.SetOut`. `ConsoleCaptureIsolationTests` (linked into both test assemblies) is the guard;
  it FORCES the interleaving with a file handshake, because a plain stress loop reproduced this 0
  times in 20 runs. `csharp/engine/conformance/CSharpRunner.cs` keeps a global redirect on purpose
  — that harness is single-threaded; port `ConsoleCapture` there before running any leg
  concurrently.
- `csharp/engine/conformance/` is the committed `tests/conformance/*.ball.json` runner (#384) —
  the `engine` leg is what CI gates on; quote its `Results:` line, not a hand-maintained count.
  Its mismatch reporting goes through `Fixtures.DescribeMismatch` (first **differing** line, never
  line 0) and is pinned by `engine/test/MismatchDescriptionTests.cs`.
- `csharp/cli/test/CliCoreParityTests.cs` is the golden-fixture parity gate against the real Dart
  CLI (checked-in `.txt` goldens in `test/golden/cli_core/`) — the C# analog of
  `rust/cli/tests/cli_core_parity.rs`.
- `csharp/shared/test/StdModuleBuilderTests.cs` compares the builders to the canonical Dart
  inventory name-for-name **and, since #557, `outputType` for `outputType`**
  (`AssertOutputTypesMatch`). The name gate cannot see a declared-TYPE drift, and that is exactly
  how `set_add`/`set_remove` kept `""` here after #545 declared `'bool'` in Dart — both sides
  green, the cross-target contract split. Port the `outputType` too, not just the name; Rust has
  the same pair of gates (`rust/shared/src/std_dart_parity.rs`).

## Dependencies

- `Google.Protobuf = "3.35.1"` — pinned to match the `buf.build/protocolbuffers/csharp:v35.1`
  gencode plugin line exactly. When bumping the `csharp` plugin version in `buf.gen.yaml`, bump
  this in the same commit and rerun `shared/test/`'s binary+JSON round-trip smoke tests (a skewed
  pairing typically still *compiles* — only the smoke tests catch a meaningful skew).
- `Microsoft.CodeAnalysis.CSharp = "5.6.0"` — Roslyn. Syntax API for the encoder's
  resolution-free entry points and the compiler test suite's in-memory compile-and-run harness;
  since #492 W12-C slice 1 also the `CSharpCompilation`/`SemanticModel` behind `EncodeProject`.
- `Basic.Reference.Assemblies.Net100 = "1.8.11"` — hermetic net10.0 REFERENCE assemblies for that
  compilation (MIT, netstandard2.0, references carried as embedded resources). Deliberately not
  the SDK ref pack: CI pins `dotnet-version: "10.0.x"`, so the pack's `<ver>` floats with the
  runner's patch and the encoder's binding answers would drift with it.
- `System.CommandLine = "2.0.9"` — the CLI's arg parser; the newest GA (non-preview) release as
  of the pin date.
- `xunit.v3` + `xunit.runner.visualstudio` + `Microsoft.NET.Test.Sdk` + `coverlet.collector` —
  the xUnit.net v3 test stack (`dotnet new xunit3` shape), bridged to `dotnet test` via VSTest.
