# TypeScript Implementation Agents

**Generated:** 2026-05-05 | **Commit:** e9d2668 | **Branch:** main

TypeScript implementation of Ball tools. Runs in browser and Node.js. **Always reference the Dart implementation** as the canonical behavior.

## Package Layout

| Package | Purpose | npm |
|---------|---------|-----|
| `ts/engine` | Runtime interpreter (browser + Node) | `@ball-lang/engine` |
| `ts/compiler` | Ball → TypeScript code generation | `@ball-lang/compiler` |
| `ts/encoder` | TypeScript source → Ball Program | `@ball-lang/encoder` |
| `ts/cli` | CLI for TS tools | `@ball-lang/cli` |
| `ts/shared` | Protobuf types (generated) | `@ball-lang/shared` |

## Build & Test

**Prefer conformance tests over unit tests.** The TS engine is validated primarily through conformance fixtures (`tests/conformance/`) shared with Dart and C++ engines. Per-language unit tests should be minimal — only for TS-specific edge cases (browser API handling, event loop differences).

```bash
# Install + test engine
cd ts/engine && npm install && npm test

# Test compiler
cd ts/compiler && npm install && npm test

# Test encoder
cd ts/encoder && npm install && npm test
```

## Conventions

- Each package has `package.json`, `tsconfig.json`, `vitest` config
- Generated protobuf types in `ts/shared/gen/` — NEVER edit
- Compiler entry: `ts/compiler/bin/ball-ts-compile.mjs` (called by Dart compiler runner)
- **Engine is validated against shared conformance fixtures** — test via `tests/conformance/`, not engine-specific tests
- Compiler round-trips: 37/37 Dart fixtures → TS → byte-identical on Node
- Full `engine.dart` parses cleanly through the TS compiler

## Publishing

- npm publishing via OIDC trusted publishing (`.github/workflows/publish-npm.yml`)
- Packages published individually

## Key Differences from Dart

- TS engine: single-threaded async (no isolates), browser-compatible
- TS compiler: uses ts-morph in-process (no shell-out)
- TS encoder: AST-based source transformation
- No `dart_std` module — Dart-specific base functions (`cascade`, `nullAwareAccess`, `spread`) are not implemented
