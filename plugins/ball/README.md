# Ball plugin for Claude Code

Skills for working with the [Ball language](https://github.com/Ball-Lang/ball) toolchain from **any** codebase — not just the Ball repository.

## Install

```shell
/plugin marketplace add Ball-Lang/ball
/plugin install ball@ball-lang
```

Contributors working inside the Ball repository are prompted automatically (the repo's `.claude/settings.json` registers the marketplace).

## Skills

| Skill | Use for |
|---|---|
| `/ball:convert <target>[, custom instructions]` | Convert a whole codebase (source, tests, build config, CI) from one language to another through the Ball IR — deterministic encode → IR → compile, with engine-oracle parity verification. Runs in **your** repository. |
| `/ball:embed` | Safely execute dynamically-delivered code inside **your** app — server-driven logic or native UI without arbitrary remote code execution. Teaches the receive → audit → reject-or-execute pattern, deny-by-default capability policy, and exposing only a vetted native module surface. |
| `/ball:new <language>` | Bootstrap full Ball support for a new target language (compiler + encoder + engine + CLI + conformance + CI). Wrapper that defers to the canonical in-repo skill in a `Ball-Lang/ball` checkout. |
| `/ball:iterate <language>[, focus]` | Audit and improve an existing Ball language target (conformance, coverage, fail-loud, docs). Wrapper that defers to the canonical in-repo skill in a `Ball-Lang/ball` checkout. |

## Toolchain

`/ball:convert` installs what it needs (verified sources only):

- Dart: `dart pub global activate ball_cli` — [pub.dev/packages/ball_cli](https://pub.dev/packages/ball_cli)
- TypeScript: `@ball-lang/encoder`, `@ball-lang/compiler`, `@ball-lang/cli` on npm
- C++ / Rust: built from a [Ball-Lang/ball](https://github.com/Ball-Lang/ball) clone

## License

MIT — see the repository's `LICENSE`.
