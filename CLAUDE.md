# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Ball Is

Ball is a programming language where every program is a Protocol Buffer message (`proto/ball/v1/ball.proto` is the single source of truth). Compilers translate Ball programs into target-language source, encoders do the reverse, and engines interpret Ball programs directly. Dart is the reference implementation (compiler + encoder + engine + CLI, broadest std coverage). **TypeScript** is a full pipeline too — compiler, self-hosted engine, and encoder — all CI-gated (the engine passes the conformance corpus; the encoder round-trips TS→Ball→target through universal `std`, with no `ts_std`). **C++** has a compiler, encoder (Clang AST → Ball), and self-hosted engine, with the self-host conformance passing **every** fixture; it is now **libprotobuf-free** — #18 Stage 5 dropped the FetchContent Google protobuf entirely (closing #18/#25/#330/#333), loading Ball via the protobuf-free `ball::ir` (nlohmann/json) + Ball's own compiled protobuf runtime. **Rust** (epic #32, closed) is now a complete pipeline too: compiler (`rust/compiler/`, #36-38), encoder (`rust/encoder/`, #42-43), proto bindings + runtime value model (`rust/shared/`, #34-35), a self-hosted engine that runs the whole conformance corpus at Dart parity (`Results: 319 passed, 0 failed, 319 total`; #39/#300 closed), and a `ball` CLI (`run`/`compile`/`encode`/`check`, #41); all CI-gated (the `rust` job in `ci.yml` plus a `rust-engine` row in `conformance-matrix.yml`, #40/#44 closed) — see `rust/AGENTS.md`.  **C#** (epic #377) is now a complete pipeline too: proto bindings + a runtime value model (`csharp/shared/`, #379-380), a Ball → C# compiler (`csharp/compiler/`, #381), a Roslyn-based C# → Ball encoder (`csharp/encoder/`, #382, syntax-only via `Microsoft.CodeAnalysis.CSharp`), a self-hosted engine that runs the whole conformance corpus at Dart parity (`csharp/engine/`, #383, `Results: 320 passed, 0 failed, 320 total`, behind the off-by-default `-p:SelfHost=true` MSBuild property since the generated `CompiledEngine.cs` isn't present in a fresh checkout), a committed conformance harness with engine/compiler/round-trip legs (`csharp/engine/conformance/`, #384), and a `ball` CLI (`csharp/cli/`, #385: `run`/`compile`/`encode`/`check` via `System.CommandLine` plus the self-hosted cli-core verbs `info`/`validate`/`tree`/`version` behind `-p:CliCore=true`), all CI-gated (the `csharp` job in `ci.yml` — build/test/format + the regenerate-and-run self-hosted engine conformance sweep — plus a `csharp-engine` row in `conformance-matrix.yml`, #386) — see `csharp/AGENTS.md`. Statuses drift — verify maturity against CI (`.github/workflows/ci.yml`), not this prose.


**Every language is only "done" when it can compile AND encode AND execute the conformance corpus** — a compiler without an encoder (or vice-versa) is a half-implementation. Treat the cross-language conformance matrix (Dart/TS/C++/… × compile/encode/run) as the definition of done.

## Codebase Exploration — use SocratiCode (CRITICAL)

This repo is large and cross-cutting (one Dart change ripples through the encoder → self-hosted engine → every target). **Use the `bdaya-socraticode` MCP tools intensively** instead of guessing or doing shallow greps:

- **Before any non-trivial change**, run `codebase_search` (semantic) and `codebase_flow`/`codebase_impact` to map the blast radius across `dart/`, `ts/`, `cpp/`, `tests/`. Prefer it over ad-hoc `grep` for "where/how is X used".
- Keep the index fresh: `codebase_status` to check, `codebase_index` to (re)build. The file watcher auto-updates, but resume any interrupted index before relying on search.
- Use `codebase_symbol`/`codebase_symbols` for precise symbol lookups and `codebase_graph_query` for dependency edges.
- For deep multi-file understanding, delegate to the `bdaya-socraticode:codebase-explorer` agent.
- Treat SocratiCode as the first-line exploration tool; fall back to Grep/Read only for pinpoint reads you already located.

