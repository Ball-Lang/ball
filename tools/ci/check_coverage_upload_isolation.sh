#!/usr/bin/env bash
# Wiring guard for coverage.yml: the Codecov upload must not be able to red a
# green coverage measurement (#638).
#
# WHAT WENT WRONG. coverage.yml run 34746079045 on main (@97927362) is red with
# every coverage number passing. Its `C++ coverage` job ran 13 steps; steps 11
# (`C++ line coverage floor`, 93.9% >= 91%) and 12 (`C++ per-target coverage
# floors`, 94.6/99.0/94.3 >= 92/97/92) both succeeded, and step 13, `Upload C++
# coverage to Codecov`, failed with
#
#   Unhandled error: Error: Error message: Failed to get ID Token.
#   Request timeout: /10//idtoken/…?api-version=2.0&audience=https%3A%2F%2Fcodecov.io
#
# — a GitHub OIDC token-fetch timeout inside codecov/codecov-action. Transport,
# not measurement. The job's exit code cannot tell the two apart, so main's
# coverage history records a red on a commit whose coverage was fine, and the
# "N consecutive green runs" that #63's ratchet and #599's cache ceiling are
# derived from have to be hand-audited job by job.
#
# WHY `fail_ci_if_error: false` DID NOT SAVE IT. Read action.yml at the pinned
# SHA (codecov/codecov-action@fb8b3582c8e4def4969c97caa2f19720cb33a72f, v7.0.0 —
# https://github.com/codecov/codecov-action/blob/v7.0.0/action.yml): v7 is a
# COMPOSITE action, and `fail_ci_if_error` is wired to exactly one of its steps,
# as `CC_FAIL_ON_ERROR` on the final `Upload coverage to Codecov` step that runs
# dist/codecov.sh. The OIDC token is fetched FOUR steps earlier, by the 5th of
# that file's 9 composite steps, `Get OIDC token`
# (actions/github-script -> core.getIDToken(audience)), which carries no `if:`,
# no `continue-on-error`, no retry, and is not influenced by
# `fail_ci_if_error` at all. v7.0.0 exposes no retry input of any kind (its 49
# inputs run base_sha … working-directory; none matches retry/attempt/backoff).
# So the ONLY
# way to bound that flake is to fetch the token ourselves, with a retry, and
# hand it to the action through its documented `token` input — action.yml
# funnels `use_oidc`'s token and the `token` input into the same `CC_TOKEN`
# variable, so the uploader cannot tell the difference.
#
# WHAT THIS GUARD ASSERTS. Parsing coverage.yml (yaml.safe_load — the `if:`
# conditions and `run:` bodies are folded/block scalars that only a parser
# reads correctly):
#
#   1. transport and verdict are DIFFERENT JOBS — no codecov/codecov-action step
#      may share a job with a coverage floor step or with the lcov artifact
#      upload that feeds it;
#   2. the upload job `needs:` the measurement jobs and each codecov step names
#      a flag that some measurement job actually produced an artifact for (and
#      vice versa) — so a newly added stack cannot be measured and silently
#      never uploaded;
#   3. nothing after a floor step in a measurement job can mask the verdict: the
#      only thing allowed to follow one is another floor step, or the lcov
#      artifact upload gated on `!cancelled()` (the Dart job measures and gates
#      in one `coverage_dart.dart --floor` invocation, so its artifact can only
#      be taken after the gate — and it must still be taken when the gate FAILS,
#      or Codecov would have a hole exactly where the drop is);
#   4. the upload is LOUD: `fail_ci_if_error: true`, no `continue-on-error`
#      anywhere in the file, no `|| true` in the upload job — a persistent
#      upload failure must still red the upload job, distinctly from a coverage
#      drop, and never be swallowed;
#   5. the upload job fetches the OIDC token itself, with a bounded retry, and
#      the codecov steps do NOT set `use_oidc: true` (which would re-enter the
#      action's own un-retried `Get OIDC token` step — the exact failure above);
#   6. each measurement job's lcov artifact upload sets `if-no-files-found:
#      error`, and each codecov step sets `disable_search: true` with an
#      explicit `files:` — five stacks' lcov now land in ONE workspace, so a
#      searching uploader would tag every stack's report with every flag.
#
# POSITIVE FLOOR: a guard that asserted nothing must not report success. The
# checker refuses a coverage.yml with fewer than 4 floor steps, 4 measurement
# jobs, 4 lcov artifacts or 4 codecov steps, and the self-test refuses to pass
# on fewer than 16 cases.
#
# Usage:
#   bash tools/ci/check_coverage_upload_isolation.sh               # gate the repo
#   bash tools/ci/check_coverage_upload_isolation.sh --file FILE   # a synthetic workflow
#   bash tools/ci/check_coverage_upload_isolation.sh --self-test   # drive the cases
#
# Exits 0 when the wiring holds; 1 otherwise, naming every broken expectation.
# Needs bash + python3 + PyYAML (the runner image ships all three), so it runs
# in ci.yml's always-on `Proto Checks` job with no toolchain — next to
# tools/ci/check_ci_regen_wiring.sh, whose shape this mirrors.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/coverage.yml"
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
  --file)
    WORKFLOW="$2"
    shift 2
    ;;
  --file=*)
    WORKFLOW="${1#--file=}"
    shift
    ;;
  --self-test)
    SELF_TEST=1
    shift
    ;;
  -h | --help)
    sed -n '2,80p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

