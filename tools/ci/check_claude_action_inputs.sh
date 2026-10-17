#!/usr/bin/env bash
# claude-code-action input/trigger-event static gate (issue #870).
#
# WHY THIS EXISTS: claude-iterate.yml's weekly `schedule` run has been red
# since the workflow was added on 2026-07-10 (#359) -- every scheduled run
# from 2026-07-14 onward failed identically (most recently run 38421075334,
# job 115378233630; also confirmed on job 91963210761, 2026-08-04) because
# every one of its three `anthropics/claude-code-action@...` steps passed
# `track_progress: true`, and that input is HARDCODED valid only for
# `pull_request`/`issues`/`issue_comment`/`pull_request_review_comment`/
# `pull_request_review` events (anthropics/claude-code-action's
# `src/modes/detector.ts`, `validateTrackProgressEvent` — read at the exact
# pinned SHA this repo uses). `claude-iterate.yml` triggers on `schedule` and
# `workflow_dispatch`, neither of which is in that set, so `detectMode()`
# throws BEFORE the action ever installs the Claude CLI or attempts auth —
# every account fails identically, and the workflow's own failover step then
# prints the misleading "All three Claude accounts failed (auth, rate
# limits, ...)" for a bug that had nothing to do with any account.
#
# Nothing caught this before a human (or a scheduled run) hit it, and a
# config-vs-input mismatch like this is invisible to every build/test gate —
# the workflow YAML is syntactically valid, actionlint has no model of the
# called action's own input semantics, and the failure only ever surfaces on
# the EVENT the workflow is scheduled for, which PR-time CI never fires.
#
# WHAT THIS GUARD CHECKS: every `.github/workflows/*.yml` file. For each
# `anthropics/claude-code-action` step whose `track_progress` input is not
# statically `false`/absent (a dynamic `${{ ... }}` expression is treated
# conservatively as "possibly enabled" — this guard never clears a step just
# because it can't prove the expression is always false), the workflow's own
# `on:` trigger set must be a SUBSET of the action's documented
# track_progress-valid events. If the workflow also triggers on
# `pull_request`, that trigger's `types:` (or the three GitHub-documented
# defaults when `types:` is omitted) must themselves be a subset of the
# action's track_progress-valid pull_request actions
# (opened/synchronize/ready_for_review/reopened) — the second validation
# `validateTrackProgressEvent` performs.
#
# POSITIVE FLOOR: a guard that scanned zero claude-code-action steps must not
# report success — `--self-test` drives 6 positive + 6 negative fixtures
# offline and requires at least 8 of them to run; the real-repo scan requires
# at least one claude-code-action step to exist (this repo ships two:
# claude.yml and claude-iterate.yml) or it fails loud instead of passing
# trivially.
#
# Usage:
#   bash tools/ci/check_claude_action_inputs.sh                 # gate the repo
#   bash tools/ci/check_claude_action_inputs.sh --dir DIR        # another workflows dir
#   bash tools/ci/check_claude_action_inputs.sh --self-test      # drive the fixtures
#
# Exits 0 when every claude-code-action step's inputs are valid for its
# workflow's own trigger events; 1 otherwise, naming every offending
# file/job/step. Needs bash + python3 + PyYAML (the runner image ships all
# three — see tools/ci/check_matrix_paths.sh for the same precedent), so this
# runs in ci.yml's always-on `Proto Checks` job with no extra toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOWS_DIR="$ROOT/.github/workflows"
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
  --dir)
    WORKFLOWS_DIR="$2"
    shift 2
    ;;
  --dir=*)
    WORKFLOWS_DIR="${1#--dir=}"
    shift
    ;;
  --self-test)
    SELF_TEST=1
    shift
    ;;
  -h | --help)
    sed -n '2,45p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

python3 - "$WORKFLOWS_DIR" "$SELF_TEST" <<'PY'
import sys
import glob
import os

try:
    import yaml
except ImportError:  # pragma: no cover - the runner image ships PyYAML
    print("::error::PyYAML is required by tools/ci/check_claude_action_inputs.sh")
    sys.exit(1)

workflows_dir, self_test_flag = sys.argv[1], sys.argv[2] == "1"

CLAUDE_ACTION_PREFIX = "anthropics/claude-code-action@"

