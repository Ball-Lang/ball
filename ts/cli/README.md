[![npm version](https://img.shields.io/npm/v/@ball-lang/cli.svg)](https://www.npmjs.com/package/@ball-lang/cli)

# @ball-lang/cli

Command-line interface for the [Ball programming language](https://github.com/ball-lang/ball). Runs Ball programs and performs static capability analysis, powered by [`@ball-lang/engine`](https://www.npmjs.com/package/@ball-lang/engine).

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

Prints the CLI version.

### `ball --help`

Prints usage information.

## Policy enforcement in CI

Fail a CI job if a Ball program gains filesystem or network access:

```bash
ball audit my_program.ball.json --deny fs,network
```

## License

MIT