# ── the check itself ────────────────────────────────────────────────────────
check_file() {
  local file="$1"
  python3 - "$file" <<'PY'
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the runner image ships PyYAML
    print("::error::PyYAML is required by tools/ci/check_coverage_upload_isolation.sh")
    sys.exit(1)

path = sys.argv[1]

# A "floor step" is the verdict: it compares a measured percentage against a
# committed number and exits nonzero below it. Matched on the step NAME, which
# is the one part of such a step that is stable across stacks (the Dart one
# shells out to coverage_dart.dart, the C++ ones to lcov + build-cov-floor.sh,
# the Rust one to `cargo llvm-cov report --fail-under-lines`).
FLOOR_RE = re.compile(r"coverage\s+(floors?|ratchet)", re.I)
CODECOV = "codecov/codecov-action@"
UPLOAD_ARTIFACT = "actions/upload-artifact@"
DOWNLOAD_ARTIFACT = "actions/download-artifact@"
# The artifact each measurement job hands to the upload job. The suffix is the
# Codecov flag, which is what ties the two halves together.
ART_PREFIX = "coverage-lcov-"

# Positive floors — see the header. Lower them only when a stack is genuinely
# retired, and say so in the commit.
MIN_FLOOR_STEPS = 4
MIN_MEASUREMENT_JOBS = 4
MIN_ARTIFACTS = 4
MIN_CODECOV_STEPS = 4
# A "bounded retry" is at least two attempts and at most ten: one attempt is not
# a retry, and an unbounded loop turns a Codecov outage into a 6-hour job.
RETRY_MIN_ATTEMPTS = 2
RETRY_MAX_ATTEMPTS = 10

passed = 0
failures = []


def ok(msg):
    global passed
    passed += 1
    print(f"PASS {msg}")


def bad(msg):
    failures.append(msg)
    print(f"FAIL {msg}")


def die(msg):
    print(f"::error::{msg}")
    print("Results: 0 passed, 1 failed, 1 total")
    sys.exit(1)


try:
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except FileNotFoundError:
    die(f"workflow not found: {path}")
except yaml.YAMLError as exc:
    die(f"{path} is not parseable YAML: {exc}")

if not isinstance(doc, dict):
    die(f"{path} does not parse to a mapping")

jobs = doc.get("jobs")
if not isinstance(jobs, dict):
    die(f"{path} has no `jobs:` mapping")


def steps_of(job):
    steps = job.get("steps")
    return steps if isinstance(steps, list) else []


def uses_of(step):
    return str(step.get("uses", "") or "").strip()


def name_of(step):
    return str(step.get("name", "") or "")


def run_of(step):
    return str(step.get("run", "") or "")


def with_of(step):
    w = step.get("with")
    return w if isinstance(w, dict) else {}


def is_floor(step):
    return bool(FLOOR_RE.search(name_of(step)))


def is_codecov(step):
    return uses_of(step).startswith(CODECOV)


def artifact_flag(step):
    """The Codecov flag an `actions/upload-artifact` step carries, or None."""
    if not uses_of(step).startswith(UPLOAD_ARTIFACT):
        return None
    name = str(with_of(step).get("name", "") or "")
    return name[len(ART_PREFIX):] if name.startswith(ART_PREFIX) else None


def truthy(value):
    return str(value).strip().lower() == "true"


# ── classify ────────────────────────────────────────────────────────────────
floor_steps = []        # (job_name, step)
measurement_jobs = {}   # job name -> job (has >= 1 floor step)
artifact_jobs = {}      # job name -> {flag: step}
codecov_jobs = {}       # job name -> job (has >= 1 codecov step)
codecov_steps = []      # (job_name, step)

for job_name, job in jobs.items():
    if not isinstance(job, dict):
        continue
    for step in steps_of(job):
        if not isinstance(step, dict):
            continue
        if is_floor(step):
            floor_steps.append((job_name, step))
            measurement_jobs[job_name] = job
        flag = artifact_flag(step)
        if flag:
            artifact_jobs.setdefault(job_name, {})[flag] = step
        if is_codecov(step):
            codecov_steps.append((job_name, step))
            codecov_jobs[job_name] = job

artifact_flags = {f for m in artifact_jobs.values() for f in m}

if len(floor_steps) < MIN_FLOOR_STEPS:
    die(
        f"{path} has {len(floor_steps)} coverage floor step(s), fewer than the "
        f"{MIN_FLOOR_STEPS} this guard expects — it refuses to certify a file it "
        "found nothing to check."
    )
if len(measurement_jobs) < MIN_MEASUREMENT_JOBS:
    die(
        f"{path} has {len(measurement_jobs)} job(s) carrying a coverage floor, "
        f"fewer than the {MIN_MEASUREMENT_JOBS} this guard expects."
    )
if len(codecov_steps) < MIN_CODECOV_STEPS:
    die(
        f"{path} has {len(codecov_steps)} codecov-action step(s), fewer than the "
        f"{MIN_CODECOV_STEPS} this guard expects."
    )

ok(
    f"found {len(floor_steps)} floor step(s) in {len(measurement_jobs)} measurement "
    f"job(s), {len(artifact_flags)} lcov artifact(s) and {len(codecov_steps)} "
    "codecov step(s)"
)

# The handoff itself. This is not a "found nothing to check" floor — it is the
# assertion that the measurement jobs publish their lcov as artifacts at all,
# which is what lets the upload live in a job of its own (#638). Reported as a
# failing expectation, not a refusal, so the rest of the diagnosis still prints.
if len(artifact_flags) < MIN_ARTIFACTS:
    bad(
        f"{path} publishes {len(artifact_flags)} `{ART_PREFIX}*` lcov artifact(s), "
        f"fewer than the {MIN_ARTIFACTS} this guard expects — the measurement jobs "
        "must hand their lcov to a separate upload job, or the Codecov upload has "
        "to stay inside them (#638)."
    )
else:
    ok(f"{len(artifact_flags)} measurement job(s) publish their lcov as an artifact")

# ── 1. transport and verdict are different jobs ─────────────────────────────
for job_name, step in codecov_steps:
    if job_name in measurement_jobs:
        bad(
            f"job `{job_name}` runs BOTH a coverage floor and the codecov upload "
            f"(step `{name_of(step)}`) — a transport failure there reds the "
            "measurement. Move the upload into its own job that `needs:` this one "
            "(#638, run 34746079045)."
        )
    elif job_name in artifact_jobs:
        bad(
            f"job `{job_name}` both produces an lcov artifact and uploads to "
            f"Codecov (step `{name_of(step)}`) — measurement and transport must be "
            "separate jobs (#638)."
        )
    else:
        ok(f"`{job_name}` / `{name_of(step)}` uploads from a transport-only job")

# ── 2. the upload job depends on the measurement jobs, flag-for-flag ────────
for job_name in sorted(codecov_jobs):
    needs = codecov_jobs[job_name].get("needs")
    if isinstance(needs, str):
        needs = [needs]
    needs = [str(n) for n in needs] if isinstance(needs, list) else []
    covered = sorted(set(needs) & set(measurement_jobs) | set(needs) & set(artifact_jobs))
    if not covered:
        bad(
            f"job `{job_name}` uploads to Codecov but `needs:` none of the "
            "measurement jobs — it would race them and upload nothing (#638)."
        )
    else:
        ok(f"`{job_name}` needs the measurement job(s): {', '.join(covered)}")

uploaded_flags = set()
for job_name, step in codecov_steps:
    flags = str(with_of(step).get("flags", "") or "").strip()
    if not flags:
        bad(f"`{job_name}` / `{name_of(step)}` sets no `flags:` — Codecov cannot separate the stacks.")
        continue
    uploaded_flags.update(f.strip() for f in flags.split(",") if f.strip())

if uploaded_flags != artifact_flags:
    missing = sorted(artifact_flags - uploaded_flags)
    extra = sorted(uploaded_flags - artifact_flags)
    bad(
        "the measured stacks and the uploaded flags disagree — measured but never "
        f"uploaded: {missing or 'none'}; uploaded but never measured: "
        f"{extra or 'none'}. A stack added to one half and not the other is "
        "invisible on both."
    )
else:
    ok(f"every measured stack is uploaded under its own flag: {', '.join(sorted(uploaded_flags))}")

# ── 3. nothing after a floor step may mask the verdict ──────────────────────
for job_name, job in measurement_jobs.items():
    steps = [s for s in steps_of(job) if isinstance(s, dict)]
    last_floor = max(i for i, s in enumerate(steps) if is_floor(s))
    trailing_ok = True
    for step in steps[last_floor + 1:]:
        if is_floor(step):
            continue
        if artifact_flag(step):
            cond = str(step.get("if", "") or "")
            if "!cancelled()" not in cond.replace(" ", ""):
                trailing_ok = False
                bad(
                    f"`{job_name}` / `{name_of(step)}` takes the lcov artifact AFTER "
                    "the floor step without `if: ${{ !cancelled() }}` — a coverage "
                    "DROP would then publish nothing to Codecov, hiding the very "
                    "run that needs recording (#638)."
                )
            continue
        trailing_ok = False
        bad(
            f"`{job_name}` runs `{name_of(step) or run_of(step)[:40]}` after its last "
            "coverage floor step — only another floor step, or the "
            "`!cancelled()`-gated lcov artifact upload, may follow one, or the "
            "job's conclusion stops being the measurement (#638)."
        )
    if trailing_ok:
        ok(f"`{job_name}`'s conclusion is its floor verdict (nothing masking follows it)")

# ── 4. loud, never swallowed ────────────────────────────────────────────────
coe_clean = True
for job_name, job in jobs.items():
    if not isinstance(job, dict):
        continue
    if "continue-on-error" in job:
        coe_clean = False
        bad(f"job `{job_name}` declares `continue-on-error` — a gate that cannot fail is not a gate.")
    for step in steps_of(job):
        if isinstance(step, dict) and "continue-on-error" in step:
            coe_clean = False
            bad(
                f"`{job_name}` / `{name_of(step)}` declares `continue-on-error` — "
                "it would swallow the step's exit code."
            )
if coe_clean:
    ok("no `continue-on-error` anywhere in the workflow")

for job_name in sorted(codecov_jobs):
    # Floor steps are excluded on purpose: the C++ per-target gate legitimately
    # writes `grep -c '^OK ' … || true` (grep exits 1 on zero matches, and the
    # count is then compared against 3). This rule is about the TRANSPORT half —
    # nothing in the upload path may swallow its own exit code.
    offenders = [
        name_of(s) or run_of(s)[:40]
        for s in steps_of(codecov_jobs[job_name])
        if isinstance(s, dict) and not is_floor(s) and "|| true" in run_of(s)
    ]
    if offenders:
        bad(
            f"job `{job_name}` guards {offenders} with `|| true` — a persistent "
            "upload failure must stay RED and distinct from a coverage drop (#638)."
        )
    else:
        ok(f"`{job_name}` silences nothing with `|| true`")

for job_name, step in codecov_steps:
    w = with_of(step)
    if not truthy(w.get("fail_ci_if_error")):
        bad(
            f"`{job_name}` / `{name_of(step)}` does not set `fail_ci_if_error: true`. "
            "Now that the upload cannot touch the floor verdict, a broken upload must "
            "show as its own honest red — best-effort was the right setting only while "
            "this step lived inside the measurement job (#638)."
        )
    else:
        ok(f"`{job_name}` / `{name_of(step)}` fails loud on a persistent upload error")

# Floor steps must not be `always()`/`failure()`-masked: such a condition makes
# the step run in states where its verdict is meaningless, or (with the job's
# other steps) lets a later green step decide the conclusion.
floors_unmasked = True
for job_name, step in floor_steps:
    cond = str(step.get("if", "") or "")
    naked = cond.replace(" ", "")
    if "always()" in naked or "failure()" in naked or "cancelled()" in naked:
        floors_unmasked = False
        bad(
            f"`{job_name}` / `{name_of(step)}` carries `if: {cond}` — a coverage "
            "floor must run unconditionally, so the job's conclusion is its verdict."
        )
if floors_unmasked:
    ok("no coverage floor step is masked by an always()/failure()/cancelled() condition")

# ── 5. the OIDC token is fetched here, with a bounded retry ─────────────────
for job_name in sorted(codecov_jobs):
    steps = [s for s in steps_of(codecov_jobs[job_name]) if isinstance(s, dict)]
    first_cc = min(i for i, s in enumerate(steps) if is_codecov(s))
    retry_ok = False
    for step in steps[:first_cc]:
        run = run_of(step)
        if "ACTIONS_ID_TOKEN_REQUEST_URL" not in run:
            continue
        m = re.search(r"(?im)^\s*attempts\s*=\s*([0-9]+)", run)
        if not m:
            bad(
                f"`{job_name}` / `{name_of(step)}` fetches the OIDC token but declares "
                "no `attempts=<n>` bound — the timeout that motivated #638 needs a "
                "RETRY, and an unbounded one is its own outage."
            )
            continue
        n = int(m.group(1))
        if not (RETRY_MIN_ATTEMPTS <= n <= RETRY_MAX_ATTEMPTS):
            bad(
                f"`{job_name}` / `{name_of(step)}` retries {n} time(s); expected "
                f"{RETRY_MIN_ATTEMPTS}..{RETRY_MAX_ATTEMPTS}."
            )
            continue
        if "::error::" not in run:
            bad(
                f"`{job_name}` / `{name_of(step)}` exhausts its retries without an "
                "`::error::` annotation — the run must say which half broke."
            )
            continue
        retry_ok = True
        ok(f"`{job_name}` / `{name_of(step)}` fetches the OIDC token with {n} bounded attempts")
    if not retry_ok and not any(job_name in f and "OIDC token" in f for f in failures):
        bad(
            f"job `{job_name}` uploads to Codecov with no bounded-retry OIDC token "
            "fetch before it. codecov-action v7.0.0 has NO retry input and its own "
            "`Get OIDC token` step (actions/github-script -> core.getIDToken) is "
            "un-retried and unaffected by `fail_ci_if_error` — that single request "
            "timing out is what reddened run 34746079045 (#638)."
        )

for job_name, step in codecov_steps:
    if truthy(with_of(step).get("use_oidc")):
        bad(
            f"`{job_name}` / `{name_of(step)}` sets `use_oidc: true`, which re-enters "
            "codecov-action's own un-retried `Get OIDC token` step — the exact "
            "request that timed out in #638. Pass the retried token through the "
            "action's `token` input instead."
        )
    elif not str(with_of(step).get("token", "") or "").strip():
        bad(
            f"`{job_name}` / `{name_of(step)}` passes no `token:` — with `use_oidc` "
            "off the upload would be tokenless and rejected."
        )
    else:
        ok(f"`{job_name}` / `{name_of(step)}` uses the retried token, not the action's own OIDC step")

# ── 6. the artifact and the upload cannot silently carry nothing ────────────
for job_name, by_flag in sorted(artifact_jobs.items()):
    for flag, step in sorted(by_flag.items()):
        if str(with_of(step).get("if-no-files-found", "") or "").strip() != "error":
            bad(
                f"`{job_name}` / `{name_of(step)}` does not set "
                "`if-no-files-found: error` — an empty artifact would make the upload "
                "job green while publishing nothing for the `" + flag + "` flag."
            )
        else:
            ok(f"`{job_name}` publishes `{ART_PREFIX}{flag}` with `if-no-files-found: error`")

# The layout the uploader expects must be the layout the downloader produces.
# This is not hypothetical: a single `pattern: coverage-lcov-*` download step
# writes into `path/<artifact-name>/` only when MORE THAN ONE artifact matches
# (download-artifact v8.0.1's `… || artifacts.length === 1 ? resolvedPath :
# path.join(resolvedPath, artifact.name)`), so on a cpp-only pull_request the
# file landed one directory above every `files:` path and the upload job went red
# having published nothing. Assert every `files:` entry sits under a directory
# some download step in the same job actually writes to.
for job_name in sorted(codecov_jobs):
    dests = []
    for step in steps_of(codecov_jobs[job_name]):
        if isinstance(step, dict) and uses_of(step).startswith(DOWNLOAD_ARTIFACT):
            dest = str(with_of(step).get("path", "") or "").strip().strip("/")
            if dest:
                dests.append(dest)
    if not dests:
        bad(
            f"job `{job_name}` uploads to Codecov but no `actions/download-artifact` "
            "step gives the lcov an explicit destination — it would upload whatever "
            "happened to be in the workspace."
        )
        continue
    for step in steps_of(codecov_jobs[job_name]):
        if not (isinstance(step, dict) and is_codecov(step)):
            continue
        for entry in str(with_of(step).get("files", "") or "").split(","):
            entry = entry.strip()
            if not entry:
                continue
            norm = entry[2:] if entry.startswith("./") else entry
            if not any(norm == d or norm.startswith(d + "/") for d in dests):
                bad(
                    f"`{job_name}` / `{name_of(step)}` uploads `{entry}`, which is under "
                    f"none of this job's download destinations ({dests}) — the uploader "
                    "and the downloader disagree about where the lcov is."
                )
            else:
                ok(f"`{job_name}` / `{name_of(step)}` reads `{entry}` from a downloaded destination")

for job_name, step in codecov_steps:
    w = with_of(step)
    if not truthy(w.get("disable_search")):
        bad(
            f"`{job_name}` / `{name_of(step)}` does not set `disable_search: true`. "
            "All five stacks' lcov now land in ONE workspace, so a searching uploader "
            "would tag every stack's report with this step's flag."
        )
    elif not str(w.get("files", "") or "").strip():
        bad(f"`{job_name}` / `{name_of(step)}` sets `disable_search: true` but no `files:` — it would upload nothing.")
    else:
        ok(f"`{job_name}` / `{name_of(step)}` uploads an explicit file list with search disabled")

total = passed + len(failures)
print(f"Results: {passed} passed, {len(failures)} failed, {total} total")
if failures:
    print(f"::error::coverage.yml upload-isolation wiring is broken ({len(failures)} failing expectation(s)) — see the FAIL lines above (#638).")
    sys.exit(1)
sys.exit(0)
PY
}