# anthropics/claude-code-action, src/modes/detector.ts, validateTrackProgressEvent
# (read at the SHA this repo pins in claude.yml/claude-iterate.yml).
VALID_TRACK_PROGRESS_EVENTS = {
    "pull_request",
    "issues",
    "issue_comment",
    "pull_request_review_comment",
    "pull_request_review",
}
VALID_PR_ACTIONS = {"opened", "synchronize", "ready_for_review", "reopened"}
# https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflows-run/events-that-trigger-workflows#pull_request
DEFAULT_PR_TYPES = {"opened", "synchronize", "reopened"}


def track_progress_enabled(value) -> bool:
    """Mirror the action's own truthiness: unset/absent/false is disabled,
    everything else (including a dynamic `${{ ... }}` expression this guard
    cannot evaluate) is conservatively treated as enabled."""
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in ("", "false"):
        return False
    return True


def get_triggers(doc):
    """Return {event_name: raw_block_or_None} for a workflow's `on:`. YAML 1.1
    (PyYAML) resolves a bare `on:` key to the boolean True, not the string
    "on" -- accept either."""
    triggers = doc.get(True, doc.get("on"))
    if isinstance(triggers, dict):
        return dict(triggers)
    if isinstance(triggers, list):
        return {str(name): None for name in triggers}
    if isinstance(triggers, str):
        return {triggers: None}
    return None


def check_workflow(doc, path):
    """Return a list of finding dicts for one parsed workflow document."""
    findings = []
    if not isinstance(doc, dict):
        return findings
    triggers = get_triggers(doc)
    if not triggers:
        return findings
    trigger_names = set(triggers.keys())

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        return findings

    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        for step in steps:
            if not isinstance(step, dict):
                continue
            uses = step.get("uses")
            if not isinstance(uses, str) or not uses.startswith(CLAUDE_ACTION_PREFIX):
                continue
            with_block = step.get("with")
            if not isinstance(with_block, dict):
                with_block = {}
            if not track_progress_enabled(with_block.get("track_progress")):
                continue

            step_label = step.get("name") or step.get("id") or "<unnamed step>"

            invalid_events = sorted(trigger_names - VALID_TRACK_PROGRESS_EVENTS)
            if invalid_events:
                findings.append(
                    {
                        "file": path,
                        "job": job_id,
                        "step": step_label,
                        "detail": (
                            f"track_progress is enabled but this workflow's trigger(s) "
                            f"{invalid_events} are outside the action's track_progress-valid "
                            f"event set {sorted(VALID_TRACK_PROGRESS_EVENTS)} -- every run "
                            "triggered by one of those events throws in detectMode() before "
                            "Claude is ever invoked (anthropics/claude-code-action "
                            "src/modes/detector.ts, validateTrackProgressEvent)."
                        ),
                    }
                )

            if "pull_request" in trigger_names:
                pr_block = triggers.get("pull_request")
                types = None
                if isinstance(pr_block, dict):
                    raw_types = pr_block.get("types")
                    if isinstance(raw_types, list):
                        types = {str(t) for t in raw_types}
                if types is None:
                    types = set(DEFAULT_PR_TYPES)
                bad_types = sorted(types - VALID_PR_ACTIONS)
                if bad_types:
                    findings.append(
                        {
                            "file": path,
                            "job": job_id,
                            "step": step_label,
                            "detail": (
                                f"track_progress is enabled and this workflow triggers on "
                                f"pull_request, but declared type(s) {bad_types} are outside "
                                f"the action's track_progress-valid pull_request actions "
                                f"{sorted(VALID_PR_ACTIONS)} -- a run with one of those "
                                "actions throws in detectMode() the same way (same source)."
                            ),
                        }
                    )
    return findings


def report(findings):
    for f in findings:
        print(
            f"::error::{f['file']}: job '{f['job']}' step '{f['step']}': {f['detail']}"
        )


