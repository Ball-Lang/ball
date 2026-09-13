#!/usr/bin/env bash
# Per-PR job fan-out guard (issue #666).
#
# WHY THIS EXISTS. Runner concurrency is the measured bottleneck of this repo's
# PR sweep (2026-09-13: 30 workflow runs queued, 0 in progress, on a Free-plan
# org capped at 20 concurrent jobs / 5 macOS —
# https://docs.github.com/en/actions/reference/limits). Every lane push fans out
# into CI + Conformance Matrix + Regression Gates + Ball Security Audit, and the
# only thing that keeps that bounded is that each job is either REQUIRED (so it
# has to report on every PR anyway), or CONDITIONED on the `changes` outputs, or
# gated by its workflow's own `paths:` filter. Nothing enforced that. A new job
# added with no condition silently joins every PR forever, and the cost is
# invisible in review — it is one more `- name:` in a 2900-line file.
#
# THE OTHER HALF IS A CORRECTNESS GUARD, and it is the one that already bites.
# The 19 contexts of ruleset 17056238 must APPEAR on every PR: a job-level `if:`
# that skips still satisfies a required check, but a check that never reports
# blocks the merge forever. Two shapes break that:
#
#   * A MATRIX job whose `name:` interpolates `${{ matrix.<key> }}` and which
#     carries a job-level `if:`. When the `if:` is false GitHub emits ONE check
#     run under the UN-EXPANDED name — literally `C++ (${{ matrix.os }})` — so
#     the required contexts `C++ (ubuntu-latest)` / `(windows-latest)` /
#     `(macos-latest)` never appear at all. Measured on this repo: PR #647 at
#     bc0c367a, whose dart-only diff made ci.yml's `cpp` gate false, produced
#     exactly that single collapsed check and three permanently-missing required
#     contexts. Gate such a job at STEP level instead, so every leg reports.
#   * A job that owns a required context inside a workflow whose
#     `pull_request:` trigger is `paths:`-filtered. A PR that misses the filter
#     never starts the workflow, so the context never reports. (docs/
#     TESTING_STRATEGY.md, "never require path-filtered jobs".)
#
# THE RULE. Every job reachable on `pull_request` in the five PR workflows must
# satisfy at least one of:
#   (a) it owns one of the 19 required contexts — it has to report anyway;
#   (b) its job-level `if:` references a `changes` job output
#       (`needs.<job>.outputs.<x>` where <job> is a job using the
#       detect-changed-stacks action);
#   (c) its workflow's `pull_request:` trigger carries a `paths:` filter, so the
#       whole workflow is already conditioned on the diff;
#   (d) it is listed in tools/ci/pr_job_fanout_allowlist.txt with a reason;
#   (e) it IS the `changes` classifier itself — the ~10-second job every other
#       condition reads. Conditioning the classifier on its own output is not a
#       thing, and it is the cheapest job in the repo.
# ...and no job may break either of the two report-safety shapes above.
#
# POSITIVE FLOOR: a guard that inspected nothing must not report success. Zero
# workflows parsed, zero jobs classified, or zero required contexts matched
# across the whole set are all hard errors.
#
# Usage:
#   bash tools/ci/check_pr_job_fanout.sh              # gate the repo
#   bash tools/ci/check_pr_job_fanout.sh --self-test  # drive the cases
#
# Needs bash + python3 + PyYAML (the runner image ships both), so it runs in
# ci.yml's always-on `proto` job with no toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW_DIR="$ROOT/.github/workflows"
ALLOWLIST="$ROOT/tools/ci/pr_job_fanout_allowlist.txt"
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
  --allowlist)
    ALLOWLIST="$2"
    shift 2
    ;;
  --allowlist=*)
    ALLOWLIST="${1#--allowlist=}"
    shift
    ;;
  --self-test)
    SELF_TEST=1
    shift
    ;;
  -h | --help)
    sed -n '2,52p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

