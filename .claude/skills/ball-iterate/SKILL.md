---
name: ball-iterate
description: Use when the user invokes /ball-iterate <lang> or asks to improve, harden, or close gaps in an existing Ball language target — conformance failures, coverage below floors, latent bugs, fail-loud violations, stale docs (e.g. "/ball-iterate ts", "harden the C++ target").
---

# /ball-iterate <lang> — audit-then-grind an existing Ball target

Orchestration contract for improving a mature target. Language internals live in `.claude/rules/<lang>.md` and `<lang>/AGENTS.md` (read both first). This skill pins the shape: audit → verified backlog → bounded gated lanes. Follow it exactly.

## Output contract (produce these, in this order)

### 0. Permission discovery
Same tiers and detection as **ball-new** §0 (`gh auth status` + `gh api repos/<owner>/<repo> -q .permissions`): maintainers merge on verified green; contributors fork + PR and end lanes at "checks green + review requested" (never merge); gh-less/sandboxed sessions keep the backlog as a committed plan doc and hand branch names to the user. Apply the tier consistently to every lane below.

### 1. Gap-audit Workflow (read-only map → synthesis)
Launch a Workflow with one **sonnet** map cell per dimension below (no builds — analyze files/CI/issues only; use semantic codebase search where the session provides it), then one **opus** synthesis returning a ranked backlog (`rank, title, severity, effort, existing_issue, action, parallelizable`):

| Map cell | Looks at |
|---|---|
| conformance | every leg for `<lang>` in ci.yml + conformance-matrix.yml + coverage.yml: which run per-PR vs main-only; current N/M; carve-outs (CARVEOUTS.md files) with live justification |
| coverage | % vs enforced floors — read CI's last-published coverage artifacts/logs and floor scripts, do NOT run builds; largest hand-written uncovered clusters; generated files correctly excluded |
| fail-loud | silent-degradation grep: placeholder returns, bare-comment emissions, no-op stubs, swallow-catches (`/* ... */`-as-expression, `return null/[]` fallbacks) |
| completeness | encoder-completeness + fixture-name gates; std base functions emittable-but-unexercised; std_coverage inventory |
| docs | `<lang>/AGENTS.md`, rules, root status prose vs shipped reality; dead issue references |

### 2. Staleness verification (after the audit's backlog, before launching lanes)
Batch-verify every issue the backlog references: `gh issue view N --json state` for ALL of them, and spot-check factual claims (floors, branch names, counts) against CI configs. Saved plans and issue references rot — 8 of 12 did in one real case. Run only still-live items; report skipped-stale ones.

### 3. Waves (bounded, gated lanes)
Launch backlog items as Workflow/Agent lanes using the lane protocol and model fits from **REQUIRED SUB-SKILL: ball-new** (same tables — not restated in this skill file; plans and lane briefs should inline them). Sizing rules:
- **Bounded per lane**: one category / one file-cluster / one CI concern per PR with a measurable delta (N→M fixtures, X%→Y% coverage). Big walls become **category grinds**: root-cause one category, land green, repeat.
- Real bugs found mid-lane are fixed with a failing-before test, or filed as issues if out of scope — never silently patched or ignored.
- Serialize heavy same-toolchain builds (one WSL build at a time); the orchestrator owns long build-waits.

### 4. Honest close-out (the #61 standard)
An issue closes only at **100%-of-honestly-reachable**: real tests for every reachable arm; per-site justified exclusions (environmental I/O, verified-unreachable defensive arms, entry-point glue) inventoried in the PR; floors ratcheted to the measured result. Below that bar the issue STAYS OPEN with a precise residual inventory — keyword auto-closes that contradict the lane's own assessment get reopened.

## Gates
Same as ball-new: never merge red; verify stack-relevant jobs RAN (absent/skipped ≠ green); full re-run after gate-job infra flakes; rebase stacked lanes at gate time; dispatch main-only workflows (coverage, matrix) after merges that touch them and confirm green.

## Red flags — stop and correct
- Launching fixes before the audit + staleness check · unbounded "improve everything" lanes · closing an issue below the honest bar · trusting a saved backlog's issue numbers · excluding hand-written code from coverage instead of testing it · a lane stalled waiting on a background build (resume it; own the wait).
