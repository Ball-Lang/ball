[![npm version](https://img.shields.io/npm/v/@ball-lang/cli.svg)](https://www.npmjs.com/package/@ball-lang/cli)

# @ball-lang/cli

Command-line interface for the [Ball programming language](https://github.com/ball-lang/ball). Runs Ball programs (`run`, powered by [`@ball-lang/engine`](https://www.npmjs.com/package/@ball-lang/engine)), inspects and validates them (`info`/`validate`/`tree`, powered by the self-hosted `cli_core.dart` verbs compiled through `@ball-lang/compiler`), and performs static capability analysis (`audit`).

> Note: `@ball-lang/cli` depends on a published `@ball-lang/engine`. Keep its dependency range in `package.json` aligned with the current engine major (the engine is at 1.x) so npm can resolve a compatible engine — a stale `^0.3.0` range will not accept engine 1.x.

## Install

```bash
npm install -g @ball-lang/cli
```

Or run it without installing:

```bash
npx @ball-lang/cli run my_program.ball.json
```

## Commands

### `ball run <program.ball.json>`

Execute a Ball program. Writes `std.print` output to stdout.

```bash
ball run examples/hello_world/hello_world.ball.json
```

### `ball info <program.ball.json>`

Inspect a Ball program's structure — name, version, entry point, and a per-module breakdown (functions, type definitions, aliases, enums). Computed by the same self-hosted `cli_core.dart` verb the Dart CLI uses, compiled to TypeScript, so the output is byte-identical between the two CLIs.

```bash
ball info examples/hello_world/hello_world.ball.json
```

### `ball validate <program.ball.json>`

Check a Ball program's validity (entry point resolves, no duplicate module names, every non-base function has a body or metadata). Prints `Valid: ...` on stdout and exits 0, or `Invalid: N error(s) found` on stderr and exits 1.

```bash
ball validate examples/hello_world/hello_world.ball.json
```

### `ball tree <program.ball.json>`

Print the module/import tree — every module with its function count, and every `moduleImports` entry with its resolved source (`http:`, `file:`, `git:`, a registry spec, `inline`, or `ref only`).

```bash
ball tree examples/hello_world/hello_world.ball.json
```

### `ball version`

Prints `ball <version>` (same as `--version`/`-v`, see below).

### `ball audit <program.ball.json>`

Static capability analysis. Walks the expression tree of every user-defined function and reports which side-effect categories are used. Because every side effect in Ball flows through a named base function, this analysis is provably complete -- not heuristic.

```bash
ball audit my_program.ball.json
```

Example output:

```
Ball Capability Audit: path v1.9.1
============================================================

Capabilities:
  ✓ pure (pure computation)
  ⚠ io (2 call sites: main.main → std.print, main.main → std.print)
  ✗ NONE: filesystem, network, process, memory, concurrency, random

Summary: LOW RISK
  1 functions: 0 pure, 1 effectful
```

#### Audit flags

| Flag | Description |
|------|-------------|
| `--output <path>` | Write the structured JSON report to `<path>`. |
| `--deny <caps>` | Comma-separated capabilities to deny. Exits with code 1 on any violation (e.g. `--deny fs,network`). |
| `--reachable-only` | Only analyze functions transitively reachable from the entry function. |
| `--json` | Emit the JSON report to stdout instead of the text report. |

Capability categories: `pure`, `io`, `fs`, `process`, `time`, `random`, `memory`, `concurrency`, `network`, `async`.

### `ball --version`

Prints `ball <version>` (matches the Dart CLI's `--version`/`-v`/`version` — all three spellings dispatch to the same `cli_core.versionLine`).

### `ball --help`

Prints usage information.

## Policy enforcement in CI

Fail a CI job if a Ball program gains filesystem or network access:

```bash
ball audit my_program.ball.json --deny fs,network
```

## License

MIT
