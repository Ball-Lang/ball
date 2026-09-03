#!/usr/bin/env bash
# Wiring test for the `dart pub get` retry wrapper (issue #520).
#
# WHY THIS EXISTS: run 33640533368's required `Python` job went red on a single
# transient pub.dev resolver hiccup — `Because ball_workspace depends on melos
# any which doesn't exist (authorization failed) ... Insufficient permissions to
# the resource at the https://pub.dev package repository` — at a commit whose
# diff could not have caused it. The defect is not in any Dart, Ball or target
# code: it is the ABSENCE of a retry around a network command in
# .github/workflows/ci.yml, at (then) 9 separate call sites, 0 of them wrapped.
#
# A unit test on a retry snippet in isolation can never catch that. The repo
# already owns the right shape for this — cpp/test/test_cov_floor_ci_wiring.sh
# (#63/#59) and .github/actions/detect-changed-stacks/test/truth_table.sh
# (#458): sub-second, toolchain-free scripts that assert the WORKFLOW's wiring,
# wired into ci.yml's always-on `proto` job so they gate every PR. That
# technique had only ever been pointed at scripts the repo owns, never at a raw
# external-network command. This test points it there.
#
# Two halves, mirroring test_cov_floor_ci_wiring.sh:
#   (a) STATIC — every `dart pub get` invocation in ci.yml is retry-wrapped
#       (`uses: ./.github/actions/dart-pub-get`, or an inline bounded loop), the
#       invocation-site count clears a positive floor so a rename cannot make
#       the check vacuously pass, and ci.yml actually RUNS this test.
#   (b) FUNCTIONAL — the composite's pub-get.sh really does retry a flaky
#       `dart`, really does give up after `attempts` (bounded, not open-ended),
#       really does surface the last failure's own output, and really does fail
#       loud on a nonsense configuration. Driven through stub `dart` binaries on
#       PATH, so no Dart SDK and no network are needed. Sub-second.
#
# Usage: bash .github/actions/dart-pub-get/test/test_dart_pub_get_wiring.sh
#        bash .../test_dart_pub_get_wiring.sh --file <a copy of ci.yml>
#
# `--file` points ONLY the retry assertions at another copy of the workflow —
# `git show origin/main:.github/workflows/ci.yml > /tmp/ci-main.yml` replays the
# red-before-fix evidence at any HEAD. The "ci.yml runs this test" assertion
# always reads the real in-tree workflow, so an orphaned gate stays visible.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$ACTION_DIR/../../.." && pwd)"
SCRIPT="$ACTION_DIR/pub-get.sh"
ACTION_YML="$ACTION_DIR/action.yml"
REAL_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
WORKFLOW="$REAL_WORKFLOW"

# The path the composite action is referenced by from a workflow.
ACTION_REF="./.github/actions/dart-pub-get"
# The minimum number of `dart pub get` invocation sites ci.yml must have. A
# positive floor: an exit code plus a zero unwrapped-count cannot tell "every
# site is wrapped" from "the sites were renamed and nothing was scanned".
MIN_SITES=9

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
  *)
    echo "::error::unknown argument '$1'"
    exit 1
    ;;
  esac
done

for f in "$SCRIPT" "$ACTION_YML" "$WORKFLOW" "$REAL_WORKFLOW"; do
  [ -f "$f" ] || {
    echo "::error::missing $f"
    exit 1
  }
done

pass=0
fail=0

# assert_cmd <name> <expected exit 0|1> <command...>
assert_cmd() {
  local name="$1" want="$2"
  shift 2
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1))
    echo "PASS  $name"
  else
    fail=$((fail + 1))
    echo "FAIL  $name: expected exit $want, got $rc"
    printf '  %s\n' "$out"
  fi
}

# ─────────────────────────────────────────────────────────────────────
# (a) The workflow wiring.
# ─────────────────────────────────────────────────────────────────────

# Two kinds of `dart pub get` occurrence in ci.yml are NOT invocations and must
# never be counted — both were reproduced as live false positives while writing
# this test:
#   * a comment ("...after a single workspace `dart pub get`.", ci.yml:356 at
#     the time of writing) — a comment can never be retry-wrapped, so a naive
#     substring scan both miscounts today AND false-fails forever after the fix;
#   * a step's `name:` value (this very test's step is called "dart pub get
#     retry wiring test") — a display string, not a command.
# Everything else that mentions the command is a command. The scan runs over the
# RAW file so reported line numbers are real ci.yml line numbers.

# bare_site_lines — "lineno<TAB>text" for every line that actually RUNS
# `dart pub get`.
bare_site_lines() {
  awk '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^[[:space:]]*#/) continue
        if (line[i] ~ /^[[:space:]]*-?[[:space:]]*name:/) continue
        if (line[i] !~ /dart[[:space:]]+pub[[:space:]]+get/) continue
        print i "\t" line[i]
      }
    }
  ' "$WORKFLOW"
}

