# Contributing to Ball

Ball welcomes contributions from humans and AI agents alike — most of this repo's recent history was built by AI sessions following the conventions below. Read `CLAUDE.md` (agent-oriented) and `AGENTS.md` first; this file covers the *contribution flow*.

## Know your permission tier first

Check what you can do before planning work:

```bash
gh auth status
gh api repos/Ball-Lang/ball -q .permissions   # {"push":true,...} = maintainer; error/absent = fork flow
```

| Tier | You can | Your flow |
|---|---|---|
| Maintainer (`push: true`) | branch on origin, create issues, merge | branch → PR → merge on verified green |
| Contributor (no `push`) | fork, open PRs, comment | `gh repo fork --remote` → branch on fork → PR → request review. **Never merge; maintainers do.** |
| No `gh` / sandboxed (cloud, Cowork) | local work only | commit locally, record plans as `docs/plans/*.md`, tell a human which branches to push/PR |

## The non-negotiables

1. **Never edit generated files** — `*/shared/gen/**`, `compiled_engine.{ts,rs}`, `engine_rt.cpp`, `dart/shared/{std,ball_proto,ball_protobuf}.{json,bin}`, `ball_protobuf_rt.*`, `ball_program_descriptor.h`, `tests/conformance/*.ball.json` (regenerate via the commands in `CLAUDE.md` → Build & Test; hand-authored fixture exceptions live in `tests/conformance/CARVEOUTS.md`).
2. **Fail loud** — never return `null`/`[]`/a placeholder for an unhandled shape.
3. **Every fix ships with a failing-before test** — prefer conformance fixtures (`tests/conformance/src/*.dart` + `generate_conformance.dart`) over unit tests.
4. **Green means verified** — before merging (maintainers), confirm the stack-relevant CI jobs actually *ran and passed*: absent or `skipping` checks are not green, and `gh run rerun --failed` does not revive gate-skipped dependents (use a full rerun).
5. **Closing keywords are commitments** — `fixes #N` auto-closes on merge; use it only when the issue's acceptance criteria are fully met, otherwise write `advances #N`.
6. **Honest status** — coverage/conformance claims come from CI runs, not aspiration; issues close at 100%-of-reachable with per-site-justified exclusions, not before.

## AI-assisted development

- **`/ball-new <lang>`** (`.claude/skills/ball-new/`) — bootstrap a complete new language target (issue tree → orchestrated waves → corpus parity).
- **`/ball-iterate <lang>`** (`.claude/skills/ball-iterate/`) — audit-then-grind an existing target (gap audit → verified backlog → bounded gated lanes).
- **Claude Code plugin** (`plugins/ball/`, distributed via this repo's plugin marketplace `.claude-plugin/marketplace.json`): `/plugin marketplace add Ball-Lang/ball` + `/plugin install ball@ball-lang` gives **any codebase** `/ball:convert <target>[, custom instructions]` (whole-codebase language conversion through the Ball IR) plus `/ball:new` and `/ball:iterate` bootstrap wrappers that clone this repo and defer to the canonical in-repo skills. Contributors opening this repo are prompted automatically via `.claude/settings.json`.
- Component internals: `.claude/skills/{ball-compiler,ball-encoder,ball-engine,new-ball-language}/`, per-language rules in `.claude/rules/`.
- Guard rails: `.claude/hookify.*.local.md` rules (require the [hookify](https://github.com/anthropics/claude-code) plugin) block generated-file edits and remind PR discipline — they activate automatically for any contributor with hookify installed and are inert otherwise.
- Cloud surfaces (Claude Code web, Claude Cowork) run in Linux sandboxes: the WSL notes in `CLAUDE.md` are for local Windows development only; on Linux just build natively. Sandboxes without `gh` follow the "No gh" tier above.

## Build, test, verify

Everything is in `CLAUDE.md` → Build & Test (Dart workspace at repo root, `cd <pkg> && dart test`; TS per-package `npm test`; C++ CMake — protobuf-free, configure ≈1 min; Rust `cargo test --workspace`). The conformance corpus (`tests/conformance/`) is the cross-language bar: a change to any target must keep every leg green, and CI runs changed fixtures per-PR on every stack.
