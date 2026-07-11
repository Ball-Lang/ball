---
paths:
  - "csharp/**"
---

# C#-Specific Instructions

C# (epic #377) is a **full pipeline** — compiler, encoder, self-hosted engine, and CLI are all in
place and tested. The self-hosted engine runs the whole conformance corpus at **Dart parity**
(`Results: 320 passed, 0 failed, 320 total (4 skipped carve-outs)`; the 4 golden-less
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
- `Ball.Encoder` (`csharp/encoder/`) — C# → Ball via **Roslyn** (`Microsoft.CodeAnalysis.CSharp`,
  syntax-only — `CSharpSyntaxTree.ParseText`, no semantic model). Routes every construct through
  universal `std`/`std_collections` — **no `csharp_std` base module**, ever.
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
- Documented scope gaps live in `csharp/AGENTS.md`'s "Compiler" section (body-carrying
  constructors, `super` chains, static members, labelled `break`/`continue` were closed during
  the self-host grind; read the current gap list before assuming something is a bug vs. a known
  boundary).

### Encoder

- `CSharpEncoder.Encode(source) -> Program` parses with Roslyn syntax trees and walks
  declarations → members → statements → expressions. **Invariant, not optional: no `csharp_std`
  base module** — verified by a CI-checkable xunit assertion (`StdModuleAccumulationTests`).
- The "one input" convention (invariant #1): unlike `rust/encoder` (which packs 2+-parameter
  functions into `field_access(reference("input"), name)` to work around a compiled-closure
  target), this encoder targets the tree-walking reference engine directly — every
  function/method/lambda parameter, of any arity, is referenced via a plain `reference(name)`,
  since the engine binds every declared parameter directly under its own name
  (`FunctionDefinition.metadata.params`).
- Instance methods use the engine's unconditional `self` convention: a method call's `input`
  carries a `"self"` field with the receiver; the encoder always addresses a field via explicit
  `field_access(reference("self"), field)`, never a bare name.
- Construction is **field-mapping only** — a constructor's parameter list (or a primary
  constructor) maps positional args onto field names; no constructor **body** is interpreted.
- Documented gaps (see `csharp/encoder/src/Methods.cs`'s module doc comment and
  `csharp/AGENTS.md`'s "Encoder" section): target-typed `new(...)`, `enum` declarations,
  `goto`/switch pattern-matching labels/catch exception filters, chained `?.` beyond one level,
  multiple constructors per class, local functions, interpolation alignment/format specifiers.

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++/Rust: compile
  `dart/self_host/engine.ball.pb` through `Ball.Compiler` into `src/CompiledEngine.cs`.
- **Status: complete, runs at Dart parity** (#383/#384 closed). `Results: 320 passed, 0 failed,
  320 total (4 skipped carve-outs)` — the whole conformance corpus, matching Dart's output
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
  legs selected via `--leg=`: `engine` (320/320, Dart parity — CI-gated), `compiler` (224/320 —
  the compiler's own honest scope-gap count, not CI-gated), `roundtrip` (0/320 — an honest,
  expected zero given the syntactic encoder doesn't yet recognize compiler-emitted
  `BallRuntime.*` shapes, not CI-gated). See `csharp/AGENTS.md`'s "Conformance harness" section
  before treating a non-`engine`-leg number as a regression.

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

- `dotnet test Ball.slnx` from `csharp/` runs every default-build test project. `Ball.Engine`'s
  and `Ball.Cli`'s self-hosted/cli-core-gated test classes are feature-gated off by default, so
  this stays green without requiring the generated, gitignored `CompiledEngine.cs`/`CompiledCli.cs`.
- `csharp/compiler/test/` — xUnit v3. `EndToEndTests` compile-and-run real fixtures via
  in-memory Roslyn and assert **byte-exact** stdout; prefer extending these (or conformance
  fixtures) over C#-only unit tests, per the repo-wide "prefer conformance tests" rule.
- `csharp/engine/conformance/` is the committed `tests/conformance/*.ball.json` runner (#384) —
  the `engine` leg is what CI gates on; quote its `Results:` line, not a hand-maintained count.
- `csharp/cli/test/CliCoreParityTests.cs` is the golden-fixture parity gate against the real Dart
  CLI (checked-in `.txt` goldens in `test/golden/cli_core/`) — the C# analog of
  `rust/cli/tests/cli_core_parity.rs`.

## Dependencies

- `Google.Protobuf = "3.35.1"` — pinned to match the `buf.build/protocolbuffers/csharp:v35.1`
  gencode plugin line exactly. When bumping the `csharp` plugin version in `buf.gen.yaml`, bump
  this in the same commit and rerun `shared/test/`'s binary+JSON round-trip smoke tests (a skewed
  pairing typically still *compiles* — only the smoke tests catch a meaningful skew).
- `Microsoft.CodeAnalysis.CSharp = "5.6.0"` — Roslyn syntax API, shared by the encoder and the
  compiler test suite's in-memory compile-and-run harness.
- `System.CommandLine = "2.0.9"` — the CLI's arg parser; the newest GA (non-preview) release as
  of the pin date.
- `xunit.v3` + `xunit.runner.visualstudio` + `Microsoft.NET.Test.Sdk` + `coverlet.collector` —
  the xUnit.net v3 test stack (`dotnet new xunit3` shape), bridged to `dotnet test` via VSTest.