# unwrapped_site_lines — bare `dart pub get` lines that are NOT inside an inline
# bounded retry loop. An inline loop is still a legitimate wrapping (the shape
# publish-pypi.yml already uses), so it is accepted; what must not survive is a
# single-shot invocation. Scoped to the enclosing step: the scan walks back from
# each occurrence to the nearest step boundary.
unwrapped_site_lines() {
  awk '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^[[:space:]]*#/) continue
        if (line[i] ~ /^[[:space:]]*-?[[:space:]]*name:/) continue
        if (line[i] !~ /dart[[:space:]]+pub[[:space:]]+get/) continue
        wrapped = 0
        for (j = i; j >= 1; j--) {
          if (j < i && line[j] ~ /^[[:space:]]*-[[:space:]]+(name|uses|id|shell|run|with):/) break
          if (line[j] ~ /(^|[[:space:]])(for|while|until)[[:space:]]/) { wrapped = 1; break }
        }
        if (!wrapped) print i "\t" line[i]
      }
    }
  ' "$WORKFLOW"
}

count_lines() { grep -c '' || true; }

# wrapped_sites — steps delegating to the retry composite action.
wrapped_sites() {
  grep -cE "uses:[[:space:]]*${ACTION_REF//./\\.}([[:space:]]|$)" "$WORKFLOW" || true
}

sites_at_least_floor() {
  local bare wrapped total
  bare="$(bare_site_lines | count_lines)"
  wrapped="$(wrapped_sites)"
  total=$((bare + wrapped))
  echo "dart pub get invocation sites: $total ($bare bare, $wrapped via $ACTION_REF; floor $MIN_SITES)"
  [ "$total" -ge "$MIN_SITES" ]
}

every_site_wrapped() {
  local offenders count
  offenders="$(unwrapped_site_lines)"
  count="$(printf '%s' "$offenders" | count_lines)"
  echo "unwrapped (single-shot) dart pub get sites: $count"
  if [ "$count" -ne 0 ]; then
    echo "the offending $WORKFLOW lines:"
    printf '%s\n' "$offenders" | sed 's/^/  /'
  fi
  [ "$count" -eq 0 ]
}

# The gate must actually reach a job, or it is a proven-correct exit code that
# never runs — the exact failure mode test_cov_floor_ci_wiring.sh was written
# for. Always read the real in-tree ci.yml, never the `--file` copy.
ci_runs_this_test() {
  grep -qE "bash[[:space:]]+[^[:space:]]*test_dart_pub_get_wiring\.sh" "$REAL_WORKFLOW"
}

# A `continue-on-error:` on a pub-get step would reduce the retry to decoration.
no_continue_on_error_near_action() {
  ! awk -v ref="$ACTION_REF" '
    index($0, "uses: " ref) { inblock = 1; next }
    inblock && /^[[:space:]]*-[[:space:]]/ { inblock = 0 }
    inblock && /^[[:space:]]*continue-on-error:/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$WORKFLOW"
}

assert_cmd "ci.yml has at least $MIN_SITES dart pub get invocation sites" 0 \
  sites_at_least_floor
assert_cmd "every dart pub get invocation site is retry-wrapped" 0 \
  every_site_wrapped
assert_cmd "no dart-pub-get step carries continue-on-error" 0 \
  no_continue_on_error_near_action
assert_cmd "ci.yml runs this wiring test" 0 \
  ci_runs_this_test

action_yml_runs_the_script() {
  grep -qE 'pub-get\.sh' "$ACTION_YML"
}
assert_cmd "action.yml runs pub-get.sh" 0 action_yml_runs_the_script

# ─────────────────────────────────────────────────────────────────────
# (b) The retry behaviour itself, through stub `dart` binaries on PATH.
#     `sleep-seconds: 0` throughout, so the whole half stays sub-second.
# ─────────────────────────────────────────────────────────────────────

STUB_ROOT="$(mktemp -d)"
trap 'rm -rf "$STUB_ROOT"' EXIT

