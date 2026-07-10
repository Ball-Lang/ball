---
name: ball-new
description: Use when the user invokes /ball-new <lang> or asks to add a complete new language target to Ball (compiler + encoder + engine + CLI + conformance + CI + docs) — e.g. "/ball-new c#", "add Swift support", "bootstrap Kotlin".
---

# /ball-new <lang> — bootstrap a complete Ball language target

Orchestration contract for adding a language. The phase *content* lives in the playbook — **REQUIRED SUB-SKILL: new-ball-language** (read it fully first). This skill pins the orchestration shape: the issue tree, the wave order, the model fits, and the gates. Follow it exactly; do not improvise a different sequencing.

## Output contract (produce these, in this order)

### 1. Recon (read-only, ~10 tool calls)
Verify `<lang>/` current state (usually proto bindings only — confirm against CLAUDE.md's status paragraph and `ls <lang>/`), confirm no existing epic (`gh issue list --search "<lang>"`), read the reference implementations named in the playbook's Phase 0, and check ci.yml/conformance-matrix.yml for the per-language job template to mirror. Toolchain facts (setup actions, package-manager conventions) are verified against current docs at issue-authoring time — never asserted from memory.

### 2. Issue tree (before ANY code)
Create a GitHub **epic** `[EPIC] Implement Ball fully in <Lang>` plus **ten phase issues**, each titled `<Lang> Phase N: <name>` and seeded with that phase's playbook checklist as acceptance criteria. This table is the binding contract (distilled from the completed Rust epic #32/#33–#45, which used finer sub-splits — do not mirror its historical shape; follow this table):

| # | Phase issue | Blocked by |
|---|---|---|
| 1 | Directory scaffold + package manifests | — |
| 2 | Proto bindings (buf plugin strategy decided IN the issue) | 1 |
| 3 | Runtime value model (BallValue/List/Map — insertion-ordered maps; reference semantics for instances/lists/maps per the Dart reference) | 1 |
| 4 | Compiler (expression tree, base-function dispatch, LAZY control flow, type emission, multi-module) | 2, 3 |
| 5 | Encoder (parser lib decided IN the issue → universal `std` only, no `<lang>_std`) | 2, 3 |
| 6 | Self-hosted engine (compile `dart/self_host/engine.ball.json`; expect a compiler-gap grind) | 4 |
| 7 | Conformance harness (`Results: N passed, M failed, T total` line; corpus at Dart parity closes it) | 6 |
| 8 | CLI (run/compile/encode/check, exit-code contract) | 4, 5 |
| 9 | CI/CD (ci.yml job: build+test+fmt+lint+conformance sweep; conformance-matrix row; coverage flag + floor; dependabot) | 7 |
| 10 | Docs (`<lang>/AGENTS.md`, `.claude/rules/<lang>.md`, root CLAUDE.md/AGENTS.md status — honest, never aspirational) | 1–9 |

Spec decisions (protobuf strategy, parser library, test framework, engine strategy) are resolved as text **in the issues** before implementation starts.

### 3. Waves (ultracode Workflows, one PR per phase)
Run phases as Workflow lanes respecting the Blocked-by column — phases 4 and 5 may run in parallel; 6 is serial after 4 and is usually a **category grind** (bounded root-cause categories, one PR each, measurable error/fixture deltas — the Rust engine went 414 compile errors → 0 → 319/319 this way). Every lane uses the lane protocol below. Model fits:

| Model | Use for |
|---|---|
| opus | compiler/engine correctness, self-host grind root-causing, value-model design/reshapes, debugging |
| sonnet | standard implementation with a strong reference (CLI, CI, conformance harness, tests, encoder port) |
| haiku | mechanical sweeps: lint/config checks, inventory tables, boilerplate docs |
| fable | large-file bulk edits (only if available in the session) |

Phases without a table row default to **sonnet** (scaffold, bindings, docs); a pure-inventory docs sweep may drop to haiku.

### 4. Definition of done
The epic closes ONLY when `<lang>` can **compile AND encode AND execute** the conformance corpus (CLAUDE.md's bar), each phase issue closed by a merged PR that satisfied its acceptance criteria.

## Lane protocol (paste into every lane brief)
- Protected worktree: `git worktree add /d/packages/ball-wt-<slug> -b <branch> origin/main` + empty anchor commit + **push before work starts**.
- Commit incrementally, only BUILDING+GREEN states. Push with retries. One PR per phase, `--base main`; body `fixes #<phase-issue>` only when acceptance criteria are fully met, else `advances #<n>` with precise status.
- STOP-and-report beats thrashing; never hand-edit generated files (regenerate); fail loud on unhandled shapes.
- Do not stop to wait on background builds — run long steps foreground with bounded until-loops (stalled lanes need orchestrator babysitting).

## Gates (the orchestrator's job)
- Never merge red. Verify the stack-relevant jobs show `pass` — **absent/skipped checks are not green** (a failed gate job leaves dependents `skipped`; a workflow-YAML error hides a whole file's checks; a suspiciously low check count is itself a red flag).
- Infra flake signature: trivial job "failing" at ~15m01s = runner acquisition; full re-run (`gh run rerun <id>`, NOT `--failed`).
- Rebase stacked lanes onto main at gate time (never mid-work).

## Red flags — stop and correct
- Writing code before the issue tree exists · a single monolith PR · merging with checks absent · phase order improvised (e.g. "encoder last") · closing the epic below corpus parity · aspirational status docs.
