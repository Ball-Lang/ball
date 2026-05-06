# Ball Project Agents

**Generated:** 2026-05-05 | **Commit:** e9d2668 | **Branch:** main

This file provides instructions for AI coding agents working on the Ball project.

## Project Context

Ball is a programming language where code is structured protobuf messages. The project has:
- A **mature Dart implementation** (compiler, encoder, engine, CLI)
- A **prototype C++ implementation** (compiler, encoder with normalizer, engine)
- **Proto bindings** for Go, Python, TypeScript, Java, C# (no implementations)

## Build & Test

```bash
# Dart — test the engine
cd dart && dart pub get
cd dart/engine && dart test

# Dart — test the compiler (skip slow cross-language with -x slow)
cd dart/compiler && dart test

# Dart — test the encoder
cd dart/encoder && dart test

# Dart — compile an example
cd dart/compiler && dart run bin/compile.dart ../../examples/hello_world.ball.json

# C++ — build all (buf generate runs automatically if buf is on PATH)
cd cpp/build && cmake .. && cmake --build .

# C++ — run tests
cd cpp/build && cmake .. && cmake --build . && ctest --output-on-failure
# Single suite: ctest -R engine_tests

# C++ — buf targets (lint, format, breaking check)
cmake --build cpp/build --target buf_lint
cmake --build cpp/build --target buf_format
cmake --build cpp/build --target buf_check    # lint + format combined

# C++ — manual proto regeneration (without CMake)
buf generate --template cpp/buf.gen.cpp.yaml -o cpp/shared/gen proto/

# TypeScript — test engine
cd ts/engine && npm install && npm test

# Proto — lint and generate (all languages)
buf lint
buf generate
```

## Key Invariants — NEVER Violate These

1. **One input, one output per function** — like gRPC. Don't add multi-parameter functions.
2. **Metadata is cosmetic** — stripping all metadata must not change what a program computes.
3. **Base functions have no body** — their implementation is per-platform.
4. **Control flow is function calls** — if/for/while are std functions with lazy evaluation.
5. **Never edit generated files** — `dart/shared/lib/gen/`, `cpp/shared/gen/`, `std.json`, `std.bin`

## Critical Known Issues

- C++ `string_split`/`string_replace`/`string_replace_all` emit empty comments (BROKEN)
- C++ `std_collections` and `std_io` modules are stubs (declared, not implemented)
- Dart encoder silently swallows malformed metadata

## File Organization

| Path | What it is | Editable? |
|------|-----------|-----------|
| `proto/ball/v1/ball.proto` | Language schema | Yes — run `buf lint` + `buf generate` after |
| `dart/shared/lib/std.dart` | Std library definition | Yes — run `gen_std.dart` after |
| `dart/shared/std.json` | Compiled std module | NO — generated |
| `dart/shared/lib/gen/` | Protobuf Dart types | NO — generated |
| `cpp/shared/gen/` | Protobuf C++ types | NO — generated |
| `dart/compiler/lib/compiler.dart` | Reference compiler | Yes |
| `dart/encoder/lib/encoder.dart` | Reference encoder | Yes |
| `dart/engine/lib/engine.dart` | Reference interpreter | Yes |
| `dart/engine/test/engine_test.dart` | Engine tests | Yes — add tests here |
| `ts/engine/src/engine.ts` | TypeScript engine (browser + Node) | Yes |
| `ts/compiler/src/compiler.ts` | TypeScript compiler | Yes |
| `cpp/shared/include/ball_runtime.h` | C++ runtime/type system | Yes |
| `website/` | ball-lang.dev + playground (Jaspr) | Yes |

## When Implementing a Feature

1. Check if it needs a proto schema change → edit `ball.proto`, lint, generate
2. Check if it needs a new std function → edit `dart/shared/lib/std.dart`, regenerate
3. Implement in Dart engine (`engine.dart`) — behavior is defined HERE
4. Implement in Dart compiler (`compiler.dart`)
5. **MAXIMIZE e2e conformance tests** — a single `.ball.json` fixture in `tests/conformance/` validates ALL engines (Dart, C++, TS) simultaneously. Prefer conformance tests over per-language unit tests.
6. If C++ is affected: implement in both `cpp/compiler/` and `cpp/engine/`
7. Add engine unit tests ONLY for engine-internal behavior not expressible as a Ball program
8. Update `docs/METADATA_SPEC.md` if new metadata keys are introduced

## Codebase Search (SocratiCode)