# ── synthetic fixtures ──────────────────────────────────────────────────────
# A miniature but structurally complete coverage.yml: five measurement jobs
# (one of which, like the real `typescript` job, has no floor of its own) plus
# one transport-only upload job. `mutate` names the single thing to break, so
# every negative control differs from the passing fixture in exactly one way.
CC_PIN='codecov/codecov-action@fb8b3582c8e4def4969c97caa2f19720cb33a72f'
UA_PIN='actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
DA_PIN='actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'

fixture() {
  local mut="${1:-ok}"
  local flag art_name

  cat <<YAML
name: Coverage
on:
  push:
    branches: [main]
permissions:
  contents: read
  id-token: write
jobs:
YAML

  for flag in dart typescript cpp rust csharp; do
    art_name="coverage-lcov-$flag"
    [ "$mut" = "flag_mismatch" ] && [ "$flag" = "rust" ] && art_name="coverage-lcov-golang"

    printf '  %s:\n    runs-on: ubuntu-latest\n    steps:\n' "$flag"
    printf '      - name: Measure %s coverage\n        run: echo measure\n' "$flag"

    # The Dart shape: measure and gate are one invocation, so the artifact can
    # only be taken after the floor — and must survive a failing floor.
    if [ "$flag" = "dart" ] && [ "$mut" = "artifact_after_floor_guarded" ]; then
      fixture_floor "$flag" "$mut"
      fixture_artifact "$art_name" "$mut" '!cancelled()'
      continue
    fi
    if [ "$flag" = "dart" ] && [ "$mut" = "artifact_after_floor_unguarded" ]; then
      fixture_floor "$flag" "$mut"
      fixture_artifact "$art_name" "$mut" ''
      continue
    fi

    fixture_artifact "$art_name" "$mut" ''
    [ "$flag" = "typescript" ] || fixture_floor "$flag" "$mut"
    # The real cpp job carries TWO floor steps — `C++ line coverage floor` and
    # `C++ per-target coverage floors (compiler/encoder/shared - gated)` — so
    # the fixture carries 5 floor steps across 4 measurement jobs, like the
    # file it stands in for. That is what lets `floor_renamed` below drop
    # exactly ONE floor step rather than the job's only one.
    [ "$flag" = "cpp" ] && fixture_per_target_floor

    if [ "$flag" = "cpp" ] && [ "$mut" = "codecov_in_measurement" ]; then
      fixture_codecov cpp
    fi
    if [ "$flag" = "cpp" ] && [ "$mut" = "step_after_floor" ]; then
      printf '      - name: Announce the result\n        run: echo done\n'
    fi
  done

  printf '  codecov-upload:\n'
  [ "$mut" = "no_needs" ] || printf '    needs: [dart, typescript, cpp, rust, csharp]\n'
  printf '    if: ${{ !cancelled() }}\n    runs-on: ubuntu-latest\n    steps:\n'
  for flag in dart typescript cpp rust csharp; do
    printf '      - uses: %s\n        with:\n          pattern: coverage-lcov-%s\n          merge-multiple: true\n          path: dl/coverage-lcov-%s\n' \
      "$DA_PIN" "$flag" "$flag"
  done
  if [ "$mut" != "no_retry" ]; then
    printf '      - name: Fetch the Codecov OIDC token (bounded retry)\n        id: oidc\n        run: |\n'
    if [ "$mut" = "retry_unbounded" ]; then
      printf '          attempts=1\n'
    else
      printf '          attempts=3\n'
    fi
    printf '          curl "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https%%3A%%2F%%2Fcodecov.io"\n'
    printf '          echo "::error::could not fetch the Codecov OIDC token"\n'
  fi
  [ "$mut" = "or_true" ] && printf '      - name: Note\n        run: echo hi || true\n'
  for flag in dart typescript cpp rust csharp; do
    [ "$mut" = "codecov_in_measurement" ] && [ "$flag" = "cpp" ] && continue
    fixture_codecov "$flag" "$mut"
  done
}

