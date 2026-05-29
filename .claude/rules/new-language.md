---
paths:
  - "go/compiler/**"
  - "go/encoder/**"
  - "go/engine/**"
  - "go/cli/**"
  - "python/compiler/**"
  - "python/encoder/**"
  - "python/engine/**"
  - "python/cli/**"
  - "java/compiler/**"
  - "java/encoder/**"
  - "java/engine/**"
  - "java/cli/**"
  - "csharp/compiler/**"
  - "csharp/encoder/**"
  - "csharp/engine/**"
  - "csharp/cli/**"
  - "rust/**"
  - "swift/**"
  - "kotlin/**"
  - "ruby/**"
---

# New Language Implementation Rules

You are working on a language that does not yet have a complete Ball implementation. These
directories currently only have proto bindings in `shared/gen/`.

## Before You Start

1. Read the **new-ball-language** skill: `.claude/skills/new-ball-language/SKILL.md`
2. Read the Dart reference implementation for the component you're building
3. Check if `buf.gen.yaml` already has a plugin entry for this language

## Implementation Order

Follow the 8 phases in `.claude/skills/new-ball-language/SKILL.md` — do not restate them here. The high-level path is: shared types → compiler → engine (via self-host) → conformance → CLI → encoder (hardest, last).

## Conformance Test Output Format

Your test runner MUST print this line for CI matrix parsing:
```
Results: <N> passed, <M> failed, <T> total
```

## Key Files to Reference

| Need | File |
|------|------|
| All std function signatures | `dart/shared/lib/std.dart` |
| Compiler dispatch pattern | `dart/compiler/lib/compiler.dart` → `_compileBaseCall()` |
| Engine evaluation pattern | `dart/engine/lib/engine.dart` → `_evalExpression()` |
| Self-host Ball program | `dart/self_host/engine.ball.json` |
| Conformance fixtures | `tests/conformance/*.ball.json` |
| Metadata spec | `docs/METADATA_SPEC.md` |
| Proto schema | `proto/ball/v1/ball.proto` |

## When You're Done

- [ ] Create `<lang>/AGENTS.md` following `dart/AGENTS.md` pattern
- [ ] Create `.claude/rules/<lang>.md` following `.claude/rules/dart.md` pattern
- [ ] Add CI job to `.github/workflows/ci.yml`
- [ ] Add conformance job to `.github/workflows/conformance-matrix.yml`
- [ ] Update root `CLAUDE.md` build & test section
- [ ] Update root `AGENTS.md` project context
