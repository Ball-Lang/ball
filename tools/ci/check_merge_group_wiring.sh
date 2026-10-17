#!/usr/bin/env bash
# Merge-queue wiring guard (issue #756).
#
# WHY THIS EXISTS. #756 is the owner's 2026-10-17 decision to adopt a GitHub
# merge queue on `main` instead of `strict_required_status_checks_policy`: a
# merge group re-runs the 19 required status checks of ruleset 17056238
# against a SPECULATIVE commit (this branch's target + the other entries
# ahead of it in the queue) before fast-forwarding `main` to it — exactly what
# would have caught #749's "two branches green alone, red on their union"
# failure one merge sooner than main itself did.
#
# None of that works unless every workflow that OWNS one of those 19 contexts
# also runs on the `merge_group` event. A workflow with only `push:` and
# `pull_request:` triggers simply never starts for a merge group's ref, so the
# required context it owns never reports — and the merge queue then blocks
# that entry FOREVER waiting on a check that will never run, which is worse
# than the gap #756 exists to close: a merge queue nobody can use is not a
# weaker guard, it is a stuck repository.
#
# And a workflow that DOES get the `merge_group:` trigger is not enough on its
# own either, if its own change-detection silently runs less than the
# pull_request path would. `detect-changed-stacks` (the single source of truth
# for ci.yml's and regression-gates.yml's `changes` jobs, #458) resolves its
# diff base from the triggering event; a merge_group event carries neither a
# `pull_request` payload nor `before`, so without an explicit branch for it the
# classifier's base stays empty and it silently FAILS OPEN (runs every stack —
# safe, but means the queue always pays the full ~25-minute C++ matrix instead
# of the real diff, and masks the day someone breaks the real wiring by making
# the fallback look identical to the intended behaviour). This guard checks for
# the real, keyed branch — not just the harmless fallback.
#
# THE RULE, in two parts:
#   (a) every workflow under .github/workflows that owns at least one of the
#       19 required contexts (job `name:`, matrix-expanded) declares a
#       top-level `merge_group:` trigger whose `types:` list contains
#       `checks_requested` (the only activity type GitHub supports today —
#       https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#merge_group);
#   (b) `.github/actions/detect-changed-stacks/action.yml` feeds the detect
#       step an env value sourced from `github.event.merge_group` (its own
#       diff-base input for that event), AND `detect.sh` contains a real,
#       keyed `EVENT = "merge_group"` branch — not merely a comment that says
#       so — so the classifier does not just fall through to the fail-open
#       block for every merge group forever.
#
# POSITIVE FLOOR: a guard that matched zero required contexts, or found zero
# workflows to check, inspected nothing and must not report success.
#
# Usage:
#   bash tools/ci/check_merge_group_wiring.sh              # gate the repo
#   bash tools/ci/check_merge_group_wiring.sh --self-test   # drive the cases
#
# Needs bash + python3 + PyYAML (the runner image ships both), so it runs in
# ci.yml's always-on `Proto Checks` job with no toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW_DIR="$ROOT/.github/workflows"
ACTION_DIR="$ROOT/.github/actions/detect-changed-stacks"
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
  --workflow-dir)
    WORKFLOW_DIR="$2"
    shift 2
    ;;
  --workflow-dir=*)
    WORKFLOW_DIR="${1#--workflow-dir=}"
    shift
    ;;
  --action-dir)
    ACTION_DIR="$2"
    shift 2
    ;;
  --action-dir=*)
    ACTION_DIR="${1#--action-dir=}"
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