# fixture_artifact <artifact name> <mutation> <if-condition>
fixture_artifact() {
  local name="$1" mut="$2" cond="$3"
  printf '      - name: Upload the %s lcov\n' "$name"
  [ -n "$cond" ] && printf '        if: ${{ %s }}\n' "$cond"
  printf '        uses: %s\n        with:\n          name: %s\n          path: out.lcov\n' "$UA_PIN" "$name"
  [ "$mut" = "no_if_no_files_found" ] || printf '          if-no-files-found: error\n'
}

# fixture_floor <flag> <mutation>
fixture_floor() {
  local flag="$1" mut="$2"
  # `floor_renamed` renames the cpp job's FIRST floor step — the mutation
  # measured against the real file in #700 item 1 (`C++ line coverage floor`
  # -> `C++ line check`). Deliberately not the LAST floor step of its job:
  # rule 3 below catches that one incidentally, as a plain step trailing a
  # floor, and the point of this control is the rename nothing else catches.
  if [ "$mut" = "floor_renamed" ] && [ "$flag" = "cpp" ]; then
    printf '      - name: %s line check\n' "$flag"
    printf '        run: echo floor\n'
    return 0
  fi
  printf '      - name: %s line coverage floor\n' "$flag"
  [ "$mut" = "floor_if_always" ] && [ "$flag" = "cpp" ] && printf '        if: always()\n'
  [ "$mut" = "continue_on_error" ] && [ "$flag" = "cpp" ] && printf '        continue-on-error: true\n'
  printf '        run: echo floor\n'
}