# run_with_stub <fail-count> <attempts> [working-directory]
# Installs a `dart` stub that fails its first <fail-count> invocations (writing
# a recognisable line to stderr, as the real resolver does) and succeeds after.
# Records every invocation so boundedness can be asserted. Echoes the combined
# output; returns pub-get.sh's exit status.
run_with_stub() {
  local failures="$1" attempts="$2" workdir="${3:-.}"
  local tmp
  tmp="$(mktemp -d "$STUB_ROOT/case.XXXXXX")"
  mkdir -p "$tmp/bin" "$tmp/work/nested"

  cat >"$tmp/bin/dart" <<STUB
#!/usr/bin/env bash
echo "\$PWD" >>"$tmp/calls"
n=\$(wc -l <"$tmp/calls")
if [ "\$n" -le $failures ]; then
  echo "Insufficient permissions to the resource at the https://pub.dev package repository." >&2
  exit 69
fi
echo "Got dependencies!"
STUB
  chmod +x "$tmp/bin/dart"
  : >"$tmp/calls"

  local rc
  (
    cd "$tmp/work" &&
      PATH="$tmp/bin:$PATH" \
        INPUT_ATTEMPTS="$attempts" \
        INPUT_SLEEP_SECONDS=0 \
        INPUT_WORKING_DIRECTORY="$workdir" \
        bash "$SCRIPT"
  ) >"$tmp/out" 2>&1
  rc=$?
  LAST_OUT="$(cat "$tmp/out")"
  LAST_CALLS="$(wc -l <"$tmp/calls" | tr -d '[:space:]')"
  LAST_CWDS="$(cat "$tmp/calls")"
  return "$rc"
}

# A flaky pub.dev that recovers must end green — the whole point of #520.
transient_failure_recovers() {
  run_with_stub 2 5 || return 1
  [ "$LAST_CALLS" = "3" ] || {
    echo "expected 3 attempts, saw $LAST_CALLS"
    return 1
  }
}
assert_cmd "two transient failures then success -> exit 0 after 3 attempts" 0 \
  transient_failure_recovers

# A genuinely broken resolution must still fail — loud, and BOUNDED, so it does
# not burn the job's 90-minute timeout.
permanent_failure_is_bounded_and_loud() {
  run_with_stub 99 3 && return 1
  [ "$LAST_CALLS" = "3" ] || {
    echo "expected exactly 3 attempts (bounded), saw $LAST_CALLS"
    return 1
  }
  case "$LAST_OUT" in
  *"::error::dart pub get failed after 3 attempts"*) ;;
  *)
    echo "missing the ::error:: exhaustion message; got: $LAST_OUT"
    return 1
    ;;
  esac
  # The LAST attempt's own resolver output must reach the log, never be
  # swallowed into a generic message — otherwise a real dependency conflict
  # becomes undiagnosable.
  case "$LAST_OUT" in
  *"Insufficient permissions to the resource at the https://pub.dev package repository."*) ;;
  *)
    echo "the resolver's own failure text was swallowed; got: $LAST_OUT"
    return 1
    ;;
  esac
  return 0
}
assert_cmd "permanent failure -> nonzero, bounded at attempts, last error surfaced" 0 \
  permanent_failure_is_bounded_and_loud

# attempts=1 is a legal (if pointless) configuration and must not loop.
single_attempt_runs_once() {
  run_with_stub 99 1 && return 1
  [ "$LAST_CALLS" = "1" ] || {
    echo "expected exactly 1 attempt, saw $LAST_CALLS"
    return 1
  }
  return 0
}
assert_cmd "attempts=1 -> exactly one invocation" 0 single_attempt_runs_once

# working-directory must be honoured, since the ci.yml sites that used to run
# `cd dart && dart pub get` depend on it.
working_directory_is_honoured() {
  run_with_stub 0 2 "nested" || return 1
  case "$LAST_CWDS" in
  */nested) ;;
  *)
    echo "expected the resolver to run in .../nested, saw: $LAST_CWDS"
    return 1
    ;;
  esac
  return 0
}
assert_cmd "working-directory is honoured" 0 working_directory_is_honoured

# A mistyped input must fail loud, not silently disable the retry.
bad_attempts_fails_loud() {
  INPUT_ATTEMPTS=abc INPUT_SLEEP_SECONDS=0 bash "$SCRIPT" >/dev/null 2>&1
}
assert_cmd "non-numeric attempts -> exit 1" 1 bad_attempts_fails_loud

zero_attempts_fails_loud() {
  INPUT_ATTEMPTS=0 INPUT_SLEEP_SECONDS=0 bash "$SCRIPT" >/dev/null 2>&1
}
assert_cmd "attempts=0 -> exit 1" 1 zero_attempts_fails_loud

missing_workdir_fails_loud() {
  INPUT_ATTEMPTS=2 INPUT_SLEEP_SECONDS=0 \
    INPUT_WORKING_DIRECTORY="$STUB_ROOT/definitely-not-here" \
    bash "$SCRIPT" >/dev/null 2>&1
}
assert_cmd "missing working-directory -> exit 1" 1 missing_workdir_fails_loud

total=$((pass + fail))
# Positive floor: an exit code plus a failure count cannot tell "everything
# passed" from "nothing ran".
if [ "$total" -lt 1 ]; then
  echo "::error::dart-pub-get wiring test ran zero cases"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
