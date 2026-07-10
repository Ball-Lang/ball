<!-- Parent: ../AGENTS.md -->

# C# (Phase 1+2 scaffold — proto bindings wired, no compiler/encoder/engine logic yet)

## Purpose

Directory scaffold + package manifests for the C# Ball implementation (epic #377). Phase 1
(#378) wires up five SDK-style projects — `shared`, `compiler`, `encoder`, `engine`, `cli` — plus
one xunit test project per package, all under a single solution. Phase 2 (#379) makes the
buf-generated protobuf bindings in `shared/gen/` consumable: pins the `Google.Protobuf` runtime
to the gencode's plugin version and adds binary + JSON round-trip smoke tests (see "Proto
bindings" below). **No compiler, encoder, or engine logic exists yet** — see the phase table
below for what each package still needs.

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
    test/                  # Ball.Shared.Tests — binary + JSON protobuf round-trip smoke tests
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
executing app, bridged to `dotnet test` via `xunit.runner.visualstudio`), not an empty stub. The
only non-trivial one is `shared` — see "Proto bindings" below. The other four packages have no
real logic yet (that's phases #380-383), so their tests assert on a `PackageInfo.Name` placeholder
constant instead; `cli`'s test additionally asserts its `CliInfo.Banner` references all four
sibling packages, proving the whole project-reference graph resolves (the C# analog of Rust's
Phase 1a "five member crates wired together via path dependencies").

## Proto bindings (issue #379, epic #377 Wave B Phase 2)

`shared/gen/Ball.cs` is buf-generated (`buf.build/protocolbuffers/csharp:v35.1`, see root
`buf.gen.yaml`) and consumed via a single `PackageReference Include="Google.Protobuf"` (version
resolved centrally — see "Google.Protobuf version pairing" below). Two smoke tests in
`shared/test/` prove the bindings are actually consumable, not just compilable:

- `ProtoBindingSmokeTests.cs` — constructs a `Ball.V1.Program` by hand, round-trips it through
  `ToByteArray()` / `Parser.ParseFrom()`, and asserts field equality. Proves the generated code
  compiles and binary (wire-format) protobuf works against the pinned runtime.
- `ProtoJsonRoundTripSmokeTests.cs` — loads a **real** conformance fixture
  (`tests/conformance/202_sandbox_mode.ball.json`, not a hand-built string) through
  `Google.Protobuf.JsonParser`, then round-trips the parsed message through binary protobuf
  (JSON → message → bytes → message) and asserts full structural equality (`Assert.Equal` on the
  generated message types, which implement deep field-by-field `Equals`). This is the JSON leg:
  it proves proto3-JSON compat, which the self-hosted engine loader (a later phase) will rely on
  when it reads `.ball.json` files off disk.

  A `.ball.json` file is a proto3-JSON `google.protobuf.Any` envelope — an explicit
  `"@type": "type.googleapis.com/ball.v1.Program"` key alongside the message's own fields (see
  `dart/shared/lib/ball_file.dart` for the canonical reader). The test mirrors that convention:
  it parses the envelope with `System.Text.Json`, asserts the `@type` value, strips the key, and
  hands the remaining body to `JsonParser` (with `IgnoreUnknownFields` on, matching the Dart
  reader's `ignoreUnknownFields: true` safety net) — rather than reaching for
  `JsonParser.Settings.IgnoreUnknownFields` to paper over the unrecognized `@type` field, which
  would test a looser contract than what the engine loader actually needs to implement.

### Google.Protobuf version pairing

`Google.Protobuf` `3.35.1` is pinned in `Directory.Packages.props` to match the
`buf.build/protocolbuffers/csharp:v35.1` gencode plugin line exactly — deliberately, not by
default resolution. The C++ target burned days on a gencode/runtime version skew (#302); the
fix here is the same discipline as C++'s `protobuf_deps.bzl` pin: **when bumping the `csharp`
plugin version in `buf.gen.yaml`, bump `Google.Protobuf`'s `PackageVersion` in
`Directory.Packages.props` to the matching minor/patch line in the same commit**, then rerun both
smoke tests above (a skewed pairing typically still compiles — the wire format is
backward/forward compatible across nearby versions — so the smoke tests, not the build, are what
would catch a meaningful skew; treat a passing build alone as insufficient evidence).

### Regen discipline — `buf generate proto` reproduces `shared/gen/` byte-identically

Verified 2026-07-11 with `buf` v1.56.0 on `PATH` (`buf --version`): ran `buf generate proto` from
the repo root (the module lives at `proto/buf.yaml`, so `proto` must be passed explicitly — see
root `CLAUDE.md`) and diffed the result against the committed tree.

- `git hash-object csharp/shared/gen/Ball.cs` before and after regeneration returned the
  **same blob hash** (`85f5ef99e0990ee12a1d00d8e066a02418f899d8`), and `cmp` against the
  pre-regen blob exited 0 (bytes identical) — i.e. `buf generate proto` reproduces
  `csharp/shared/gen/Ball.cs` byte-for-byte from `proto/ball/v1/ball.proto` + `buf.gen.yaml`.
- `git status` reported the file (and every other language's `gen/` output) as modified anyway.
  This is a benign local artifact of `core.autocrlf=true` on Windows: `buf`'s remote plugins emit
  LF line endings and none of `dart/`, `go/`, `java/`, `python/`, `rust/`, `ts/`, or `csharp/`
  `gen/**` carry a `text eol=lf` (or `binary`) `.gitattributes` rule, only `linguist-generated=true`
  — so a Windows checkout with `autocrlf=true` flags the LF-committed generated file as
  "would-convert" even when its content exactly matches HEAD. Confirmed via `git diff --numstat`
  (zero output — no line changes) and the blob-hash/`cmp` check above; do not read a bare `git
  status` "M" on `**/gen/**` after a regen as evidence of drift on Windows — check the blob hash.
- Regen command (also what CI should run once a C# CI job exists — #386):
  `buf generate proto` from the repo root, with `buf` on `PATH`.

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

- Status: Phase 1 (#378) + Phase 2 (#379) scaffold — every package compiles, `shared` consumes
  the buf-generated bindings against a version-pinned `Google.Protobuf` runtime with binary AND
  JSON round-trip smoke tests, and the regen discipline (`buf generate proto` reproduces
  `shared/gen/` byte-identically) is verified and documented above. There is still no
  compiler/encoder/engine/CLI logic — see the phase table in the epic #377 tracking comment for
  the blocked-by graph (#380 runtime value model, #381 compiler, #382 encoder, #383 self-hosted
  engine, #384 conformance, #385 CLI, #386 CI, #387 docs).
- Follow `.claude/skills/new-ball-language/SKILL.md` for the remaining phases.
- Central Package Management is on (`Directory.Packages.props`) — add new package versions there,
  not per-project `Version=` attributes.
- Verify maturity against CI (`.github/workflows/ci.yml`), not this prose — no C# CI job exists
  yet (that's #386).