# fixture_per_target_floor — the cpp job's SECOND floor step, so the fixture
# mirrors the real file's 5-floors-across-4-jobs shape.
fixture_per_target_floor() {
  printf '      - name: C++ per-target coverage floors\n'
  printf '        run: echo per-target floor\n'
}

# fixture_codecov <flag> [mutation]
fixture_codecov() {
  local flag="$1" mut="${2:-ok}"
  printf '      - name: Upload %s coverage to Codecov\n        uses: %s\n        with:\n' "$flag" "$CC_PIN"
  if [ "$mut" = "use_oidc" ] && [ "$flag" = "rust" ]; then
    printf '          use_oidc: true\n'
  else
    printf '          token: ${{ steps.oidc.outputs.token }}\n'
  fi
  [ "$mut" = "no_disable_search" ] && [ "$flag" = "rust" ] || printf '          disable_search: true\n'
  if [ "$mut" = "files_outside_download" ] && [ "$flag" = "rust" ]; then
    printf '          files: ./x/%s.lcov\n' "$flag"
  else
    printf '          files: ./dl/coverage-lcov-%s/%s.lcov\n' "$flag" "$flag"
  fi
  printf '          flags: %s\n' "$flag"
  if [ "$mut" = "fail_ci_false" ] && [ "$flag" = "rust" ]; then
    printf '          fail_ci_if_error: false\n'
  else
    printf '          fail_ci_if_error: true\n'
  fi
}

