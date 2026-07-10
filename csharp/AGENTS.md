<!-- Parent: ../AGENTS.md -->

# C# (Phase 1 scaffold — no Ball logic yet)

## Purpose

Directory scaffold + package manifests for the C# Ball implementation (epic #377). This phase
(#378) wires up five SDK-style projects — `shared`, `compiler`, `encoder`, `engine`, `cli` — plus
one xunit test project per package, all under a single solution. **No compiler, encoder, or
engine logic exists yet** — see the phase table below for what each package still needs.

## Layout

```
csharp/
  Ball.slnx               # solution (see "Solution format" below)
  Directory.Build.props   # shared MSBuild settings (net10.0, nullable, implicit usings)
  Directory.Packages.props # Central Package Management — all NuGet versions pinned here
  global.json              # minimum SDK: 10.0.100, rollForward: latestFeature
  shared/
    gen/Ball.cs            # buf-generated protobuf bindings — NEVER edit by hand
    src/PackageInfo.cs     # Phase 1 placeholder; BallValue/BallList/BallMap/BallFunction land in #380
    test/                  # Ball.Shared.Tests — protobuf round-trip smoke test
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

- Status: Phase 1 scaffold only (issue #378, epic #377). Every package compiles and has a real
  (non-empty-assert) smoke test, but there is no compiler/encoder/engine/CLI logic — see the phase
  table in the epic #377 tracking comment for the blocked-by graph (#379 proto wiring, #380
  runtime value model, #381 compiler, #382 encoder, #383 self-hosted engine, #384 conformance,
  #385 CLI, #386 CI, #387 docs).
- Follow `.claude/skills/new-ball-language/SKILL.md` for the remaining phases.
- Central Package Management is on (`Directory.Packages.props`) — add new package versions there,
  not per-project `Version=` attributes.
- Verify maturity against CI (`.github/workflows/ci.yml`), not this prose — no C# CI job exists
  yet (that's #386).
