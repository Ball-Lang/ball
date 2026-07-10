# Ball toolchain matrix — acquisition and verification

Last verified: **2026-07-10** against live registries and `Ball-Lang/ball` CI. Statuses drift — re-verify before relying on a row (§2 of the skill).

## Summary

| Language | Encoder (source-side) | Compiler (target-side) | Engine | Fast install path |
|---|---|---|---|---|
| Dart | ✅ `ball encode` | ✅ `ball compile` (Ball → Dart) | ✅ `ball run` | `dart pub global activate ball_cli` (pub.dev, verified publisher **ball-lang.dev**) |
| TypeScript | ✅ `@ball-lang/encoder` | ✅ `@ball-lang/compiler` | ✅ `@ball-lang/cli` (`run`, `audit`) | `npm i @ball-lang/encoder @ball-lang/compiler @ball-lang/cli` |
| C++ | ✅ `ball_cpp_encode` (Clang JSON AST) | ✅ `ball_cpp_compile` | ✅ self-hosted engine | clone + CMake build (see below) |
| Rust | ✅ `rust/encoder` | ✅ `rust/compiler` | ✅ `rust/engine` | clone + `cargo build` (see below) |
| C#, Go, Python, Java | ❌ proto bindings only | ❌ | ❌ | Route to `/ball:new <lang>` |

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

- **crates.io**: the `ball` crate is an UNRELATED 2022 package (n-dimensional arrays). Do **not** `cargo install ball`. As of the verification date the Ball Rust toolchain is **not on crates.io** — build from source.
- **npm**: only trust `@ball-lang/*` packages whose `repository` field points at `github.com/Ball-Lang/ball`.

## Cross-language emission — which compiler runs where

Each Ball compiler emits **its own language only**; there is **no `--target` flag anywhere**. Pair the source language's encoder with the target language's compiler:

- Ball → Dart: `ball compile <program.ball.json>` (Dart CLI)
- Ball → TypeScript: `@ball-lang/compiler`'s `compile()` — e.g. `node -e "const {readFileSync,writeFileSync}=require('fs');const {compile}=require('@ball-lang/compiler');const p=JSON.parse(readFileSync(process.argv[1],'utf8'));delete p['@type'];writeFileSync(process.argv[2], compile(p));" program.ball.json out.ts`
- Ball → C++: `ball_cpp_compile <program.ball.json>`
- Ball → Rust: the built `rust/compiler` binary

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

## When a row is missing (no target compiler)

The conversion is blocked on bootstrapping the target — that is the `/ball:new <lang>` skill (run inside a `Ball-Lang/ball` checkout). It is a separate epic: scaffold → proto bindings → compiler → encoder → engine → conformance → CI. Do not begin the conversion until the target passes the Ball conformance corpus.