cleanup() { [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"; }

self_test() {
  local pass=0 fail=0
  SCRATCH="$(mktemp -d)"
  trap cleanup EXIT

  # expect <name> <want-exit> <yaml> [needle...]
  expect() {
    local name="$1" want="$2" yaml="$3"
    shift 3
    local f out rc=0 ok=1 needle
    f="$SCRATCH/wf.$RANDOM$RANDOM.yml"
    printf '%s' "$yaml" >"$f"
    out="$(check_file "$f" 2>&1)" || rc=$?
    [ "$rc" -eq "$want" ] || ok=0
    for needle in "$@"; do
      case "$out" in
      *"$needle"*) ;;
      *) ok=0 ;;
      esac
    done
    if [ "$ok" -eq 1 ]; then
      pass=$((pass + 1))
      echo "PASS $name"
    else
      fail=$((fail + 1))
      echo "FAIL $name (exit $rc, wanted $want)"
      echo "$out" | sed 's/^/    | /'
    fi
  }

  expect "a correctly isolated workflow passes" 0 "$(fixture ok)" \
    "Results: " " passed, 0 failed,"

  expect "the Dart shape — artifact after the floor, gated on !cancelled() — passes" 0 \
    "$(fixture artifact_after_floor_guarded)" " passed, 0 failed,"

  expect "an upload inside a measurement job fails" 1 "$(fixture codecov_in_measurement)" \
    "runs BOTH a coverage floor and the codecov upload"

  expect "an upload job with no needs fails" 1 "$(fixture no_needs)" \
    "\`needs:\` none of the measurement jobs"

  expect "a plain step after the floor fails" 1 "$(fixture step_after_floor)" \
    "after its last coverage floor step"

  expect "an ungated artifact after the floor fails" 1 \
    "$(fixture artifact_after_floor_unguarded)" \
    "without \`if: \${{ !cancelled() }}\`"

  expect "a continue-on-error floor fails" 1 "$(fixture continue_on_error)" \
    "declares \`continue-on-error\`"

  expect "an always()-masked floor fails" 1 "$(fixture floor_if_always)" \
    "a coverage floor must run unconditionally"

  expect "a best-effort upload fails" 1 "$(fixture fail_ci_false)" \
    "does not set \`fail_ci_if_error: true\`"

  expect "a searching uploader fails" 1 "$(fixture no_disable_search)" \
    "does not set \`disable_search: true\`"

  expect "use_oidc: true fails (the un-retried step is the bug)" 1 "$(fixture use_oidc)" \
    "re-enters codecov-action's own un-retried"

  expect "a missing OIDC retry fails" 1 "$(fixture no_retry)" \
    "no bounded-retry OIDC token fetch"

  expect "a single-attempt 'retry' fails" 1 "$(fixture retry_unbounded)" \
    "retries 1 time(s); expected 2..10"

  expect "a flag with no measured artifact fails" 1 "$(fixture flag_mismatch)" \
    "the measured stacks and the uploaded flags disagree"

  expect "an artifact without if-no-files-found: error fails" 1 \
    "$(fixture no_if_no_files_found)" "does not set \`if-no-files-found: error\`"

  expect "a || true in the upload job fails" 1 "$(fixture or_true)" \
    "with \`|| true\`"

  expect "an uploaded path outside every download destination fails" 1 \
    "$(fixture files_outside_download)" \
    "under none of this job's download destinations"

  # The ONE-RENAME mutation (#700 item 1). Every post-floor, masking and
  # isolation rule above is scoped to the steps FLOOR_RE found, so renaming a
  # single floor step away from that phrase silently removes it from all of
  # them. With the floor set AT the measured count that is a refusal, not a
  # shrug — and the renamed step here is NOT the last of its job, so no other
  # rule can catch it incidentally.
  expect "renaming exactly ONE floor step out of the matched set is refused" 1 \
    "$(fixture floor_renamed)" \
    "has 4 coverage floor step(s), fewer than the 5"

  local too_few='name: Coverage
on: {push: {branches: [main]}}
jobs:
  cpp:
    runs-on: ubuntu-latest
    steps:
      - name: C++ line coverage floor
        run: echo floor
'
  expect "a file with too few floors is refused" 1 "$too_few" \
    "refuses to certify a file it found nothing to check"

  local no_jobs='name: Coverage
on: {push: {branches: [main]}}
'
  expect "a file with no jobs is refused" 1 "$no_jobs" "has no \`jobs:\` mapping"

  expect "unparseable YAML is refused" 1 'jobs:
  x:
   steps:
  - bad: [
' "::error::"

  echo "Results: $pass passed, $fail failed, $((pass + fail)) total"
  if [ "$pass" -lt 16 ]; then
    echo "::error::self-test executed fewer cases than expected ($pass < 16) — a self-test that ran nothing is not a passing self-test."
    return 1
  fi
  [ "$fail" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

check_file "$WORKFLOW"
exit $?
