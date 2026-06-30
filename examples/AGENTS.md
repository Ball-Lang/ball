<!-- Parent: ../AGENTS.md -->

# examples

## Purpose
Hand-authored Ball programs that demonstrate language features. Each example is a self-contained directory with a `.ball.json` source plus optional compiled outputs for each target language.

## Layout Convention

```
examples/<name>/
  <name>.ball.json     # Ball program in proto3 JSON (the source of truth)
  dart/                # Dart compiled output (optional)
  cpp/                 # C++ compiled output (optional)
```

Every `.ball.json` must define the std module inline with all base functions/types it uses. User functions carry a `body` expression tree; base functions set `"isBase": true` with no body. See CLAUDE.md → "Examples Layout".

## Key Files / Contents

| Example | What it demonstrates |
|---------|----------------------|
| `hello_world/` | Minimal program: std `print`, string literal |
| `fibonacci/` | Recursion, integer arithmetic |
| `add/` | Simple function call with one input |
| `all_constructs/` | Wide coverage of expression types (call, lambda, block, etc.) |
| `comprehensive/` | Broader std-library usage |
| `real_world/` | A more realistic composite program |

## For AI Agents

- `.ball.json` files in `examples/` are **hand-authored** (unlike `tests/conformance/*.ball.json` which are generated). Edit them directly when adjusting an example.
- Compiled outputs (`dart/`, `cpp/`) are **generated** by the compiler — regenerate rather than editing by hand.
- When adding a new example, follow the layout above and ensure the program runs correctly through `dart/engine` (`dart run bin/engine.dart ../../examples/<name>/<name>.ball.json`).
- Examples are used by `website/tool/generate_examples.dart` to populate the website — keep them clean and self-documenting.
- Do not use examples as conformance tests; add a fixture under `tests/conformance/src/` for CI gating instead.