This project is indexed with SocratiCode. Always use its MCP tools to explore the codebase
before reading any files directly.

### Workflow

1. **Start most explorations with `codebase_search`.**
   Hybrid semantic + keyword search (vector + BM25, RRF-fused) runs in a single call.
   - Use broad, conceptual queries for orientation: "how is authentication handled",
     "database connection setup", "error handling patterns".
   - Use precise queries for symbol lookups: exact function names, constants, type names.
   - Prefer search results to infer which files to read — do not speculatively open files.
   - **When to use grep instead**: If you already know the exact identifier, error string,
     or regex pattern, grep/ripgrep is faster and more precise — no semantic gap to bridge.
     Use `codebase_search` when you're exploring, asking conceptual questions, or don't
     know which files to look in.

2. **Follow the graph before following imports.**
   Use `codebase_graph_query` to see what a file imports and what depends on it before
   diving into its contents. This prevents unnecessary reading of transitive dependencies.
   - **Before modifying or deleting a file**, check its dependents with `codebase_graph_query`
     to understand the blast radius.
   - **When planning a refactor**, use the graph to identify all affected files before
     making changes.

3. **Use Impact Analysis BEFORE refactoring, renaming, or deleting code.**
   The symbol-level call graph (`codebase_impact`, `codebase_flow`, `codebase_symbol`,
   `codebase_symbols`) goes one step deeper than the file graph: it knows which
   functions and methods call which.
   - `codebase_impact` answers "what breaks if I change X?" (blast radius — every file
     that transitively calls into the target).
   - `codebase_flow` answers "what does this code do?" by tracing forward from an entry
     point. Call with no `entrypoint` to discover candidate entry points (auto-detected
     via orphans, conventional names like `main()`, framework routes, tests).
   - `codebase_symbol` gives a 360° view of one function: definition, callers, callees.
   - `codebase_symbols` lists symbols in a file or searches by name.
   - Always prefer these over reading multiple files when the question is about
     dependencies between functions, not concepts.

4. **Read files only after narrowing down via search.**
   Once search results clearly point to 1–3 files, read only the relevant sections.
   Never read a file just to find out if it's relevant — search first.

5. **Use `codebase_graph_circular` when debugging unexpected behaviour.**
   Circular dependencies cause subtle runtime issues; check for them proactively.
   Also run `codebase_graph_circular` when you notice import-related errors or unexpected
   initialisation order.

6. **Check `codebase_status` if search returns no results.**
   The project may not be indexed yet. Run `codebase_index` if needed, then wait for
   `codebase_status` to confirm completion before searching.

7. **Leverage context artifacts for non-code knowledge.**
   Projects can define a `.socraticodecontextartifacts.json` config to expose database
   schemas, API specs, infrastructure configs, architecture docs, and other project
   knowledge that lives outside source code. These artifacts are auto-indexed alongside
   code during `codebase_index` and `codebase_update`.
   - Run `codebase_context` early to see what artifacts are available.
   - Use `codebase_context_search` to find specific schemas, endpoints, or configs
     before asking about database structure or API contracts.
   - If `codebase_status` shows artifacts are stale, run `codebase_context_index` to
     refresh them.

### When to use each tool

| Goal | Tool |
|------|------|
| Understand what a codebase does / where a feature lives | `codebase_search` (broad query) |
| Find a specific function, constant, or type | `codebase_search` (exact name) or grep if you know already the exact string |
| Find exact error messages, log strings, or regex patterns | grep / ripgrep |
| See what a file imports or what depends on it | `codebase_graph_query` |
| Check blast radius before modifying or deleting a file | `codebase_impact` (symbol-level) or `codebase_graph_query` (file-level) |
| **What breaks if I change function X?** | `codebase_impact target=X` |
| **What does this entry point actually do?** | `codebase_flow entrypoint=X` |
| **List entry points in this codebase** | `codebase_flow` (no args) |
| **Who calls this function and what does it call?** | `codebase_symbol name=X` |
| **What functions/classes exist in this file?** | `codebase_symbols file=path` |
| **Search for symbols by name across the project** | `codebase_symbols query=X` |
| Spot architectural problems | `codebase_graph_circular`, `codebase_graph_stats` |
| Visualise module structure | `codebase_graph_visualize` |
| Verify index is up to date | `codebase_status` |
| Discover what project knowledge (schemas, specs, configs) is available | `codebase_context` |
| Find database tables, API endpoints, infra configs | `codebase_context_search` |