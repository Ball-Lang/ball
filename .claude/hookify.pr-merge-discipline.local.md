---
name: pr-merge-discipline
enabled: true
event: bash
pattern: gh\s+pr\s+(merge|create)
action: warn
---

⚠️ **PR discipline check** (real incidents in this repo):

**Merging?** Verify the stack-relevant jobs actually **RAN and pass** — absent or `skipping` checks are NOT green. A failed gate job leaves dependents `skipped`; a workflow-YAML error hides a whole file's checks; a suspiciously low check count is itself a red flag. After a gate-job infra flake, use a full `gh run rerun <run-id>` — `--failed` does not revive skipped dependents. Never merge red.

**Creating?** `fixes #N` / `closes #N` auto-closes the issue on merge — use them ONLY when the issue's acceptance criteria are fully met (an accidental keyword once closed a coverage issue against the PR's own keep-open assessment). For partial progress write `advances #N`. Also: only maintainers merge — contributors stop at "PR open + checks green + review requested".
