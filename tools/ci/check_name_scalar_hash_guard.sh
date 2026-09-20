#!/usr/bin/env bash
# Guard against a plain `name:` scalar truncating at an unquoted ` #` (issue
# #704, follow-up to #666/#671).
#
# WHY THIS EXISTS. YAML treats a `#` preceded by whitespace as the start of a
# comment inside a PLAIN (unquoted) scalar — https://yaml.org/spec/1.2.2/#66-comments,
# "Comments must be separated from other tokens by white space characters."
# `- name: C++ e2e fixture-list drift guard (#63 / #511)` therefore parses as
# `name: "C++ e2e fixture-list drift guard (#63 /"` — the visible name silently
# truncates at the FIRST unquoted `<space>#`, both in the Actions UI and to
# anything that reads the parsed YAML.
#
# PR #671 (closed #666) quoted two step names that truncated this way; its own
# review found three more the same PR had missed, and this guard's own first
# run against `main` found a FOURTH (`ci.yml`'s "Engine-row doc drift guard
# (#610, #613)" step, added by #652 — before #671 even opened, so its reviewer
# never saw it either). That is exactly the failure mode a guard exists to
# close: a human audit of "every workflow name" is a claim about a moving
# 2900-line file, and nothing kept re-checking it after the fix landed.
#
# WHAT IT CHECKS: every plain-scalar `name:` mapping value — the workflow's own
# top-level `name:`, a job's `name:`, and a step's `- name:` — in
# `.github/workflows/*.yml` and `.github/actions/*/action.yml`. A value is
# flagged when it is NOT already quoted (does not start with `'` or `"`) and
# either starts with `#` (an immediate comment — an accidentally EMPTY name) or
# contains an unquoted `<space>#` / `<tab>#` anywhere after that (the
# truncating case). It is a plain line/regex scanner — deliberately
# PyYAML-free, unlike tools/ci/check_pr_job_fanout.sh's parser, so this repo
# has two independent ways of reading these files and neither depends on the
# other's toolchain. It tracks block scalars (`key: |` / `key: >`, with an
# optional `+`/`-` chomping indicator) by indentation so a `run: |` step body
# that happens to contain the literal text "name: ... #" is never mistaken for
# a real mapping key — see the self-test's block-scalar case.
#
# JOB NAMES ARE THE DANGEROUS CASE, STEP NAMES ARE COSMETIC. A step's display
# name truncating is cosmetic (Actions UI only); a JOB's `name:` truncating
# would silently change one of ruleset 17056238's 19 required status contexts,
# which is a merge-blocking correctness bug, not a cosmetic one. So every
# finding below is tagged `workflow` / `job` / `step` by structural position
# (a dash-prefixed `- name:` is always a step; an un-dashed `name:` at column 0
# is the workflow's own name; anything else un-dashed is a job's). Today's four
# offenders are all `step` — quoting them cannot move a required context, and
# tools/ci/check_pr_job_fanout.sh (run on every PR) independently re-derives
# and asserts the full 19-context set from the parsed job `name:` values, so a
# future `job`-tagged finding would still be caught by that gate even if this
# one were somehow bypassed.
#
# POSITIVE FLOOR: a scanner that read zero files or matched zero `name:` lines
# must not report success — that is "nothing ran", not "nothing is wrong".
#
# Usage:
#   bash tools/ci/check_name_scalar_hash_guard.sh              # gate the repo
#   bash tools/ci/check_name_scalar_hash_guard.sh --self-test  # drive the cases
#
# Needs bash + python3 (stdlib only — no PyYAML), both on the runner image, so
# it runs in ci.yml's always-on `Proto Checks` job with no toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW_DIR="$ROOT/.github/workflows"
ACTIONS_DIR="$ROOT/.github/actions"
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
  --actions-dir)
    ACTIONS_DIR="$2"
    shift 2
    ;;
  --actions-dir=*)
    ACTIONS_DIR="${1#--actions-dir=}"
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
check_dirs() {
  local workflow_dir="$1" actions_dir="$2"
  python3 - "$workflow_dir" "$actions_dir" <<'PY'
import glob
import os
import re
import sys

workflow_dir, actions_dir = sys.argv[1], sys.argv[2]

# A `- name:` step is ALWAYS a list item; an un-dashed `name:` at column 0 is
# the workflow's own name; any other un-dashed `name:` is a job's. This mirrors
# the one nesting shape every file in this repo actually uses (jobs are mapping
# keys, never list items), so it needs no full YAML parse to classify.
NAME_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<dash>-\s+)?name:(?P<rest>.*)$")
# Any `key: |`/`key: >` (optionally `+`/`-` chomped) opens a block scalar whose
# body is everything more-indented than THIS line, however deep the key sits
# (job-level `description: |`, a step's `run: |`, …).
BLOCK_START_RE = re.compile(r"^[ \t]*(?:-\s+)?[A-Za-z0-9_.-]+:\s*[|>][+-]?\s*$")
HASH_RE = re.compile(r"[ \t]#")

