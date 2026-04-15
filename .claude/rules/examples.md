---
paths:
  - "examples/**"
---

# Ball Examples Instructions

## Example Program Structure

Each example lives in `examples/<name>/` with:
- `<name>.ball.json` — The Ball program (proto3 JSON format)
- `dart/` — Compiled Dart output
- `cpp/` — Compiled C++ output (often empty — C++ compilation not automated)

## Ball Program JSON Structure

A valid Ball program has:
```json
{
  "name": "program_name",
  "version": "1.0.0",
  "entryModule": "main",
  "entryFunction": "main",
  "modules": [
    {
      "name": "std",
      "types": [...],
      "functions": [...]
    },
    {
      "name": "main",
      "imports": ["std"],
      "functions": [...]
    }
  ]
}
```

## Key Rules

- The std module must define ALL base functions and types used by the program
- Base functions have `"isBase": true` and no `"body"`
- User functions have a `"body"` containing an Expression tree
- `"input"` is a special reference name meaning "the function's parameter"
- Control flow (if, for, while) are calls to std functions, not special syntax
- Types use protobuf descriptors: `TYPE_STRING`, `TYPE_INT64`, `TYPE_DOUBLE`, `TYPE_BOOL`
