# ball_cli

Command-line tool for the [Ball programming language](https://ball-lang.dev).

`ball_cli` installs the `ball` executable -- a one-stop CLI for inspecting, validating, compiling, encoding, running, auditing, and packaging Ball programs.

## Install

```
dart pub global activate ball_cli
```

Or add it as a dev dependency:

```
dart pub add --dev ball_cli
```

## Quick start

```bash
ball encode my_app.dart --output my_app.ball.json   # Dart -> Ball
ball run my_app.ball.json                           # Execute
ball compile my_app.ball.json --output out.dart     # Ball -> Dart
```

## Commands

| Command | Purpose |
|---------|---------|
| `ball info <input.ball.json>` | Inspect program structure (modules, functions, types) |
| `ball validate <input.ball.json>` | Check program validity against the proto schema |
| `ball compile <input.ball.json>` | Compile a Ball program to Dart source |
| `ball encode <input.dart>` | Encode Dart source into a Ball program |
| `ball run <input.ball.json>` | Execute a Ball program with the Dart engine |
| `ball round-trip <input.dart>` | Encode, compile, and diff -- round-trip validation |
| `ball audit <input.ball.json>` | Static capability analysis (filesystem, network, ...) |
| `ball build <input.ball.json>` | Resolve imports into a self-contained program |
| `ball init` | Create a `ball.yaml` manifest in the current directory |
| `ball add <spec>` | Add a dependency (`pub:pkg@^1.0.0`, `npm:@scope/pkg@1.0`, ...) |
| `ball resolve` | Resolve declared deps into `ball.lock.json` |
| `ball tree` | Print the dependency tree |
| `ball version` | Print the CLI version |

## Options

| Flag | Description |
|------|-------------|
| `--output <file>` | Output file (default: stdout) |
| `--format <json\|binary>` | Output format for `encode` (default: json) |
| `--no-format` | Skip `dart_style` formatting during `compile` |

## Example workflow

```bash
# Start a new Ball project
ball init
ball add pub:http@^1.2.0
ball resolve

# Turn a real Dart app into a Ball program, then compile it back.
ball encode bin/server.dart --output server.ball.json
ball compile server.ball.json --output server_roundtrip.dart

# Run directly
ball run server.ball.json
```

## Related packages

- [`@ball-lang/engine`](https://www.npmjs.com/package/@ball-lang/engine) -- TypeScript/JavaScript engine and CLI (experimental)

## Links

- Website: https://ball-lang.dev
- Repository: https://github.com/ball-lang/ball
- Issue tracker: https://github.com/ball-lang/ball/issues

## License

MIT