files = sorted(glob.glob(os.path.join(workflow_dir, "*.yml"))) + sorted(
    glob.glob(os.path.join(actions_dir, "*", "action.yml"))
)

errors = []
findings = []
files_scanned = 0
name_lines_scanned = 0

for path in files:
    files_scanned += 1
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:  # noqa: BLE001 - report any read failure verbatim
        errors.append(f"{path}: could not read: {exc}")
        continue

    in_block = False
    block_indent = -1
    for lineno, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped:
            continue
        indent = len(line) - len(line.lstrip(" \t"))

        if in_block:
            if indent > block_indent:
                continue
            in_block = False

        if BLOCK_START_RE.match(line):
            in_block = True
            block_indent = indent
            continue

        m = NAME_RE.match(line)
        if not m:
            continue
        name_lines_scanned += 1

        value = m.group("rest").strip()
        if not value:
            continue  # `name:` with the value on a following block-scalar line
        if value[0] in ("'", '"'):
            continue  # already quoted — safe regardless of what it contains

        if m.group("dash"):
            kind = "step"
        elif indent == 0:
            kind = "workflow"
        else:
            kind = "job"

        if value.startswith("#") or HASH_RE.search(value):
            findings.append((path, lineno, kind, stripped))

# ── positive floors ─────────────────────────────────────────────────────────
if files_scanned < 1:
    errors.append(f"scanned zero files under {workflow_dir!r} / {actions_dir!r}")
if name_lines_scanned < 1:
    errors.append("matched zero `name:` mapping lines — the scanner inspected nothing")

for path, lineno, kind, text in findings:
    errors.append(
        f"{path}:{lineno}: {kind} name is an UNQUOTED plain scalar containing ' #' — "
        f"YAML starts a comment there and truncates the visible name. Quote the value. "
        f"Offending line: {text!r}"
    )

if errors:
    for err in errors:
        print(f"::error::{err}")
    print(
        f"FAIL: {len(findings)} finding(s) over {name_lines_scanned} name: scalar(s) "
        f"across {files_scanned} file(s)"
    )
    sys.exit(1)

print(
    f"OK: {name_lines_scanned} name: scalar(s) across {files_scanned} file(s) scanned; "
    "zero unquoted ' #' occurrences"
)
PY
}

