<!-- Parent: ../AGENTS.md -->

# C# (Phase 3 — runtime value model landed; compiler/encoder/engine still scaffold)

## Purpose

Directory scaffold + package manifests for the C# Ball implementation (epic #377). Phase 1
(#378) wired up five SDK-style projects — `shared`, `compiler`, `encoder`, `engine`, `cli` —
plus one xunit test project per package, all under a single solution. **Phase 3 (#380) added the
runtime value model + std module builders + the base-op helper layer to `shared/`** (see "Runtime
value model" below). The `compiler`/`encoder`/`engine`/`cli` packages are still Phase-1
placeholders — see the phase table in the epic #377 tracking comment.

## Layout

```
csharp/
  Ball.slnx               # solution (see "Solution format" below)
  Directory.Build.props   # shared MSBuild settings (net10.0, nullable, implicit usings)
  Directory.Packages.props # Central Package Management — all NuGet versions pinned here
  global.json              # minimum SDK: 10.0.100, rollForward: latestFeature
  shared/
    gen/Ball.cs            # buf-generated protobuf bindings — NEVER edit by hand
    src/BallValue.cs       # #380: polymorphic value hierarchy + numeric/display semantics
    src/BallList.cs        # #380: ordered, reference-semantic list (List<BallValue> backing)
    src/BallMap.cs         # #380: insertion-ordered map (OrderedDictionary<string,BallValue>)
    src/BallMessage.cs     # #380: descriptor-backed message instance (shared field map)
    src/BallFunction.cs    # #380: first-class callable (Func<BallValue,BallValue>)
    src/BallExceptions.cs  # #380: BallRuntimeException (fail-loud) + BallThrow (catchable)
    src/BallRuntime.cs     # #380: base-op helper layer the Phase-4 compiler dispatches to
    src/DescriptorBuilders.cs # #380: proto-descriptor helpers for the module builders
    src/StdModuleBuilders.cs  # #380: BuildStd{,Collections,Io,Memory}Module()
    src/Fields.cs          # #380: Fields.Extract(FunctionCall) named-argument convention
    src/PackageInfo.cs     # Phase 1 marker (still referenced by cli's CliInfo)
    test/                  # Ball.Shared.Tests — protobuf smoke + value-model/runtime/builder tests
  compiler/
    src/PackageInfo.cs     # Phase 1 placeholder; real Ball -> C# compiler lands in #381
    test/
  encoder/
    src/PackageInfo.cs     # Phase 1 placeholder; real C# -> Ball encoder (Roslyn) lands in #382
    test/
  engine/
    src/PackageInfo.cs     # Phase 1 placeholder; self-hosted engine wrapper lands in #383
    test/
  cli/
    src/Program.cs         # Phase 1 placeholder entry point; real subcommands land in #385
    src/CliInfo.cs          # proves shared/compiler/encoder/engine all resolve as references
    test/
```

## Solution format

`dotnet new sln` on the installed .NET 10.0.201 SDK generates the new XML `.slnx` format by
default (not the classic text `.sln`) — `Ball.slnx` is the real solution file; `dotnet build`/
`dotnet test`/`dotnet sln add` all work against it directly. Don't hand-author a `.sln`; use
`dotnet sln Ball.slnx add <path>` to add new projects.

## Test project layout (decision, issue #378)

Each package gets a **sibling** `<pkg>/test/` directory holding its own `.csproj` (e.g.
`shared/test/Ball.Shared.Tests.csproj`), not a top-level `test/` tree. This mirrors the
`src/`/`test/` split documented in `.claude/skills/new-ball-language/SKILL.md` §1.1 and keeps
parity with the sibling-language directory convention (`rust/compiler/`, `ts/compiler/` are
direct children of the language root, not nested under a shared `src/`). Because the .NET SDK's
default item globbing is recursive from each `.csproj`'s own directory, every main package
`.csproj` explicitly excludes `test/**/*.cs` (`<Compile Remove="test/**/*.cs" />`) so the main and
test projects never double-compile each other's files.

Each package's test project is a real xUnit.net v3 project (`dotnet new xunit3` shape — self
executing app, bridged to `dotnet test` via `xunit.runner.visualstudio`), not an empty stub. In
Phase 1 the only non-trivial one is `shared`: `ProtoBindingSmokeTests.cs` constructs a
`Ball.V1.Program`, round-trips it through `ToByteArray()`/`Parser.ParseFrom()`, and asserts field
equality — proving the buf-generated bindings actually compile and work against the pinned
`Google.Protobuf` runtime. The other four packages have no real logic yet (that's phases #380-383),
so their tests assert on a `PackageInfo.Name` placeholder constant instead; `cli`'s test
additionally asserts its `CliInfo.Banner` references all four sibling packages, proving the whole
project-reference graph resolves (the C# analog of Rust's Phase 1a "five member crates wired
together via path dependencies").

## Ordered-map decision (issue #378, for the runtime value model landing in #380)

`BallMap` (Ball's `std_collections` map type) has insertion order as a hard invariant — the same
requirement Rust satisfied with `indexmap::IndexMap` (see `rust/shared/Cargo.toml`). C# does not
need a third-party package for this: **`System.Collections.Generic.OrderedDictionary<TKey,TValue>`**
was added to the BCL in .NET 9 (`System.Collections.dll`) and is present unchanged in the .NET 10
docs (verified via learn.microsoft.com,
`system.collections.generic.ordereddictionary-2?view=net-10.0`, 2026-07-11). Since this project
targets `net10.0`, `BallMap` will wrap `OrderedDictionary<string, BallValue>` directly — no
`Google.Protobuf`-adjacent or third-party ordered-map dependency needed. This type is not yet
used in Phase 1 (no runtime value model exists yet); the decision is recorded here for #380 to
consume.

## Runtime value model (issue #380)

The `shared/` package now carries the runtime types the compiler/encoder/engine all build on,
the C# port of `rust/shared/src/value.rs` + `runtime.rs` (its closest sibling) and the Dart
reference engine's value hierarchy.

### Value hierarchy (`BallValue`)

`BallValue` is an **abstract sealed class hierarchy** (the idiomatic C# analog of Rust's
`enum BallValue` — exhaustive `value switch { BallInt i => …, BallList l => … }`). Concrete
subclasses: `BallNull`, `BallBool`, `BallInt` (`long`), `BallDouble` (`double`), `BallString`,
`BallBytes`, `BallList`, `BallMap`, `BallMessage`, `BallFunction`. Construct primitives via the
factories `BallValue.Null` / `.Bool(bool)` / `.Int(long)` / `.Double(double)` / `.Str(string)` /
`.Bytes(byte[])` (`Null`/`Bool` are cached singletons); the collection/callable/message types are
`BallValue`s themselves (`new BallList(...)`, `new BallMap()`, `new BallMessage(name, fields)`,
`new BallFunction(name, input => …)`).

- **Reference vs value semantics (the load-bearing invariant).** `BallList`/`BallMap`/
  `BallMessage`/`BallFunction` are reference types, so `var b = a;` aliases the same backing — a
  mutation through `b` is visible through `a`, exactly like Dart's `List`/`Map`/class instances
  (and the `Arc<Mutex<…>>`-shared Rust `BallList`/`BallMap`). Primitives are immutable/value-
  semantic. A `BallMessage` shares its field `BallMap` backing (the property the self-hosted
  engine's mutable `this` relies on). **Copy points must snapshot** (`BallList.Snapshot()` /
  `BallMap.Snapshot()`): list literals, `toList()`, spread, and `+` concat build a fresh backing —
  never alias an operand.
- **`BallMap` is insertion-ordered** via `System.Collections.Generic.OrderedDictionary<string,
  BallValue>` (.NET 9+): overwriting an existing key keeps its position; `Remove` preserves the
  order of the rest (unit-tested). Never substitute `Dictionary<,>`.
- **Numeric cross-type equality.** `BallValue.ValueEquals` (and each subclass's `Equals`/
  `GetHashCode`) treats `Int` and `Double` as equal when numerically equal (Dart's `0 == 0.0`).
  `BallList.Contains`/`IndexOf` and set ops route through it. Maps compare order-independently;
  functions compare by delegate identity.
- **`ToString()` matches reference-engine stdout**: whole doubles keep a trailing `.0`, `-0.0` is
  distinct, NaN/`Infinity`/`-Infinity` spellings, maps/messages render `{k: v, …}`, functions
  render `<function name>`/`<lambda>`.

### Module builders + field extraction

- `StdModuleBuilders.BuildStdModule()` / `BuildStdCollectionsModule()` / `BuildStdIoModule()` /
  `BuildStdMemoryModule()` construct the universal base `ball.v1.Module`s (every function
  `IsBase = true`, no `Body`). Counts are **asserted against the canonical Dart inventory** in the
  tests — `std` name-for-name against `dart/shared/std.json` (parsed at test time), and
  `std_collections`/`std_io`/`std_memory` (which have no committed JSON) against each `_fn('name',
  …)` in `dart/shared/lib/std_*.dart`. Never hardcode a bare count. `DescriptorBuilders`
  (`TypeDef`/`ExprField`/`StringField`/`BaseFn`/…) mirrors `rust/shared/src/descriptor_builders.rs`.
- `Fields.Extract(FunctionCall) → OrderedDictionary<string, Expression>` — the named-argument
  convention: no input ⇒ empty; a `MessageCreation` input ⇒ `{field.name: field.value}` (an
  absent value becomes a default, non-null `Expression`); any other input ⇒ `{"value": input}`.

### Base-op helper layer (`BallRuntime`) — what Phase 4 (#381) emits calls to

Static `BallRuntime` is the C# analog of `rust/shared/src/runtime.rs` / `cpp/shared/include/
ball_dyn.h`: the compiler emits `BallRuntime.Add(a, b)` etc. instead of re-deriving operator
semantics as text. **Every method takes/returns `BallValue`** (invariant #1). Signatures the
compiler dispatch table depends on:

- **Arithmetic** (int/double promotion, 64-bit wrapping, Euclidean modulo, truncating `~/`):
  `Add`, `Subtract`, `Multiply`, `Divide`, `DivideDouble`, `Modulo`, `Negate`. `Add` also does
  string concat and non-mutating list concat; `Multiply` does string×int repeat.
- **Comparison** (numeric promotion, ordinal string order): `Equals`, `NotEquals`, `LessThan`,
  `GreaterThan`, `Lte`, `Gte`, `CompareTo`.
- **Truthiness / dispatch**: `Truthy` (bool/`null`-falsy, else fail loud), `CallFunction`
  (first-class value dispatch), `UnsupportedBaseCall(module, function)` (fail-loud fallback),
  `Throw`. `and`/`or`/`??` short-circuit, so the compiler emits them **inline**, not as calls.
- **Logic / bitwise**: `Not`, `BitwiseAnd`/`Or`/`Xor`/`Not`, `LeftShift`, `RightShift`,
  `UnsignedRightShift`. **Null**: `NullCheck`, `NullCoalesce`.
- **Conversion / string**: `ToStringValue`, `Length`, `StringToInt`/`StringToDouble` (throw a
  catchable `FormatException` via `BallThrow`), `ToInt`/`ToDouble`, and the `String*` family
  (`Concat`, `StringContains`/`StartsWith`/`EndsWith`/`IndexOf`/`Substring`/`ToUpper`/`Trim`/
  `Replace`/`ReplaceAll`/`Split`/`Repeat`/`PadLeft`/`PadRight`, …). C#'s native UTF-16 `string`
  already gives Dart's `String.length`/index semantics for free.
- **Collections**: `ListGet`/`ListLength`/`ListFirst`/`ListContains`/… (read), `ListPush`/`ListPop`/
  `ListInsert`/`ListRemoveAt`/`ListSet`/`ListClear` (mutate the shared backing), `ListReverse`/
  `ListConcat`/`ListSlice`/`ListTake`/`ListDrop` (non-mutating, snapshot). `Map*`
  (`MapGet`/`MapSet`/`MapDelete`/`MapKeys`/…). `Set*` — a set is a duplicate-free list
  (`SetCreate`/`SetAdd`/`SetContains`/`SetUnion`/…). `StringJoin`.

**Fail loud** (throw `BallRuntimeException`) on an unhandled/mistyped shape — never a silent
`null`/placeholder. `BallThrow` is the catchable Ball `throw` (carries a `BallValue` payload +
optional type name for `on Type catch`). **Scope:** deferred to Phase 4 (fall back to
`UnsupportedBaseCall`): higher-order collection ops needing multi-arg callbacks
(`list_map`/`list_reduce`/…), `regex_*`, the `math_*` transcendental family, `std_io`, and all of
`std_memory`.

## Generated Files — NEVER Edit

- `csharp/shared/gen/` — protobuf bindings (`buf generate`, plugin
  `buf.build/protocolbuffers/csharp:v35.1`, see root `buf.gen.yaml`)

## Build & Test

```bash
# .NET 10 SDK is native on Windows — no WSL needed (unlike C++/Rust in this repo)
dotnet build csharp/Ball.slnx
dotnet test csharp/Ball.slnx
dotnet format csharp/Ball.slnx --verify-no-changes   # run `dotnet format` (no flag) to fix
dotnet run --project csharp/cli/Ball.Cli.csproj       # prints the Phase 1 wiring banner
```

## For AI Agents

- Status: Phase 3 for `shared/` (issue #380 — runtime value model + std module builders +
  base-op helper layer, all with real tests; see "Runtime value model" above). The
  `compiler`/`encoder`/`engine`/`cli` packages are still Phase-1 placeholders with smoke tests
  only — see the phase table in the epic #377 tracking comment for the blocked-by graph (#379
  proto wiring, #380 runtime value model, #381 compiler, #382 encoder, #383 self-hosted engine,
  #384 conformance, #385 CLI, #386 CI, #387 docs).
- The Phase-4 compiler (#381) must emit calls into `BallRuntime.*` for base-function dispatch and
  build lists/maps/messages with the reference-vs-value-semantics copy rules above — do not
  re-derive operator semantics as emitted text.
- Follow `.claude/skills/new-ball-language/SKILL.md` for the remaining phases.
- Central Package Management is on (`Directory.Packages.props`) — add new package versions there,
  not per-project `Version=` attributes.
- Verify maturity against CI (`.github/workflows/ci.yml`), not this prose — no C# CI job exists
  yet (that's #386).
