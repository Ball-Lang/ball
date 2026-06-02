# TypeScript Implementation Agents

TypeScript implementation of Ball tools. The engine is **self-hosted** (compiled from the Dart reference engine); runs in browser and Node.js. **Always reference the Dart implementation** as the canonical behavior.

## Package Layout

| Package | Purpose | npm |
|---------|---------|-----|
| `ts/engine` | Runtime interpreter (browser + Node) | `@ball-lang/engine` |
| `ts/compiler` | Ball → TypeScript code generation | `@ball-lang/compiler` |
| `ts/encoder` | TypeScript source → Ball Program | `@ball-lang/encoder` |
| `ts/cli` | CLI for TS tools | `@ball-lang/cli` |
| `ts/shared` | Protobuf types (generated) | `@ball-lang/shared` |

## Build & Test

Commands: see CLAUDE.md → Build & Test (canonical) and `.claude/rules/ts.md` for per-package detail.

**Prefer conformance tests over unit tests.** The TS engine is validated primarily through conformance fixtures (`tests/conformance/`) shared with Dart and C++ engines. Per-language unit tests should be minimal — only for TS-specific edge cases (browser API handling, event loop differences).

## Conventions

- Each package has `package.json`, `tsconfig.json`, `vitest` config
- Generated protobuf types in `ts/shared/gen/` — NEVER edit
- Compiler entry: `ts/compiler/bin/ball-ts-compile.mjs` (called by Dart compiler runner)
- **Engine is validated against shared conformance fixtures** — test via `tests/conformance/`, not engine-specific tests
- Current TS pass counts live in `docs/SELF_HOST_STATUS.md` (CI floor in `.github/workflows/regression-gates.yml`)

## Publishing

- npm publishing via OIDC trusted publishing (`.github/workflows/publish-npm.yml`)
- Packages published individually

## Key Differences from Dart

- TS engine: single-threaded async (no isolates), browser-compatible
- TS compiler: uses ts-morph in-process (no shell-out)
- TS encoder: AST-based source transformation
- All base functions route through `std` — the `dart_std` module has been eliminated from encoders