# ── the check itself ────────────────────────────────────────────────────────
# python3 because the workflows use YAML anchors/aliases and matrix expansion —
# neither of which a grep can see — and because reading the real parsed `env:`
# mapping of the composite action (rather than grepping its raw text) is the
# only way to tell "this value references merge_group" from "a COMMENT
# mentions merge_group", which this file's own header now does, repeatedly.
check_dir() {
  local workflow_dir="$1" action_dir="$2"
  python3 - "$workflow_dir" "$action_dir" <<'PY'
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the runner image ships PyYAML
    print("::error::PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

workflow_dir, action_dir = sys.argv[1], sys.argv[2]

# The 19 required status contexts of ruleset 17056238 (read back with
# `gh api repos/Ball-Lang/ball/rulesets/17056238`) — the same literal set
# tools/ci/check_pr_job_fanout.sh carries, kept honest against the live
# ruleset by tools/ci/check_required_contexts.sh. A context here that no job
# owns is a hard error below, which is what catches a rename of either list.
REQUIRED_CONTEXTS = {
    "Ball Artifact Freshness",
    "C#",
    "C++ (macos-latest)",
    "C++ (ubuntu-latest)",
    "C++ (windows-latest)",
    "C++ Self-Host Tally (every fixture must pass)",
    "CLI Verb Parity",
    "Dart",
    "Dart Coverage Ratchet",
    "Dart Regression Gate (engine + encoder + compiler)",
    "Detect changed stacks",
    "Go",
    "Proto Checks",
    "Protobuf Codegen (gen + rpc)",
    "Python",
    "Rust",
    "TS Regression Gate (engine + compiler)",
    "TypeScript",
    "Upstream Conformance (Editions)",
}

MATRIX_REF = re.compile(r"\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}")

errors = []
jobs_checked = 0
workflows_scanned = 0
matched_contexts = set()
owning_workflows = set()


def job_names(job):
    """Every check-run name this job can produce (matrix-expanded)."""
    name = job.get("name")
    if not isinstance(name, str) or not name:
        return []
    refs = MATRIX_REF.findall(name)
    if not refs:
        return [name]
    matrix = ((job.get("strategy") or {}).get("matrix")) or {}
    expanded = [name]
    for key in refs:
        values = matrix.get(key)
        if not isinstance(values, list):
            return [name]
        expanded = [
            n.replace(m.group(0), str(v))
            for n in expanded
            for v in values
            for m in [MATRIX_REF.search(n)]
            if m and m.group(1) == key
        ]
    return expanded


if not os.path.isdir(workflow_dir):
    print(f"::error::no such workflow directory: {workflow_dir}")
    print("Results: 0 passed, 1 failed, 1 total")
    sys.exit(1)

for fname in sorted(os.listdir(workflow_dir)):
    if not fname.endswith((".yml", ".yaml")):
        continue
    path = os.path.join(workflow_dir, fname)
    try:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001 - report any parse failure verbatim
        errors.append(f"{fname}: YAML parse failed: {exc}")
        continue
    if not isinstance(doc, dict):
        continue
    workflows_scanned += 1

    jobs = doc.get("jobs")
    jobs = jobs if isinstance(jobs, dict) else {}
    owned_here = set()
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        jobs_checked += 1
        owned_here.update(n for n in job_names(job) if n in REQUIRED_CONTEXTS)
    if not owned_here:
        continue

    matched_contexts.update(owned_here)
    owning_workflows.add(fname)

    # PyYAML resolves the bare `on:` key to the boolean True.
    on = doc.get("on", doc.get(True))
    on = on if isinstance(on, dict) else {}
    merge_group = on.get("merge_group")
    if merge_group is None:
        errors.append(
            f"{fname}: owns required context(s) {sorted(owned_here)} but declares no "
            "top-level `merge_group:` trigger — a merge group built from queued PRs "
            "touching this stack would never start this workflow, and the context would "
            "stay pending on that merge group forever (#756)."
        )
        continue
    merge_group = merge_group if isinstance(merge_group, dict) else {}
    types = merge_group.get("types")
    types = types if isinstance(types, list) else []
    if "checks_requested" not in types:
        errors.append(
            f"{fname}: `merge_group:` trigger does not declare "
            f"`types: [checks_requested]` (found {types!r}). `checks_requested` is the "
            "only activity type GitHub supports today, and naming it explicitly is what "
            "keeps this specific if GitHub adds more (#756)."
        )

if workflows_scanned < 1:
    errors.append(f"scanned zero workflow files under {workflow_dir} — inspected nothing")

missing = sorted(REQUIRED_CONTEXTS - matched_contexts)
if missing:
    errors.append(
        "no job in any workflow under "
        f"{workflow_dir} produces these required context(s): {', '.join(missing)} — "
        "either a job was renamed or the ruleset changed; this guard's own required-context "
        "set must track tools/ci/check_pr_job_fanout.sh and the live ruleset."
    )

# ── (b): the shared classifier itself must handle merge_group, not just fall
# through to its (safe but unintentional-looking) fail-open path. ───────────
action_path = os.path.join(action_dir, "action.yml")
detect_path = os.path.join(action_dir, "detect.sh")

if not os.path.isfile(action_path):
    errors.append(f"not found: {action_path}")
else:
    try:
        with open(action_path, encoding="utf-8") as fh:
            action_doc = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001
        errors.append(f"{action_path}: YAML parse failed: {exc}")
        action_doc = None
    if isinstance(action_doc, dict):
        steps = (((action_doc.get("runs") or {}).get("steps")) or [])
        env_values = []
        for step in steps:
            if not isinstance(step, dict):
                continue
            env = step.get("env")
            if isinstance(env, dict):
                env_values.extend(str(v) for v in env.values())
        if not any("github.event.merge_group" in v for v in env_values):
            errors.append(
                f"{action_path}: no step's `env:` references `github.event.merge_group` — "
                "the composite action has nothing to pass detect.sh as a merge_group diff "
                "base, so a merge_group run can only ever take the fail-open path (#756)."
            )

if not os.path.isfile(detect_path):
    errors.append(f"not found: {detect_path}")
else:
    with open(detect_path, encoding="utf-8") as fh:
        detect_src = fh.read()
    # Mirrors the exact shape of the pre-existing pull_request/push branches
    # (`[ "${EVENT:-}" = "pull_request" ] && base=...`), anchored to a line
    # that OPENS with `[` — so a comment merely mentioning "merge_group"
    # (this very script's header does, and so does detect.sh's own, #756)
    # cannot satisfy it. Requires both the EVENT test and a real assignment
    # keyed on it, not just one half.
    keyed_test = re.search(
        r'^\s*\[\s*"\$\{EVENT:-\}"\s*=\s*"merge_group"\s*\]', detect_src, re.M
    )
    base_assignment = re.search(r"base=\"\$\{MERGE_GROUP_BASE_SHA:-\}\"", detect_src)
    if not (keyed_test and base_assignment):
        errors.append(
            f"{detect_path}: carries no real `[ \"${{EVENT:-}}\" = \"merge_group\" ]` "
            "branch assigning `base` from `MERGE_GROUP_BASE_SHA` — only a comment "
            "mentioning merge_group does not count. Without this, every merge_group run "
            "silently takes the fail-open path (every stack runs; safe, but not the "
            "intended wiring) and nothing would ever fail loud the day it regresses (#756)."
        )

if errors:
    for err in errors:
        print(f"::error::{err}")
    print(f"FAIL: {len(errors)} finding(s)")
    sys.exit(1)

print(
    f"OK: {workflows_scanned} workflow file(s) scanned, {jobs_checked} job(s) classified, "
    f"{len(owning_workflows)} workflow(s) own a required context "
    f"({', '.join(sorted(owning_workflows))}) and all declare `merge_group: "
    "types: [checks_requested]`; detect-changed-stacks handles merge_group for real."
)
PY
}

# ── self-test ───────────────────────────────────────────────────────────────
self_test() {
  local tmp pass=0 fail=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # A minimal but COMPLETE stand-in set: between the two files below every one
  # of the 19 required contexts is owned, so the guard's own positive floor is
  # satisfied and each case differs from the baseline in exactly one way.
  scaffold_workflows() {
    local dir="$1"
    mkdir -p "$dir"
    cat >"$dir/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
    branches: [main]
  merge_group:
    types: [checks_requested]
jobs:
  changes:
    name: Detect changed stacks
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  proto:
    name: Proto Checks
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  cli-verb-parity:
    name: CLI Verb Parity
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  dart-coverage:
    name: Dart Coverage Ratchet
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  ball-freshness:
    name: Ball Artifact Freshness
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  protobuf-codegen:
    name: Protobuf Codegen (gen + rpc)
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  editions:
    name: Upstream Conformance (Editions)
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  dart:
    name: Dart
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  typescript:
    name: TypeScript
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  rust:
    name: Rust
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  csharp:
    name: C#
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  go:
    name: Go
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  python:
    name: Python
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  cpp:
    name: C++ (${{ matrix.os }})
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps: [{ run: "true" }]
YAML
    cat >"$dir/regression-gates.yml" <<'YAML'
name: Regression Gates
on:
  pull_request:
    branches: [main]
  merge_group:
    types: [checks_requested]
jobs:
  dart-regression:
    name: Dart Regression Gate (engine + encoder + compiler)
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  ts-regression:
    name: TS Regression Gate (engine + compiler)
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  cpp-selfhost-tally:
    name: C++ Self-Host Tally (every fixture must pass)
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
YAML
    # Owns no required context, and carries no merge_group trigger either —
    # proves the guard does not demand merge_group off a workflow it has no
    # business requiring it from.
    cat >"$dir/coverage.yml" <<'YAML'
name: Coverage
on:
  pull_request:
    paths: ["cpp/**"]
jobs:
  cpp:
    name: C++ coverage
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
YAML
  }

  scaffold_action() {
    local dir="$1"
    mkdir -p "$dir"
    cat >"$dir/action.yml" <<'YAML'
name: Detect changed stacks
runs:
  using: composite
  steps:
    - id: detect
      shell: bash
      env:
        EVENT: ${{ github.event_name }}
        PR_BASE: ${{ github.event.pull_request.base.sha }}
        PUSH_BASE: ${{ github.event.before }}
        MERGE_GROUP_BASE_SHA: ${{ github.event.merge_group.base_sha }}
      run: bash "$GITHUB_ACTION_PATH/detect.sh"
YAML
    cat >"$dir/detect.sh" <<'SH'
#!/usr/bin/env bash
# merge_group (#756): base_sha is the target branch's tip.
ball_detect_main() {
  local base=""
  [ "${EVENT:-}" = "pull_request" ] && base="${PR_BASE:-}" || true
  [ "${EVENT:-}" = "push" ] && base="${PUSH_BASE:-}" || true
  [ "${EVENT:-}" = "merge_group" ] && base="${MERGE_GROUP_BASE_SHA:-}" || true
}
SH
  }

  case_run() {
    local name="$1" expect="$2" wf_dir="$3" action_dir="$4"
    local out rc
    out="$(check_dir "$wf_dir" "$action_dir" 2>&1)"
    rc=$?
    if [ "$rc" -eq "$expect" ]; then
      pass=$((pass + 1))
      echo "PASS  $name (exit $rc)"
    else
      fail=$((fail + 1))
      echo "FAIL  $name (exit $rc, wanted $expect)"
      printf '  %s\n' "$out"
    fi
  }

  # 1. The baseline set is accepted.
  scaffold_workflows "$tmp/base/wf"
  scaffold_action "$tmp/base/action"
  case_run "baseline accepted" 0 "$tmp/base/wf" "$tmp/base/action"

  # 2. NEGATIVE CONTROL — a required-context workflow with NO merge_group
  # trigger at all.
  scaffold_workflows "$tmp/no-trigger/wf"
  scaffold_action "$tmp/no-trigger/action"
  python3 - "$tmp/no-trigger/wf/ci.yml" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace("  merge_group:\n    types: [checks_requested]\n", "")
open(path, "w", encoding="utf-8").write(src)
PY
  case_run "required-context workflow missing merge_group rejected" 1 "$tmp/no-trigger/wf" "$tmp/no-trigger/action"

  # 3. NEGATIVE CONTROL — merge_group present but with no `types:` at all.
  scaffold_workflows "$tmp/no-types/wf"
  scaffold_action "$tmp/no-types/action"
  python3 - "$tmp/no-types/wf/ci.yml" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace("  merge_group:\n    types: [checks_requested]\n", "  merge_group: {}\n")
open(path, "w", encoding="utf-8").write(src)
PY
  case_run "merge_group with no types rejected" 1 "$tmp/no-types/wf" "$tmp/no-types/action"

  # 4. NEGATIVE CONTROL — the only workflow WITHOUT a required context gets
  # merge_group too; this must still be accepted (never required, but never
  # forbidden either).
  scaffold_workflows "$tmp/extra-trigger/wf"
  scaffold_action "$tmp/extra-trigger/action"
  python3 - "$tmp/extra-trigger/wf/coverage.yml" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace(
    "  pull_request:\n    paths: [\"cpp/**\"]\n",
    "  pull_request:\n    paths: [\"cpp/**\"]\n  merge_group:\n    types: [checks_requested]\n",
)
open(path, "w", encoding="utf-8").write(src)
PY
  case_run "non-owning workflow may carry merge_group too" 0 "$tmp/extra-trigger/wf" "$tmp/extra-trigger/action"

  # 5. NEGATIVE CONTROL — action.yml's env never mentions merge_group.
  scaffold_workflows "$tmp/no-env/wf"
  scaffold_action "$tmp/no-env/action"
  python3 - "$tmp/no-env/action/action.yml" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace("        MERGE_GROUP_BASE_SHA: ${{ github.event.merge_group.base_sha }}\n", "")
open(path, "w", encoding="utf-8").write(src)
PY
  case_run "action.yml with no merge_group env rejected" 1 "$tmp/no-env/wf" "$tmp/no-env/action"

  # 6. NEGATIVE CONTROL — detect.sh only MENTIONS merge_group in a comment,
  # with no real keyed branch. This is the case a naive grep would miss.
  scaffold_workflows "$tmp/comment-only/wf"
  scaffold_action "$tmp/comment-only/action"
  cat >"$tmp/comment-only/action/detect.sh" <<'SH'
#!/usr/bin/env bash
# TODO: this comment mentions merge_group but wires nothing (#756).
ball_detect_main() {
  local base=""
  [ "${EVENT:-}" = "pull_request" ] && base="${PR_BASE:-}" || true
  [ "${EVENT:-}" = "push" ] && base="${PUSH_BASE:-}" || true
}
SH
  case_run "comment-only merge_group mention in detect.sh rejected" 1 "$tmp/comment-only/wf" "$tmp/comment-only/action"

  # 7. NEGATIVE CONTROL — detect.sh has the EVENT test but assigns `base` from
  # the wrong variable (a copy/paste of the push branch) — proves both halves
  # of the regex (the keyed test AND the assignment) are required.
  scaffold_workflows "$tmp/wrong-assign/wf"
  scaffold_action "$tmp/wrong-assign/action"
  cat >"$tmp/wrong-assign/action/detect.sh" <<'SH'
#!/usr/bin/env bash
ball_detect_main() {
  local base=""
  [ "${EVENT:-}" = "pull_request" ] && base="${PR_BASE:-}" || true
  [ "${EVENT:-}" = "push" ] && base="${PUSH_BASE:-}" || true
  [ "${EVENT:-}" = "merge_group" ] && base="${PUSH_BASE:-}" || true
}
SH
  case_run "detect.sh keyed test with the wrong base variable rejected" 1 "$tmp/wrong-assign/wf" "$tmp/wrong-assign/action"

  local total=$((pass + fail))
  # Positive floor: an exit code plus a failure count cannot tell "everything
  # passed" from "nothing ran".
  if [ "$total" -lt 7 ]; then
    echo "::error::self-test ran $total case(s), expected 7"
    return 1
  fi
  echo "Results: $pass passed, $fail failed, $total total"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

check_dir "$WORKFLOW_DIR" "$ACTION_DIR"
exit $?