# ── the check itself ────────────────────────────────────────────────────────
# python3 because the workflows use YAML anchors/aliases (conformance-matrix's
# `paths: &matrix_paths` / `*matrix_paths`) and matrix expansion — neither of
# which a grep can see. The parser is the only thing that reads these files the
# way GitHub does.
check_dir() {
  local dir="$1" allowlist="$2"
  python3 - "$dir" "$allowlist" <<'PY'
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the runner image ships PyYAML
    print("::error::PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

workflow_dir, allowlist_path = sys.argv[1], sys.argv[2]

# The workflows that run on `pull_request` and carry the PR fan-out. A new PR
# workflow must be added here deliberately, with its jobs classified.
WORKFLOWS = [
    "ci.yml",
    "conformance-matrix.yml",
    "regression-gates.yml",
    "ball-audit.yml",
    "coverage.yml",
]

# The 19 required status contexts of ruleset 17056238 (read back with
# `gh api repos/Ball-Lang/ball/rulesets/17056238`). These must APPEAR on every
# PR — see the header. Keep this list and the ruleset identical; a context here
# that no job owns is a hard error below, which is what catches a rename.
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
DETECT_ACTION = "detect-changed-stacks"

errors = []
notes = []
jobs_checked = 0
matched_contexts = set()

# ── allow-list: "<workflow>:<job-id>  # reason" ─────────────────────────────
allowed = {}
if os.path.exists(allowlist_path):
    with open(allowlist_path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            entry, sep, reason = line.partition("#")
            entry = entry.strip()
            reason = reason.strip()
            if not sep or not reason:
                errors.append(
                    f"{allowlist_path}:{lineno}: allow-list entry '{entry}' has no "
                    "'# <reason>' — an allow-list without a reason is a silent exemption"
                )
                continue
            if entry.count(":") != 1:
                errors.append(
                    f"{allowlist_path}:{lineno}: expected '<workflow.yml>:<job-id>', got '{entry}'"
                )
                continue
            allowed[entry] = reason


def trigger(on, name):
    """The `pull_request:` (or `push:`) mapping, normalised to a dict."""
    if isinstance(on, dict):
        if name not in on:
            return None
        value = on[name]
        return value if isinstance(value, dict) else {}
    if isinstance(on, list):
        return {} if name in on else None
    return {} if on == name else None


def job_names(job):
    """Every check-run name this job can produce, and whether it is a matrix."""
    name = job.get("name")
    if not isinstance(name, str) or not name:
        return [], False
    refs = MATRIX_REF.findall(name)
    if not refs:
        return [name], False
    matrix = ((job.get("strategy") or {}).get("matrix")) or {}
    expanded = [name]
    for key in refs:
        values = matrix.get(key)
        if not isinstance(values, list):
            # Cannot expand (a dynamic `fromJSON` matrix): the un-expanded name
            # is all we can assert, and it can never equal a required context.
            return [name], True
        expanded = [
            n.replace(m.group(0), str(v))
            for n in expanded
            for v in values
            for m in [MATRIX_REF.search(n)]
            if m and m.group(1) == key
        ]
    return expanded, True


for wf_name in WORKFLOWS:
    path = os.path.join(workflow_dir, wf_name)
    if not os.path.exists(path):
        errors.append(f"{wf_name}: not found under {workflow_dir}")
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001 - report any parse failure verbatim
        errors.append(f"{wf_name}: YAML parse failed: {exc}")
        continue
    if not isinstance(doc, dict):
        errors.append(f"{wf_name}: not a YAML mapping")
        continue

    # PyYAML resolves the bare `on:` key to the boolean True.
    on = doc.get("on", doc.get(True))
    pr = trigger(on, "pull_request")
    if pr is None:
        errors.append(f"{wf_name}: no `pull_request:` trigger — not a PR workflow")
        continue
    workflow_conditioned = bool(pr.get("paths"))

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        errors.append(f"{wf_name}: no jobs")
        continue

    # Which job ids are `changes`-style producers (they run the composite
    # detect action)? An `if:` is only a real stack condition if it reads one.
    detect_jobs = set()
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if isinstance(step, dict) and DETECT_ACTION in str(step.get("uses", "")):
                detect_jobs.add(job_id)

    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            errors.append(f"{wf_name}:{job_id}: not a mapping")
            continue
        jobs_checked += 1
        names, is_matrix = job_names(job)
        owns = [n for n in names if n in REQUIRED_CONTEXTS]
        matched_contexts.update(owns)
        cond = job.get("if")
        cond = "" if cond is None else str(cond)
        conditioned = any(
            re.search(r"needs\.%s\.outputs\." % re.escape(dj), cond) for dj in detect_jobs
        )
        key = f"{wf_name}:{job_id}"

        # ── report-safety 1: a skipped matrix job reports under one
        # un-expanded name, so its required contexts never appear. ──────────
        if owns and is_matrix and cond:
            errors.append(
                f"{key}: owns required context(s) {sorted(owns)} and is a MATRIX job with a "
                "job-level `if:`. When that `if:` is false GitHub emits a single check run "
                f"named '{job.get('name')}' verbatim, so those contexts never report and the "
                "PR can never merge. Move the condition to the job's STEPS so every leg reports."
            )

        # ── report-safety 2: a required context behind a workflow-level
        # `paths:` filter never reports on a PR that misses the filter. ─────
        if owns and workflow_conditioned:
            errors.append(
                f"{key}: owns required context(s) {sorted(owns)} inside a workflow whose "
                "`pull_request:` trigger is `paths:`-filtered. A PR that misses the filter "
                "never starts the workflow, so the context stays pending forever."
            )

        # ── fan-out: required, conditioned, workflow-filtered, allow-listed,
        # or the `changes` classifier itself. ───────────────────────────────
        if owns or conditioned or workflow_conditioned or key in allowed or job_id in detect_jobs:
            if key in allowed and not (owns or conditioned or workflow_conditioned):
                notes.append(f"allow-listed  {key}: {allowed[key]}")
            continue
        errors.append(
            f"{key}: runs on every pull_request unconditionally. Give it a job-level `if:` on a "
            "`changes` output, or add it to tools/ci/pr_job_fanout_allowlist.txt with a reason."
        )

# ── positive floors ─────────────────────────────────────────────────────────
if jobs_checked < 1:
    errors.append("classified zero jobs — the guard inspected nothing")
missing = sorted(REQUIRED_CONTEXTS - matched_contexts)
if missing:
    errors.append(
        "no job in the PR workflows produces these required context(s): "
        + ", ".join(missing)
        + " — either a job was renamed or the ruleset changed"
    )

for note in notes:
    print(note)
if errors:
    for err in errors:
        print(f"::error::{err}")
    print(f"FAIL: {len(errors)} finding(s) over {jobs_checked} job(s)")
    sys.exit(1)
print(
    f"OK: {jobs_checked} pull_request job(s) across {len(WORKFLOWS)} workflow(s); "
    f"{len(matched_contexts)} required context(s) owned; every job is required, "
    "stack-conditioned, workflow-path-filtered or allow-listed."
)
PY
}

# ── self-test ───────────────────────────────────────────────────────────────
# Drives the guard over synthetic workflow sets: the fabricated unconditional
# job MUST be rejected, and each accepted shape MUST pass. A guard nobody proved
# can fail is not a guard.
self_test() {
  local tmp pass=0 fail=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # A minimal but COMPLETE stand-in set: between them these four files own all
  # 19 required contexts, so the guard's own positive floor is satisfied and
  # each case differs from the baseline in exactly one way.
  scaffold() {
    local dir="$1"
    mkdir -p "$dir"
    cat >"$dir/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
    branches: [main]
jobs:
  changes:
    name: Detect changed stacks
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/detect-changed-stacks
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
jobs:
  changes:
    name: Detect changed stacks
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/detect-changed-stacks
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
    cat >"$dir/conformance-matrix.yml" <<'YAML'
name: Conformance Matrix
on:
  pull_request:
    paths: ["tests/conformance/**"]
jobs:
  dart-engine:
    name: Dart Engine
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
YAML
    cat >"$dir/coverage.yml" <<'YAML'
name: Coverage
on:
  pull_request:
    branches: [main]
    paths: ["cpp/**"]
jobs:
  cpp:
    name: C++ coverage
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
YAML
    cat >"$dir/ball-audit.yml" <<'YAML'
name: Ball Security Audit
on:
  pull_request:
    paths: ["**.ball.json"]
jobs:
  audit:
    name: Capability Audit
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
YAML
  }

  case_run() {
    local name="$1" expect="$2" dir="$3" allow="$4"
    local out rc
    out="$(check_dir "$dir" "$allow" 2>&1)"
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

  : >"$tmp/empty-allowlist"

  # 1. The baseline set is accepted.
  scaffold "$tmp/base"
  case_run "baseline accepted" 0 "$tmp/base" "$tmp/empty-allowlist"

  # 2. NEGATIVE CONTROL — a fabricated unconditional job joins every PR.
  scaffold "$tmp/unconditional"
  cat >>"$tmp/unconditional/ci.yml" <<'YAML'
  brand-new-job:
    name: Brand New Unconditional Job
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
YAML
  case_run "unconditional new job rejected" 1 "$tmp/unconditional" "$tmp/empty-allowlist"

  # 3. ...the same job, conditioned on a `changes` output, is accepted.
  scaffold "$tmp/conditioned"
  cat >>"$tmp/conditioned/ci.yml" <<'YAML'
  brand-new-job:
    name: Brand New Conditioned Job
    if: ${{ needs.changes.outputs.rust == 'true' }}
    needs: changes
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
YAML
  case_run "changes-conditioned new job accepted" 0 "$tmp/conditioned" "$tmp/empty-allowlist"

  # 4. ...and so is the same job when explicitly allow-listed with a reason.
  scaffold "$tmp/allowed"
  cat >>"$tmp/allowed/ci.yml" <<'YAML'
  brand-new-job:
    name: Brand New Allow-listed Job
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
YAML
  echo 'ci.yml:brand-new-job  # self-test: proves the allow-list path' >"$tmp/allowlist"
  case_run "allow-listed new job accepted" 0 "$tmp/allowed" "$tmp/allowlist"

  # 5. An allow-list entry with NO reason is a silent exemption — rejected.
  echo 'ci.yml:brand-new-job' >"$tmp/allowlist-noreason"
  case_run "allow-list entry without a reason rejected" 1 "$tmp/allowed" "$tmp/allowlist-noreason"

  # 6. NEGATIVE CONTROL — a job-level `if:` on the required C++ MATRIX job.
  # This is the shape that collapsed three required contexts into one
  # un-expanded check name on PR #647 at bc0c367a.
  scaffold "$tmp/matrix-if"
  python3 - "$tmp/matrix-if/ci.yml" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace(
    "    name: C++ (${{ matrix.os }})\n",
    "    name: C++ (${{ matrix.os }})\n    if: ${{ needs.changes.outputs.cpp == 'true' }}\n",
)
open(path, "w", encoding="utf-8").write(src)
PY
  case_run "job-level if on a required matrix job rejected" 1 "$tmp/matrix-if" "$tmp/empty-allowlist"

  # 7. NEGATIVE CONTROL — a required context behind a workflow `paths:` filter
  # never reports on a PR that misses the filter.
  scaffold "$tmp/paths-required"
  python3 - "$tmp/paths-required/ci.yml" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace(
    "  pull_request:\n    branches: [main]\n",
    "  pull_request:\n    branches: [main]\n    paths: [\"dart/**\"]\n",
)
open(path, "w", encoding="utf-8").write(src)
PY
  case_run "required context behind a paths filter rejected" 1 "$tmp/paths-required" "$tmp/empty-allowlist"

  # 8. NEGATIVE CONTROL — a renamed job orphans a required context.
  scaffold "$tmp/renamed"
  python3 - "$tmp/renamed/ci.yml" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace("    name: Proto Checks\n", "    name: Proto Checks (renamed)\n")
open(path, "w", encoding="utf-8").write(src)
PY
  case_run "renamed job orphaning a required context rejected" 1 "$tmp/renamed" "$tmp/empty-allowlist"

  local total=$((pass + fail))
  # Positive floor: an exit code plus a failure count cannot tell "everything
  # passed" from "nothing ran".
  if [ "$total" -lt 8 ]; then
    echo "::error::self-test ran $total case(s), expected 8"
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

check_dir "$WORKFLOW_DIR" "$ALLOWLIST"
exit $?