# ── self-test ───────────────────────────────────────────────────────────────
# A guard nobody has watched fail is not a guard: this drives one fabricated
# offender through and confirms a quoted sibling with the SAME hash content is
# left alone, plus the report-safety and block-scalar edge cases.
self_test() {
  local tmp pass=0 fail=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  case_run() {
    local name="$1" expect="$2" workflow_dir="$3" actions_dir="$4"
    local out rc
    out="$(check_dirs "$workflow_dir" "$actions_dir" 2>&1)"
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

  mkdir -p "$tmp/empty-actions"

  # 1. Baseline: a quoted step name that CONTAINS a hash-space is left alone,
  # alongside a clean job and workflow name. Accepted.
  mkdir -p "$tmp/clean/workflows"
  cat >"$tmp/clean/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
jobs:
  proto:
    name: Proto Checks
    runs-on: ubuntu-latest
    steps:
      - name: "Quoted step naming an issue (#1 / #2)"
        run: echo hi
YAML
  case_run "quoted hash-space name accepted" 0 "$tmp/clean/workflows" "$tmp/empty-actions"

  # 2. NEGATIVE CONTROL — the fabricated offender: an UNQUOTED step name with a
  # hash preceded by a space, the exact shape that truncates in the Actions UI.
  mkdir -p "$tmp/offender/workflows"
  cat >"$tmp/offender/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
jobs:
  proto:
    name: Proto Checks
    runs-on: ubuntu-latest
    steps:
      - name: Fabricated offender (#63 / #511)
        run: echo hi
YAML
  case_run "unquoted hash-space step name rejected" 1 "$tmp/offender/workflows" "$tmp/empty-actions"

  # 3. Same file, fixed the ONLY way this guard asks for: quote the value,
  # change nothing else. Must go green.
  mkdir -p "$tmp/fixed/workflows"
  cat >"$tmp/fixed/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
jobs:
  proto:
    name: Proto Checks
    runs-on: ubuntu-latest
    steps:
      - name: "Fabricated offender (#63 / #511)"
        run: echo hi
YAML
  case_run "quoting the offender in place fixes it" 0 "$tmp/fixed/workflows" "$tmp/empty-actions"

  # 4. An unquoted JOB name with a hash-space is tagged `job`, not `step` — the
  # dangerous case this guard exists to catch loud (a required context could
  # move). Still just a rejection here; tools/ci/check_pr_job_fanout.sh is what
  # asserts the required-context set itself.
  mkdir -p "$tmp/job-offender/workflows"
  cat >"$tmp/job-offender/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
jobs:
  proto:
    name: Proto Checks issue #1
    runs-on: ubuntu-latest
    steps:
      - name: "Fine step"
        run: echo hi
YAML
  out="$(check_dirs "$tmp/job-offender/workflows" "$tmp/empty-actions" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q ": job name is an UNQUOTED"; then
    pass=$((pass + 1))
    echo "PASS  unquoted job name rejected and tagged 'job'"
  else
    fail=$((fail + 1))
    echo "FAIL  unquoted job name rejected and tagged 'job' (exit $rc)"
    printf '  %s\n' "$out"
  fi

  # 5. An unquoted WORKFLOW-level name with a hash-space is tagged `workflow`.
  mkdir -p "$tmp/workflow-offender/workflows"
  cat >"$tmp/workflow-offender/workflows/ci.yml" <<'YAML'
name: CI issue #1
on:
  pull_request:
jobs:
  proto:
    name: Proto Checks
    runs-on: ubuntu-latest
    steps:
      - name: "Fine step"
        run: echo hi
YAML
  out="$(check_dirs "$tmp/workflow-offender/workflows" "$tmp/empty-actions" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q ": workflow name is an UNQUOTED"; then
    pass=$((pass + 1))
    echo "PASS  unquoted workflow name rejected and tagged 'workflow'"
  else
    fail=$((fail + 1))
    echo "FAIL  unquoted workflow name rejected and tagged 'workflow' (exit $rc)"
    printf '  %s\n' "$out"
  fi

  # 6. An immediate `name: #comment` (the value IS the comment — an
  # accidentally empty name) is flagged even with nothing before the `#`.
  mkdir -p "$tmp/empty-name/workflows"
  cat >"$tmp/empty-name/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
jobs:
  proto:
    name: Proto Checks
    runs-on: ubuntu-latest
    steps:
      - name: #oops, forgot the text
        run: echo hi
YAML
  case_run "name: immediately followed by # rejected" 1 "$tmp/empty-name/workflows" "$tmp/empty-actions"

  # 7. Block-scalar false-positive avoidance: a `run: |` body containing the
  # LITERAL text of an unquoted offending step name must NOT be flagged — it is
  # shell content, not a YAML mapping key. Proves the block-scalar tracking
  # actually works rather than just "no false positives in the fixtures above
  # because none of them happen to have a run: | block".
  mkdir -p "$tmp/block-scalar/workflows"
  cat >"$tmp/block-scalar/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
jobs:
  proto:
    name: Proto Checks
    runs-on: ubuntu-latest
    steps:
      - name: "Print a fake workflow line"
        run: |
          echo "      - name: Looks like an offender (#63 / #511)"
          echo done
YAML
  case_run "name-shaped text inside a run: | body is not scanned" 0 "$tmp/block-scalar/workflows" "$tmp/empty-actions"

  # 8. Positive floor — an empty directory pair must be a hard error, never a
  # silent pass ("0 findings" must not read as "0 files, all clean").
  mkdir -p "$tmp/nothing/workflows-missing-on-purpose" # never populated
  case_run "empty workflow dir is a hard error, not a silent pass" 1 "$tmp/nothing/nope" "$tmp/empty-actions"

  # 9. action.yml files are scanned too (the OTHER glob this guard covers).
  mkdir -p "$tmp/action-offender/actions/some-action"
  mkdir -p "$tmp/action-offender/workflows"
  cat >"$tmp/action-offender/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
jobs:
  proto:
    name: Proto Checks
    runs-on: ubuntu-latest
    steps:
      - name: "Fine step"
        run: echo hi
YAML
  cat >"$tmp/action-offender/actions/some-action/action.yml" <<'YAML'
name: A composite action issue #1
description: does a thing
runs:
  using: composite
  steps:
    - run: echo hi
YAML
  case_run "an offender in an action.yml is caught too" 1 "$tmp/action-offender/workflows" "$tmp/action-offender/actions"

  local total=$((pass + fail))
  if [ "$total" -lt 9 ]; then
    echo "::error::self-test ran $total case(s), expected 9"
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

check_dirs "$WORKFLOW_DIR" "$ACTIONS_DIR"
exit $?
