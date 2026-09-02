# Ball toolchain matrix — acquisition and verification

Last verified: **2026-09-02** against live registries and `Ball-Lang/ball` CI (the Go/Python rows were stale — both are complete pipelines now, but neither is registry-installable; see the warnings below). Statuses drift — re-verify before relying on a row (§2 of the skill).

## Summary

| Language | Encoder (source-side) | Compiler (target-side) | Engine | Fast install path |
|---|---|---|---|---|
| Dart | ✅ `ball encode` | ✅ `ball compile` (Ball → Dart) | ✅ `ball run` | `dart pub global activate ball_cli` (pub.dev, verified publisher **ball-lang.dev**) |
| TypeScript | ✅ `@ball-lang/encoder` | ✅ `@ball-lang/compiler` | ✅ `@ball-lang/cli` (`run`, `audit`) | `npm i @ball-lang/encoder @ball-lang/compiler @ball-lang/cli` |
| C++ | ✅ `ball_cpp_encode` (Clang JSON AST) | ✅ `ball_cpp_compile` | ✅ self-hosted engine | clone + CMake build (see below) |
| Rust | ✅ `rust/encoder` | ✅ `rust/compiler` | ✅ `rust/engine` | clone + `cargo build` (see below) |
| C# | ✅ `csharp/encoder` (Roslyn) | ✅ `csharp/compiler` | ✅ self-hosted `csharp/engine` (`-p:SelfHost=true`) | clone + `dotnet build` (see below) — **not yet on NuGet** (#369 blocked on packaging, prerequisite now satisfied) |
| Go | ✅ `go/encoder` | ✅ `go/compiler` | ✅ self-hosted `go/engine` (`-tags selfhost`) | clone + `go build` — **NOT `go install`-able** (see below) |
| Python | ✅ `python/encoder` | ✅ `python/compiler` | ✅ self-hosted `python/engine` | clone + run in place — **not on PyPI** (no publish workflow exists) |
| Java | ❌ proto bindings only | ❌ | ❌ | Route to `/ball:new java` |

## Verification commands (run these, do not trust the table)

```bash
# Dart CLI — exists and current?
dart pub global activate ball_cli && ball version

# npm packages — published and pointing at the real repo?
npm view @ball-lang/cli repository.url   # must be github.com/Ball-Lang/ball
npm view @ball-lang/compiler version
npm view @ball-lang/encoder version

# Target maturity ground truth: Ball repo CI
gh api repos/Ball-Lang/ball/contents/.github/workflows/ci.yml -q .content | base64 -d | head -80
```

## Registry warnings

- **Go module proxy**: `go install github.com/ball-lang/ball/go/cli/cmd/ball@latest` **does not work** and never has (issue #361, verified live 2026-09-02). It fails with `The go.mod file for the module providing named packages contains one or more replace directives.` — `go/{cli,compiler,encoder,engine}/go.mod` carry filesystem-relative `replace ... => ../<dep>` directives that the proxy cannot satisfy, because it serves a nested module as its own directory tree only. Clone the repo and `go build` instead. (ci.yml's `go` job now measures this every run: 2/6 modules build in isolation today.)
- **PyPI**: nothing is published, and no `publish-pypi.yml` exists. Clone and run `python -m ball_cli` in place.
- **crates.io**: the `ball` crate is an UNRELATED 2022 package (n-dimensional arrays). Do **not** `cargo install ball`. As of the verification date the Ball Rust toolchain is **not on crates.io** — build from source.
- **npm**: only trust `@ball-lang/*` packages whose `repository` field points at `github.com/Ball-Lang/ball`.

## Cross-language emission — which compiler runs where

Each Ball compiler emits **its own language only**; there is **no `--target` flag anywhere**. Pair the source language's encoder with the target language's compiler:

- Ball → Dart: `ball compile <program.ball.json>` (Dart CLI)
- Ball → TypeScript: `@ball-lang/compiler`'s `compile()` — e.g. `node -e "const {readFileSync,writeFileSync}=require('fs');const {compile}=require('@ball-lang/compiler');const p=JSON.parse(readFileSync(process.argv[1],'utf8'));delete p['@type'];writeFileSync(process.argv[2], compile(p));" program.ball.json out.ts`
- Ball → C++: `ball_cpp_compile <program.ball.json>`
- Ball → Rust: the built `rust/compiler` binary
- Ball → C#: `dotnet run --project csharp/cli/Ball.Cli.csproj -- compile <program.ball.json>`

## Dart (`ball` CLI)

`dart pub global activate ball_cli` installs the `ball` executable. Commands: `info`, `validate`, `compile` (Ball → Dart source), `encode` (Dart source → Ball), `run` (execute on the engine), `round-trip` (encode → compile → diff, the ideal §3 probe), `audit` (static capability analysis), `build` (resolve imports into a self-contained program, encoding pub dependencies on the fly), `init`/`add`/`resolve`/`tree`/`publish` (Ball package management; `publish` bakes a whole package into `lib/module.ball.bin` via the package-level encoder). Options: `--output <file>`, `--format json|binary`, `--no-format`.

## TypeScript

- `@ball-lang/encoder` — TS source → Ball IR (TypeScript Compiler API based).
- `@ball-lang/compiler` — Ball IR → TS source; `import { compile } from '@ball-lang/compiler'`, pass the parsed program object (strip the `"@type"` key of the `google.protobuf.Any` envelope first if present).
- `@ball-lang/cli` — `run` and `audit` over `.ball.json` programs.

## C++ (build from source)

```bash
git clone https://github.com/Ball-Lang/ball && cd ball/cpp
mkdir -p build && cd build && cmake .. && cmake --build . -j
# Produces: ball_cpp_compile (Ball IR -> C++), ball_cpp_encode (C++ -> Ball IR, via Clang JSON AST)
```

Linux/macOS/WSL only — native Windows MSVC builds are unsupported; on Windows run the build inside WSL.

## Rust (build from source)

```bash
git clone https://github.com/Ball-Lang/ball && cd ball/rust
cargo build --release
# Workspace crates: cli (binary name: ball), compiler, encoder, engine, shared
```

## C# (build from source — not yet on NuGet)

```bash
git clone https://github.com/Ball-Lang/ball && cd ball/csharp
dotnet build Ball.slnx
dotnet run --project cli/Ball.Cli.csproj -- --help
# Packages: shared, compiler, encoder, engine, cli. The self-hosted engine
# (info/validate/tree/version cli-core verbs, and the interpreter itself)
# need CompiledEngine.cs/CompiledCli.cs regenerated first — see csharp/AGENTS.md.
```

## When a row is missing (no target compiler)

The conversion is blocked on bootstrapping the target — that is the `/ball:new <lang>` skill (run inside a `Ball-Lang/ball` checkout). It is a separate epic: scaffold → proto bindings → compiler → encoder → engine → conformance → CI. Do not begin the conversion until the target passes the Ball conformance corpus.