## General Rules to follow (CRITICAL)

- Avoid anti-patterns, follow best practices
- Maximize performance and minimize memory usage where possible, but not at the cost of readability or maintainability.
- Write clear, concise code with good variable names and comments where necessary.
- Make sure everything is covered by tests, maximize using e2e conformance tests with round-trips instead of just unit tests.
- DO NOT leave any hanging TODOs or FIXMEs in the code. If something is not implemented, either implement it or remove the placeholder.
- YOU MUST FLAG AND FIX ANY BUGS YOU ENCOUNTER, EVEN IF THEY ARE NOT YOUR FAULT. This is a shared codebase and everyone is responsible for its health.
- When in doubt, use AskUserQuestion tool to get feedback on design decisions or implementation details.
- Maximize automation via github actions, scripts, and code generation. Avoid manual steps that can be automated.
- Follow the existing code style and patterns in the repository for consistency. If you need to introduce a new pattern, make sure to justify it and document it well.
- Update CLAUDE.md and AGENTS.md and .claude/* as needed when making changes to the codebase, especially if it affects how agents interact with the code or how developers should work with it.
- Always cross check your work against official latest docs, compiler source codes, and any relevant resources to ensure accuracy and completeness.
- YOU MUST NOT BE LAZY. YOU MUST Use WebSearch, WebFetch, exa, github MCP, or any knowledge retrieval tool at your disposal to get the information you need to do your job well. If you don't know something, find out. Don't just guess or make assumptions. YOU MUST NOT RELY ON YOUR TRAINING DATA OR MEMORY. The world is changing fast, and you need to keep up. Always verify that your information is up to date and relevant.

## Build & Test

```bash
# Dart — the pub-workspace + Melos root is the REPO ROOT (/pubspec.yaml);
# the packages live under dart/. Run `dart pub get` and `melos …` from root.
dart pub get                                   # resolves the whole workspace
cd dart/engine && dart test                    # full engine test suite
cd dart/engine && dart test --name "pattern"   # single test by name
cd dart/encoder && dart test                   # encoder tests
cd dart/compiler && dart run bin/compile.dart ../../examples/hello_world/hello_world.ball.json
cd dart/engine   && dart run bin/engine.dart   ../../examples/hello_world/hello_world.ball.json

# C++ — CMake; buf auto-regenerates protos if buf CLI is on PATH
cd cpp && mkdir -p build && cd build && cmake .. && cmake --build .
cmake --build cpp/build --target buf_lint     # also: buf_format, buf_breaking, buf_check

# TypeScript — shared protobuf types
cd ts/shared && npm install && npm test          # protobuf-es binding tests

# TS engine tests (self-hosted compiled engine, conformance tests)
cd ts/engine && npm test

# TS compiler tests (including compiled engine conformance)
cd ts/compiler && npm install && npm test

# Regenerate compiled TS engine from self-hosted Ball source.
# engine.ball.json is a self-describing google.protobuf.Any envelope
# ({"@type":"…/ball.v1.Program", …}); strip @type before compiling.
cd ts/compiler && node --experimental-strip-types -e "
const {readFileSync, writeFileSync} = require('fs');
const {compile} = require('./src/index.ts');
function unwrapBallFile(json){ if(json===null||typeof json!=='object'||Array.isArray(json))return json; const t=json['@type']; if(t===undefined)return json; const b={}; for(const[k,v]of Object.entries(json)){if(k!=='@type')b[k]=v;} return b; }
const program = unwrapBallFile(JSON.parse(readFileSync('../../dart/self_host/engine.ball.json', 'utf8')));
const ts = compile(program);
writeFileSync('../engine/src/compiled_engine.ts', '// @ts-nocheck — auto-generated\n' + ts);
"

# Regenerate compiled TS CLI core (ts/cli's info/validate/tree/version verbs —
# issue #364) from the self-hosted cli_core.dart source. Same pipeline as
# "Regenerate compiled TS engine" above, plus an export-rewrite pass:
# cli_core.dart is a free-function library (not a single class like
# engine.dart), so its compiled top-level functions need `export` added
# explicitly — BallCompiler.compile()'s own class-export logic only covers
# top-level *classes*. First regenerate the (gitignored) IR artifact:
cd dart && dart run compiler/tool/gen_cli_json.dart
cd ts/compiler && node --experimental-strip-types -e "
const {readFileSync, writeFileSync} = require('fs');
const {compile} = require('./src/index.ts');
function unwrapBallFile(json){ if(json===null||typeof json!=='object'||Array.isArray(json))return json; const t=json['@type']; if(t===undefined)return json; const b={}; for(const[k,v]of Object.entries(json)){if(k!=='@type')b[k]=v;} return b; }
const program = unwrapBallFile(JSON.parse(readFileSync('../../dart/self_host/cli.ball.json', 'utf8')));
let ts = compile(program);
ts = ts.replace(/^(function )/gm, 'export \$1');
ts = ts.replace(/^(class )/gm, 'export \$1');
ts = ts.replace(/^(enum )/gm, 'export \$1');
ts = ts.replace(/^(let )/gm, 'export \$1');
ts = ts.replace(/^(const )/gm, 'export \$1');
ts = ts.replace(/^export export /gm, 'export ');
writeFileSync('../cli/src/compiled_cli.ts', '// @ts-nocheck — auto-generated\n' + ts);
"
# Then re-run ts/cli's suite (npm test in ts/cli — includes the parity gate
# against the native Dart CLI, test/cli_core_parity.test.ts).

# Rust — cargo is not on native Windows in this environment; build/test via
# WSL. rust-toolchain.toml pins the stable channel + rustfmt/clippy.
cd rust && cargo build --workspace
cargo test --workspace            # ball-lang-engine's compiled-engine driver is
                                   # feature-gated off by default (see
                                   # rust/AGENTS.md), so this stays green
                                   # without requiring the generated,
                                   # gitignored compiled_engine.rs
cargo fmt --check && cargo clippy --workspace

# Regenerate the Rust self-hosted engine (compiles and RUNS the whole
# conformance corpus at Dart parity — see rust/engine/AGENTS.md; produces the
# gitignored src/compiled_engine.rs, driven behind the off-by-default
# `self_host` cargo feature since the generated file isn't present in a
# fresh checkout)
cd rust && cargo run -p ball-engine-regen
cargo test -p ball-lang-engine --features self_host --test self_host_conformance -- --ignored --nocapture

# C# — .NET 10 SDK is native on Windows, no WSL needed. Solution is csharp/Ball.slnx;
# Central Package Management pins versions in csharp/Directory.Packages.props.
cd csharp && dotnet build Ball.slnx && dotnet test Ball.slnx
dotnet format Ball.slnx --verify-no-changes   # run `dotnet format` (no flag) to fix

# Regenerate the C# self-hosted engine (dart/self_host/engine.ball.pb -> CompiledEngine.cs,
# gitignored, only in the build under -p:SelfHost=true — see csharp/AGENTS.md)
cd dart && dart run compiler/tool/compile_engine_cpp.dart   # writes engine.ball.pb (the trailing
                                                              # C++ emit step errors when
                                                              # ball_cpp_compile is absent —
                                                              # harmless, the .pb is already written
cd ../csharp && dotnet run --project engine/tool/Ball.Engine.Regen.csproj
dotnet test engine/test/Ball.Engine.Tests.csproj -p:SelfHost=true --filter "FullyQualifiedName~SelfHostRunTests"

# Regenerate the C# self-hosted CLI core (dart/self_host/cli.ball.json -> CompiledCli.cs,
# gitignored, only in the build under -p:CliCore=true — see csharp/AGENTS.md)
cd dart && dart run compiler/tool/gen_cli_json.dart
cd ../csharp && dotnet run --project cli/tool/Ball.Cli.Regen.csproj
dotnet test cli/test/Ball.Cli.Tests.csproj -p:CliCore=true -p:SelfHost=true

# Proto — lint, breaking-change check, regenerate all bindings
# NOTE: buf.yaml lives at proto/buf.yaml (not repo root), so `proto` MUST be
# passed as the explicit input — a bare `buf generate`/`buf lint` run from
# the repo root does not discover that module and silently mis-resolves
# paths (e.g. emits gen/proto/ball/v1/... instead of gen/ball/v1/...).
buf lint proto/
buf breaking proto/ --against ".git#subdir=proto"
buf generate proto

# After editing dart/shared/lib/std.dart, regenerate std.json/std.bin
cd dart/shared && dart run bin/gen_std.dart

# Self-hosted CLI verbs: after editing dart/shared/lib/cli_core.dart, regenerate
# the (gitignored) cli.ball.json + cli.ball.pb so the parity gate can run them
# on the engine (mirrors gen_engine_json.dart). CI regenerates these too.
cd dart && dart run compiler/tool/gen_cli_json.dart

# Single-source the `ball` CLI version from pubspec.yaml (#363). Regenerate
# lib/version.g.dart after a version bump; --check is the CI drift guard.
cd dart/cli && dart run tool/gen_version.dart          # regenerate
cd dart/cli && dart run tool/gen_version.dart --check  # CI drift guard

# Upstream protobuf conformance for ball_protobuf (Editions) — POSIX-only
# runner; build/run on Linux/macOS/WSL, not native Windows. See
# dart/ball_protobuf/conformance/README.md.
cmake -S cpp -B cpp/build-conformance -Dprotobuf_BUILD_CONFORMANCE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build-conformance --target conformance_test_runner -j
dart compile exe dart/ball_protobuf/tool/conformance_main.dart -o ball_conformance
"$(find cpp/build-conformance -name conformance_test_runner -type f | head -1)" \
  --maximum_edition 2023 ./ball_conformance
```

## Core Invariants — Never Violate

1. **One input, one output per function** (gRPC-style). Not a limitation — it is the design. Don't add multi-parameter functions.
2. **Metadata is cosmetic.** Stripping all metadata must never change what a program computes. Semantic content = expression tree, function signatures, type descriptors, module structure. Everything else lives in `google.protobuf.Struct metadata` fields.
3. **Base functions have no body.** Their implementation is supplied per-platform by the target compiler/engine — this is the extensibility mechanism.
4. **Control flow is function calls.** `if`, `for`, `while`, `for_each` are std base functions. Compilers and engines MUST evaluate them lazily — never eagerly evaluate all branches before choosing one.
5. **Never edit generated files:** `dart/shared/lib/gen/**`, `ts/shared/gen/**`, `rust/shared/gen/**`, `csharp/shared/gen/**`, `ts/engine/src/compiled_engine.ts`, `csharp/engine/src/CompiledEngine.cs` (gitignored; `csharp/engine/tool`), `csharp/cli/src/CompiledCli.cs` (gitignored; `csharp/cli/tool`), `dart/shared/std.json`, `dart/shared/std.bin`, `dart/self_host/cli.ball.json`, `dart/self_host/cli.ball.pb` (gitignored; `gen_cli_json.dart`), `dart/cli/lib/version.g.dart` (`gen_version.dart`). Regenerate via `buf generate proto`, `gen_std.dart`, or the TS/C# engine regeneration commands above. (The C++ target is libprotobuf-free since #18 Stage 5 — there is no `cpp/shared/gen/` and no cpp plugin in `buf.gen.yaml`.)

## Architecture Big Picture

Every Ball computation is one of seven `Expression` node types: `call`, `literal`, `reference`, `fieldAccess`, `messageCreation`, `block`, `lambda`. The special reference name `"input"` always means "this function's parameter." Understanding this tree is the key to reading both compilers (`DartCompiler.compile` / the C++ string-based emitter) and engines (tree-walking interpreters with lexical `Scope` chains and `FlowSignal` for break/continue/return).

### Dart workspace (`dart/`)
Five packages resolved as a workspace:
- `ball_base` (`shared/`) — protobuf types + std module builders; dependency for the rest.
- `ball_compiler` — Ball → Dart via `code_builder` + `dart_style`. Base-function dispatch lives in `_compileBaseCall`; extract fields from the `MessageCreation` input.
- `ball_encoder` — Dart → Ball via the `analyzer` package. All constructs (including cascade, null-aware access, spread, invoke) encode to the universal `std` module.
- `ball_engine` — tree-walking interpreter. `StdModuleHandler` dispatches all universal `std` base functions; custom modules implement `BallModuleHandler`.
- `ball_cli` — CLI entry point.

Types are emitted from `typeDefs[]` only — each `TypeDefinition` carries the protobuf descriptor plus a cosmetic `metadata` bag. The former `Module.types` field (bare descriptors) and the `_meta_*` function hack were removed; `typeDefs[]` is the single type-declaration path.

#### Protobuf consumer codegen (`ball_protobuf_gen` + `ball_rpc`)

Two additional (non-Ball-portable) Dart packages turn a user's `.proto` into typed models + service stubs bound to the `ball_protobuf` runtime:
- `ball_protobuf_gen` (`dart/ball_protobuf_gen/`) — the protoc/buf plugins `protoc-gen-ball` (message/enum/extension models → `.pb.dart`), `protoc-gen-ball-connect` (`.connect.dart`), and `protoc-gen-ball-grpc` (`.grpc.dart`). Generated models are thin: a mutable typed view over a `Map<String,Object?>` backing store plus an embedded resolved-Editions descriptor; all wire/JSON work delegates to the conformance-pinned `ball_protobuf` runtime (no serialization code is generated). Depends on `ball_base` + `ball_protobuf`.
- `ball_rpc` (`dart/ball_rpc/`) — the Dart-target transport runtime generated service clients delegate to: `ConnectTransport`, `GrpcTransport` (over a pluggable `GrpcByteSender`), `FakeTransport`, and the shared `RpcCode`/`RpcException` status model.

**Dart is the shipped target; C++/TS library targets are roadmap.** Full design, status, and the verified multi-target findings live in `docs/PROTOBUF_CODEGEN_PLAN.md`. These packages are independent of the repo's own `buf generate` bindings — do **not** wire them into the root `buf.gen.yaml`.

### C++ prototype (`cpp/`)
- `BallValue = std::any`, `BallList = std::vector<BallValue>`, `BallMap = std::map<std::string, BallValue>` (ordered — **not** `unordered_map`).
- Compiler emits C++ via string concatenation; blocks become immediately-invoked lambdas.
- Encoder consumes Clang JSON AST (`clang -Xclang -ast-dump=json`) and directly emits universal `std`/`std_memory` calls (C++ pointer ops are inlined during encoding).
- Stack sizes are bumped for deep protobuf ASTs: compiler 128 MB, encoder 256 MB; engine has 65 KB linear memory.

### TypeScript workspace (`ts/`)

Five packages (no workspace manager — each has its own `node_modules`):

- `@ball-lang/shared` (`shared/`) — protobuf-es generated types from `ball.proto` (via `buf generate`). Depends on `@bufbuild/protobuf` v2. Provides typed messages with discriminated unions for oneofs (`expr.expr.case === "call"`), JSON/binary serialization (`fromJson`/`toJson`/`fromBinary`/`toBinary` from `@bufbuild/protobuf`), and presence checking (`field !== undefined`). API mapping from Dart protobuf: `whichExpr()` -> `expr.case`, `hasBody()` -> `body !== undefined`, `metadata.fields['key'].whichKind()` -> `typeof metadata?.['key']`.
- `@ball-lang/compiler` — Ball -> TypeScript. Uses `ts-morph`. The preamble (`preamble.ts`) installs Dart-flavored polyfills (`whichExpr()`, `hasBody()`, etc.) on `Object.prototype` so compiled Dart code can call proto-style methods on plain JSON objects.
- `@ball-lang/engine` — Self-hosted engine: `compiled_engine.ts` is generated by compiling `dart/self_host/engine.ball.json` through `@ball-lang/compiler`. `index.ts` wraps it with proto3 JSON normalization (protoWrap), method dispatch handlers, and extra std function registrations. `run()` is async (returns `Promise<string[]>`).
- `@ball-lang/encoder` — TS -> Ball via the TypeScript Compiler API. Functional and CI-gated: routes through universal `std` (no `ts_std`); 100+ encoder/conformance/round-trip tests.
- `@ball-lang/cli` (`cli/`) — CLI entry point. `run` executes via `@ball-lang/engine`; `info`/`validate`/`tree`/`version`/`audit` are all self-hosted (`compiled_cli.ts`, compiled from `dart/shared/lib/cli_core.dart` the same way `compiled_engine.ts` is — see "Regenerate compiled TS CLI core" above), wrapped by a small `cli_core.ts` normalizer. `audit`'s capability + termination analyzers self-host too since #362 (the hand-ported `capability_analyzer.ts`/`capability_table.ts` are gone) — `cli_core.ts` deep-materializes the expression tree the compiled analyzers walk (the TS analog of the Dart parity gate's `protoToEngineMap`). `index.ts` `await import()`s each compiled engine lazily, inside its own command handler — never at module top level — because two independently-compiled Ball TS artifacts loaded in the same process corrupt each other's `Map.prototype` monkey-patch (see `ts/cli/AGENTS.md`).

### Rust workspace (`rust/`)

Cargo workspace (`rust/Cargo.toml`, `resolver = "3"`) with five member crates plus one internal
tool crate — see `rust/AGENTS.md` for the full status table:

- `ball-lang-shared` — protobuf bindings (`prost` + `prost-reflect`, generated via the
  `buf.build/community/neoeinstein-prost` plugin into `rust/shared/gen/`) plus the runtime value
  model (`BallValue`/`BallList`/`BallMap` backed by `indexmap::IndexMap`/`BallFunction`/
  `BallMessage`) and std/std_collections/std_io/std_memory module builders.
- `ball-lang-compiler` — Ball → Rust. Emits Rust source as strings (closer to the C++ compiler's
  approach than Dart's `code_builder`); `Block` compiles to a native Rust block expression
  (already tail-expression-valued, unlike C++'s IIFE pattern). Base-function dispatch lives in
  `base_call.rs`, delegating to `ball_lang_shared::runtime`. Complete (#36-38).
- `ball-lang-encoder` — Rust (`syn` 2.x AST) → Ball. No `rust_std` base module — every construct
  routes through universal `std`/`std_collections`. Complete (#42-43).
- `ball-lang-engine` — self-hosted engine (SKILL.md Phase 4 Option B), same approach as TS/C++:
  compiles `dart/self_host/engine.ball.json` through `ball-lang-compiler`. **Complete, at Dart
  parity** (#39/#300 closed): the compiled engine builds and runs the whole conformance corpus
  with Dart-identical output (`Results: 319 passed, 0 failed, 319 total`; the 4 golden-less
  resource-limit/sandbox fixtures are documented carve-outs). Still behind the off-by-default
  `self_host` cargo feature because `compiled_engine.rs` is a gitignored generated artifact not
  present in a fresh checkout — see `rust/engine/AGENTS.md` for the regeneration workflow.
- `ball-lang-cli` — `run`/`compile`/`encode`/`check` subcommands over `ball-lang-engine`/`ball-lang-compiler`/
  `ball-lang-encoder`. Complete (#41/#304).

The conformance harness (#40) is `rust/engine/tests/self_host_conformance.rs`, and CI job (#44)
is the `rust` job in `.github/workflows/ci.yml` plus the `rust-engine` row in
`conformance-matrix.yml` — both gate on full parity.

### Standard library modules
Eight universal modules ship in `dart/shared/lib/` (`std*.dart`): `std` (arithmetic, comparison, logic, bitwise, strings, math, control flow, type ops, cascade, null_aware_access, invoke, spread, record, etc. — `dart/shared/std.json` is the canonical base-function inventory), `std_collections` (list/map/set), `std_io` (console/process/time/random), `std_memory` (linear-memory fns for C/C++ interop), `std_convert` (JSON/UTF-8/base64), `std_fs` (file/directory ops), `std_time` (clock, timestamp format/parse, duration arithmetic), and `std_concurrency` (threads, mutexes, atomics). The `dart_std`/`cpp_std`/`ts_std` modules have been eliminated — all functions now route through universal `std`.

### Portable protobuf engine + Editions (`ball_protobuf` package — `dart/ball_protobuf/lib/`)
A pure-Dart, descriptor-driven protobuf runtime (wire codecs, binary marshal/unmarshal, proto3-JSON codec, well-known types, gRPC framing) authored in **Ball-portable Dart** so it encodes to a Ball library and runs on every target. It lives in its **own publishable workspace package** `ball_protobuf` (re-exported by `ball_base.dart` for back-compat; the engine itself has zero package deps). It is **Editions-aware**: `edition.dart` + `editions.dart` implement the FeatureSet model and protoc's canonical resolution algorithm + proto2/proto3 legacy inference; `marshal.dart`/`unmarshal.dart`/`json_codec.dart` honor the resolved features (presence, open/closed enum, packed/expanded, DELIMITED groups, utf8_validation, json_format) when a field descriptor carries an optional `'features'` key (absent ⇒ proto3 defaults, zero regression).
- **Compiled artifact `ball_protobuf.{json,bin}`** (`dart/shared/`, a build output — not part of the published source package): a facade **`ball.v1.Module`** whose `module_imports[]` embed each impl module inline via `InlineSource` (NOT a `Program` — it has no entry point). Regenerate with `cd dart/encoder && dart run bin/gen_ball_protobuf.dart` (reads sources from `dart/ball_protobuf/lib/`).
- **Spec:** `docs/EDITIONS_SPEC.md` (the §3 feature tables + known limitations; roadmap/status is tracked as GitHub issues, not a checked-in plan doc).
- **Golden defaults:** `tests/editions/featureset_defaults.binpb` (from protoc 35.1, max edition 2024 — EDITION_2024's runtime feature defaults are golden-verified identical to EDITION_2023's; EDITION_2026 is not yet a published edition in any stable protoc release). Refresh on protoc upgrade with `tools/gen_edition_defaults.{ps1,sh}` (supports `--check` drift mode, and a `-MaxEdition`/`--max-edition=` override). The golden-driven test in `dart/ball_protobuf/test/editions_test.dart` asserts the hand-authored defaults table matches that binpb (CI drift guard).
- **Portability proof:** `tests/conformance/256_editions_resolver.ball.json` runs the real resolver through the Dart/TS/C++ engines (golden-exact); see `tests/editions/portability_matrix.md`. Regenerate with `dart/encoder/tool/gen_editions_conformance.dart`.
- **Legacy↔editions parity harness:** `dart/ball_protobuf/tool/editions_conformance.dart` (also a CI step).

## Adding a New Language

To add full Ball support for a new programming language (compiler + encoder + engine + CLI +
conformance + CI/CD), follow the **new-ball-language** skill at
`.claude/skills/new-ball-language/SKILL.md`. It has 8 phases:

1. **Directory scaffold & proto bindings** — create `<lang>/` tree, add to `buf.gen.yaml`
2. **Compiler** (Ball → target language) — expression compilation + base function dispatch
3. **Encoder** (target language → Ball) — parser integration + AST-to-Ball mapping
4. **Engine** — self-hosted (recommended: compile `dart/self_host/engine.ball.json`) or hand-written
5. **CLI** — `ball run`, `ball compile`, `ball encode` subcommands
6. **Conformance tests** — wire `tests/conformance/*.ball.json`, output `Results: N passed, M failed, T total`
7. **CI/CD** — add jobs to `ci.yml` and `conformance-matrix.yml`
8. **Documentation** — `<lang>/AGENTS.md`, `.claude/rules/<lang>.md`, update root docs

Supporting configs:

- Agent: `.claude/agents/ball-lang-bootstrapper.md` — orchestrates the full bootstrap
- Rule: `.claude/rules/new-language.md` — auto-activates when editing new language dirs
- Existing skills (`ball-compiler`, `ball-encoder`, `ball-engine`) cover component internals
- Plugin: `plugins/ball/` ships `/ball:convert` (cross-language codebase conversion, usable in ANY repo) plus `/ball:new`/`/ball:iterate` wrappers, distributed via this repo's plugin marketplace (`.claude-plugin/marketplace.json`). The canonical `/ball-new`/`/ball-iterate` contracts stay in `.claude/skills/`; keep the plugin wrappers as thin pointers, never fork the content

## Typical Feature Workflow

1. Does it need a schema change? Edit `proto/ball/v1/ball.proto`, then `buf lint` → `buf breaking ...` → `buf generate`.
2. Does it need a new std function? Edit `dart/shared/lib/std.dart`, then rerun `gen_std.dart`.
3. Implement in `dart/compiler/lib/compiler.dart`.
4. Implement in `dart/engine/lib/engine.dart`. **Fail loud** on any shape you do
   not handle — never return `null`/`[]`/a placeholder string (that silent
   degradation is what hid issue #55).
5. Add a test in `dart/engine/test/engine_test.dart` (helpers: `buildProgram()`, `runAndCapture()`, `loadProgram()`).
6. **Add a conformance fixture** `tests/conformance/src/NN_<name>.dart` that
   actually exercises the construct, then `cd dart/encoder && dart run
   bin/generate_conformance.dart`. CI-gated: every std base function the encoder
   can emit MUST appear in an executed fixture
   (`check_encoder_completeness.dart`) or a documented carve-out, and a fixture's
   name must match its content (`check_fixture_names.dart`). See
   `docs/TESTING_STRATEGY.md`.
7. Regenerate self-hosted engines: `cd dart && dart run compiler/tool/gen_engine_json.dart`, then `dart run compiler/tool/compile_engine_cpp.dart` (C++) and regen `compiled_engine.ts` (TS, see Build & Test). **Re-run conformance on ALL THREE engines** — a Dart-only fix is half a fix. If you touched the portable CLI verbs (`dart/shared/lib/cli_core.dart`), also regenerate the self-hosted CLI: `dart run compiler/tool/gen_cli_json.dart`, then re-run the parity gate (`cd dart/cli && dart test test/cli_core_parity_test.dart`).
8. If new metadata keys were introduced, update `docs/METADATA_SPEC.md`.

## Examples Layout

Each example lives at `examples/<name>/` with `<name>.ball.json` (proto3 JSON Ball program) and optional `dart/` / `cpp/` compiled outputs. Every program must define the std module with all base functions/types it uses; user functions carry a `body` expression tree, base functions set `"isBase": true` with no body.
