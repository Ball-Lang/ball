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
7. **Your PR title becomes `main`'s commit message, verbatim, with an empty body** (`squash_merge_commit_title: PR_TITLE` + `squash_merge_commit_message: BLANK` — issue #881; see "Landing via the merge queue" below). Never put a GitHub skip-CI token (`[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, `[actions skip]`, a `skip-checks: true` trailer) or a closing keyword before an issue number in a PR title — `tools/ci/check_pr_title_skip_tokens.sh` gates the former on every PR; nothing gates the latter mechanically, so rule 5 above is on you. And because the body is dropped, a `BREAKING CHANGE:` footer written only in a commit body never reaches `main` either — see `docs/RELEASE.md` → "Release via PR" for how (and whether) that is currently signalled per release lane.

## AI-assisted development

- **`/ball-new <lang>`** (`.claude/skills/ball-new/`) — bootstrap a complete new language target (issue tree → orchestrated waves → corpus parity).
- **`/ball-iterate <lang>`** (`.claude/skills/ball-iterate/`) — audit-then-grind an existing target (gap audit → verified backlog → bounded gated lanes).
- **Claude Code plugin** (`plugins/ball/`, distributed via this repo's plugin marketplace `.claude-plugin/marketplace.json`): `/plugin marketplace add Ball-Lang/ball` + `/plugin install ball@ball-lang` gives **any codebase** `/ball:convert <target>[, custom instructions]` (whole-codebase language conversion through the Ball IR) plus `/ball:new` and `/ball:iterate` bootstrap wrappers that clone this repo and defer to the canonical in-repo skills. Contributors opening this repo are prompted automatically via `.claude/settings.json`.
- Component internals: `.claude/skills/{ball-compiler,ball-encoder,ball-engine,new-ball-language}/`, per-language rules in `.claude/rules/`.
- Guard rails: `.claude/hookify.*.local.md` rules (require the [hookify](https://github.com/anthropics/claude-code) plugin) block generated-file edits and remind PR discipline — they activate automatically for any contributor with hookify installed and are inert otherwise.
- Cloud surfaces (Claude Code web, Claude Cowork) run in Linux sandboxes: the WSL notes in `CLAUDE.md` are for local Windows development only; on Linux just build natively. Sandboxes without `gh` follow the "No gh" tier above.

## Landing via the merge queue

`main`'s `Protect main` ruleset (17056238) moved from a plain "19 required
checks must be green" gate to GitHub's **merge queue**
([#756, owner decision 2026-10-17](https://github.com/Ball-Lang/ball/issues/756#issuecomment-6229422998))
— the fix for #749, where two PRs were each green alone and broke `main` on
their union, discovered only after both had merged. The ruleset's workflows
were wired for this first (every required-context workflow gained a
`merge_group:` trigger — #756's first PR), and the `merge_queue` rule itself
is now **enabled** on ruleset 17056238 (confirmed via
`gh api repos/Ball-Lang/ball/rulesets/17056238 --jq '[.rules[].type]'`
including `"merge_queue"`), with these parameters:

| Parameter | Value |
| --- | --- |
| `merge_method` | `SQUASH` |
| `grouping_strategy` | `ALLGREEN` |
| `max_entries_to_build` | 5 |
| `max_entries_to_merge` | 5 |
| `min_entries_to_merge` | 1 |
| `min_entries_to_merge_wait_minutes` | 5 |
| `check_response_timeout_minutes` | 90 |

(see `docs/TESTING_STRATEGY.md` → "Merge-queue readiness (#756)" for the full
wiring story).

**Your PR title is what lands on `main`.** The repository's squash settings
are `squash_merge_commit_title: PR_TITLE` and `squash_merge_commit_message:
BLANK` (verify live: `gh api repos/Ball-Lang/ball --jq
'{t:.squash_merge_commit_title,m:.squash_merge_commit_message}'`) — the queue
squashes with these repository defaults regardless of what `gh pr merge`
requests, same as a plain squash merge (GitHub's API docs say the queue
ignores any commit headline/body/method an auto-merge call sends). So every
merge's squash commit on `main` is exactly `<your PR title> (#N)` with an
**empty body** — no commit body, no footer, ever reaches `main` this way.
This used to be `squash_merge_commit_title: COMMIT_OR_PR_TITLE` (the single
commit's own subject + body, for a single-commit PR); it changed because PR
#881's merge commit carried a literal `[skip ci]` inherited from a branch
commit and silently skipped every push-triggered workflow on `main` for that
merge, including Release. `tools/ci/check_pr_title_skip_tokens.sh` (always-on,
`Proto Checks`) now fails any PR whose title contains a GitHub skip-CI token
before it can repeat that. Landing a PR now works like this:

1. Get the PR's own `pull_request` checks green, same as always — queueing
   does **not** skip that.
2. Queue it (the PR page's merge button, or `gh pr merge <n>` — once a
   branch requires a merge queue, `gh pr merge` needs no merge-strategy flag:
   per [the `gh pr merge` manual](https://cli.github.com/manual/gh_pr_merge),
   it adds the PR to the queue once its required checks have passed, or
   enables auto-merge (equivalent to `--auto`) if they haven't yet — there is
   no `--queue` flag. `--admin` bypasses the queue entirely for an
   administrator; don't use it to dodge a legitimately red merge group.
3. GitHub builds a **merge group**: a speculative commit of `main` plus this
   PR and anything else already ahead of it in the queue, and re-runs every
   one of the 19 required checks AGAINST THAT COMMIT via each workflow's
   `merge_group:` trigger (`ci.yml`, `regression-gates.yml` today).
4. If the merge group is green, GitHub fast-forwards `main` to it. If it is
   red, your PR is dequeued (the others in the queue are retried without it)
   and you fix it and re-queue — exactly the #749 shape, caught one step
   earlier than before.

The merge-group run is a separate check-run set from the PR's own
`pull_request` run, on a different ref (`gh-readonly-queue/...`) and commit;
whether `gh pr checks <n> --watch` follows it once queued is unverified —
confirm on the PR page now that the `merge_queue` rule is enabled, or watch
the Actions run for the `gh-readonly-queue/` branch directly in the meantime.

Every required-context workflow's `pull_request:` trigger is also
unconditional now — no `paths:`/`paths-ignore:` filter — so a docs-only PR's
checks always start and can actually reach "green" to queue; see
`docs/TESTING_STRATEGY.md` → "Docs-only PRs and required-context workflows"
for why that matters once a merge queue is the only way to land.

## Build, test, verify

Everything is in `CLAUDE.md` → Build & Test (Dart workspace at repo root, `cd <pkg> && dart test`; TS per-package `npm test`; C++ CMake — protobuf-free, configure ≈1 min; Rust `cargo test --workspace`). The conformance corpus (`tests/conformance/`) is the cross-language bar: a change to any target must keep every leg green, and CI runs changed fixtures per-PR on every stack.