def run_self_test():
    FIXTURES = [
        # ── positive controls: must be flagged ──────────────────────────────
        (
            "schedule-only",
            """
on:
  schedule:
    - cron: "0 8 * * 2"
jobs:
  iterate:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
        with:
          track_progress: true
""",
            True,
        ),
        (
            "workflow_dispatch-only",
            """
on:
  workflow_dispatch:
jobs:
  iterate:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: true
""",
            True,
        ),
        (
            "schedule+workflow_dispatch (the exact #870 shape)",
            """
on:
  schedule:
    - cron: "0 8 * * 2"
  workflow_dispatch:
    inputs:
      target:
        required: false
jobs:
  iterate:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: true
""",
            True,
        ),
        (
            "push+issues mixed (push is invalid even though issues is fine)",
            """
on:
  push:
    branches: [main]
  issues:
    types: [opened]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: true
""",
            True,
        ),
        (
            "pull_request restricted to an unsupported type",
            """
on:
  pull_request:
    types: [closed]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: true
""",
            True,
        ),
        (
            "non-literal expression on an invalid trigger (conservative)",
            """
on:
  workflow_dispatch:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: ${{ inputs.track }}
""",
            True,
        ),
        # ── negative controls: must NOT be flagged ──────────────────────────
        (
            "claude.yml-shaped: all-valid events",
            """
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  issues:
    types: [opened, assigned]
jobs:
  claude:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: true
""",
            False,
        ),
        (
            "claude-iterate.yml-shaped AFTER the fix: no track_progress at all",
            """
on:
  schedule:
    - cron: "0 8 * * 2"
  workflow_dispatch:
    inputs:
      target:
        required: false
jobs:
  iterate:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          claude_code_oauth_token: x
""",
            False,
        ),
        (
            "track_progress explicitly false on an invalid trigger",
            """
on:
  workflow_dispatch:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: false
""",
            False,
        ),
        (
            "pull_request with default types (omitted) is fully valid",
            """
on:
  pull_request: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: true
""",
            False,
        ),
        (
            "pull_request with an explicit valid type subset",
            """
on:
  pull_request:
    types: [opened, synchronize]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@deadbeef
        with:
          track_progress: true
""",
            False,
        ),
        (
            "unrelated action on an invalid trigger is ignored entirely",
            """
on:
  schedule:
    - cron: "0 0 * * *"
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: some-org/some-action@v1
        with:
          track_progress: true
""",
            False,
        ),
    ]

    passed = 0
    failed = 0
    for name, text, expect_finding in FIXTURES:
        doc = yaml.safe_load(text)
        findings = check_workflow(doc, f"<fixture:{name}>")
        got_finding = len(findings) > 0
        if got_finding == expect_finding:
            passed += 1
            print(f"PASS self-test fixture: {name}")
        else:
            failed += 1
            print(
                f"FAIL self-test fixture: {name} -- expected "
                f"{'a finding' if expect_finding else 'no finding'}, got {len(findings)}"
            )
            report(findings)

    total = passed + failed
    print(f"Results: {passed} passed, {failed} failed, {total} total (self-test)")
    if total < 8:
        print(
            f"::error::self-test ran only {total} fixture(s) -- a guard that stopped "
            "driving cases is not a guard."
        )
        sys.exit(1)
    sys.exit(1 if failed else 0)


def run_real_check():
    if not os.path.isdir(workflows_dir):
        print(f"::error::workflows directory not found: {workflows_dir}")
        print("Results: 0 passed, 1 failed, 1 total")
        sys.exit(1)

    all_findings = []
    steps_checked = 0
    for path in sorted(glob.glob(os.path.join(workflows_dir, "*.yml"))) + sorted(
        glob.glob(os.path.join(workflows_dir, "*.yaml"))
    ):
        with open(path, encoding="utf-8") as fh:
            try:
                doc = yaml.safe_load(fh)
            except yaml.YAMLError as exc:
                print(f"::error::{path} is not parseable YAML: {exc}")
                print("Results: 0 passed, 1 failed, 1 total")
                sys.exit(1)
        if not isinstance(doc, dict):
            continue
        jobs = doc.get("jobs")
        if isinstance(jobs, dict):
            for job in jobs.values():
                if not isinstance(job, dict):
                    continue
                for step in job.get("steps") or []:
                    if (
                        isinstance(step, dict)
                        and isinstance(step.get("uses"), str)
                        and step["uses"].startswith(CLAUDE_ACTION_PREFIX)
                    ):
                        steps_checked += 1
        all_findings.extend(check_workflow(doc, os.path.relpath(path, workflows_dir)))

    if steps_checked == 0:
        print(
            "::error::found zero anthropics/claude-code-action steps under "
            f"{workflows_dir} -- a guard that checked nothing must not report success "
            "(this repo ships at least claude.yml and claude-iterate.yml)."
        )
        print("Results: 0 passed, 1 failed, 1 total")
        sys.exit(1)

    # A single bad step can produce more than one finding (event + pull_request
    # action); collapse back to per-step pass/fail for the Results line.
    bad_steps = {(f["file"], f["job"], f["step"]) for f in all_findings}
    passed = steps_checked - len(bad_steps)
    failed = len(bad_steps)
    report(all_findings)
    print(f"Results: {passed} passed, {failed} failed, {steps_checked} total")
    sys.exit(1 if failed else 0)


if self_test_flag:
    run_self_test()
else:
    run_real_check()
PY
