# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Ball Is

Ball is a programming language where every program is a Protocol Buffer message (`proto/ball/v1/ball.proto` is the single source of truth). Compilers translate Ball programs into target-language source, encoders do the reverse, and engines interpret Ball programs directly. Dart is the reference implementation (compiler + encoder + engine + CLI, broadest std coverage). **TypeScript** is a full pipeline too — compiler, self-hosted engine, and encoder — all CI-gated (the engine passes the conformance corpus; the encoder round-trips TS→Ball→target through universal `std`, with no `ts_std`). **C++** has a compiler, encoder (Clang AST → Ball), and self-hosted engine, with the self-host conformance passing **every** fixture; it still FetchContents upstream protobuf (#18/#25). **Go/Python/Java/C#** ship proto bindings only; **Rust** is unstarted (epic #32). Statuses drift — verify maturity against CI (`.github/workflows/ci.yml`), not this prose.

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

# Proto — lint, breaking-change check, regenerate all bindings
buf lint
buf breaking --against ".git#subdir=proto"
buf generate

# After editing dart/shared/lib/std.dart, regenerate std.json/std.bin
cd dart/shared && dart run bin/gen_std.dart

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
5. **Never edit generated files:** `dart/shared/lib/gen/**`, `cpp/shared/gen/**`, `ts/shared/gen/**`, `ts/engine/src/compiled_engine.ts`, `dart/shared/std.json`, `dart/shared/std.bin`. Regenerate via `buf generate`, `gen_std.dart`, or the TS engine regeneration command above.

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
- `@ball-lang/cli` (`cli/`) — CLI entry point.

### Standard library modules
`std` (118 fns: arithmetic, comparison, logic, bitwise, strings, math, control flow, type ops, cascade, null_aware_access, invoke, spread, record, etc.), `std_collections` (53 list/map/set fns), `std_io` (10 console/process/time/random), `std_memory` (38 linear-memory fns for C/C++ interop). The `dart_std` module has been eliminated — all functions now route through universal `std`.

### Portable protobuf engine + Editions (`ball_protobuf` package — `dart/ball_protobuf/lib/`)
A pure-Dart, descriptor-driven protobuf runtime (wire codecs, binary marshal/unmarshal, proto3-JSON codec, well-known types, gRPC framing) authored in **Ball-portable Dart** so it encodes to a Ball library and runs on every target. It lives in its **own publishable workspace package** `ball_protobuf` (re-exported by `ball_base.dart` for back-compat; the engine itself has zero package deps). It is **Editions-aware**: `edition.dart` + `editions.dart` implement the FeatureSet model and protoc's canonical resolution algorithm + proto2/proto3 legacy inference; `marshal.dart`/`unmarshal.dart`/`json_codec.dart` honor the resolved features (presence, open/closed enum, packed/expanded, DELIMITED groups, utf8_validation, json_format) when a field descriptor carries an optional `'features'` key (absent ⇒ proto3 defaults, zero regression).
- **Compiled artifact `ball_protobuf.{json,bin}`** (`dart/shared/`, a build output — not part of the published source package): a facade **`ball.v1.Module`** whose `module_imports[]` embed each impl module inline via `InlineSource` (NOT a `Program` — it has no entry point). Regenerate with `cd dart/encoder && dart run bin/gen_ball_protobuf.dart` (reads sources from `dart/ball_protobuf/lib/`).
- **Spec:** `docs/EDITIONS_SPEC.md` (the §3 feature tables + known limitations). **Plan:** `docs/EDITIONS_PLAN.md`.
- **Golden defaults:** `tests/editions/featureset_defaults.binpb` (from protoc 28.2). Refresh on protoc upgrade with `tools/gen_edition_defaults.{ps1,sh}` (supports `--check` drift mode). The golden-driven test in `dart/ball_protobuf/test/editions_test.dart` asserts the hand-authored defaults table matches that binpb (CI drift guard).
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
7. Regenerate self-hosted engines: `cd dart && dart run compiler/tool/gen_engine_json.dart`, then `dart run compiler/tool/compile_engine_cpp.dart` (C++) and regen `compiled_engine.ts` (TS, see Build & Test). **Re-run conformance on ALL THREE engines** — a Dart-only fix is half a fix.
8. If new metadata keys were introduced, update `docs/METADATA_SPEC.md`.

## Examples Layout

Each example lives at `examples/<name>/` with `<name>.ball.json` (proto3 JSON Ball program) and optional `dart/` / `cpp/` compiled outputs. Every program must define the std module with all base functions/types it uses; user functions carry a `body` expression tree, base functions set `"isBase": true` with no body.
