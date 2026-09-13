#!/usr/bin/env bash
# Loop-breaker for the `Ball Artifact Freshness` auto-push (issue #625).
#
# WHY THIS EXISTS: when the repository secret `REGEN_PAT` is set, ci.yml's
# `Ball Artifact Freshness` job commits the regenerated Ball artifacts onto the
# PR's own branch and pushes. A PAT push triggers a fresh CI run *by design*
# (that is the whole reason it is not `GITHUB_TOKEN` — see the step's comment),
# so the job that produced the commit runs again on it.
#
# THAT IS A LOOP IF ANY GENERATOR IS NONDETERMINISTIC. The only short-circuit
# #620 shipped is `git diff --cached --quiet`, which stops the *identical-bytes*
# case and nothing else: a generator that emits a timestamp, a map iteration
# order, or an absolute path produces different-but-equally-"correct" bytes every
# run, so every run drifts, pushes, and re-triggers — forever, burning the whole
# Actions budget with a green-looking cadence of commits nobody asked for.
#
# THE RULE: at most ONE auto-push per HUMAN commit. The regeneration commit
# carries a marker trailer; before pushing, the job asks this script whether the
# PR head commit already carries it. If it does, the head is itself an auto-push,
# the drift survived it, and a human has to look at the generator — so the push
# is skipped and the run says so loudly instead of pushing commit N+1.
#
# WHY A LINE MATCH AND NOT `git interpret-trailers --parse`: the commit is built
# from several `git commit -m` arguments, and each `-m` becomes its own
# PARAGRAPH. `--parse` only reads the last paragraph as trailers, so it would see
# a single trailer and miss the rest. This checks the whole message for a
# trailer-shaped LINE, which is correct for both shapes (one trailer paragraph or
# several). The key is matched case-insensitively (git treats trailer tokens that
# way); the value must match exactly, and the line must start at column 0 so that
# prose quoting the marker — including this file's own comments once they are
# ever pasted into a message — cannot trip it.
#
# Usage:
#   bash tools/ci/regen_loop_breaker.sh --print-marker      # the trailer line
#   bash tools/ci/regen_loop_breaker.sh --rev <commit-ish>  # check a commit
#   bash tools/ci/regen_loop_breaker.sh --message-file FILE # check a message
#   bash tools/ci/regen_loop_breaker.sh --self-test         # drive the cases
#
# Exit codes:
#   0  no marker — safe to auto-push
#   3  marker present — the head is already an auto-push; DO NOT push again
#   2  usage error
#   1  the message could not be read, or was empty (fail loud: never push on an
#      unreadable head, since "no marker found" would then be a guess)
#
# Needs bash + git only, so it runs both on the runner and in ci.yml's always-on
# `Proto Checks` job with no toolchain.

set -uo pipefail

MARKER_KEY="Ball-Regen-Autopush"
MARKER_VALUE="ball-artifact-freshness"
MARKER_LINE="${MARKER_KEY}: ${MARKER_VALUE}"

MODE=""
ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
  --print-marker)
    MODE="print"
    shift
    ;;
  --rev)
    MODE="rev"
    ARG="${2:-}"
    shift 2
    ;;
  --rev=*)
    MODE="rev"
    ARG="${1#--rev=}"
    shift
    ;;
  --message-file)
    MODE="file"
    ARG="${2:-}"
    shift 2
    ;;
  --message-file=*)
    MODE="file"
    ARG="${1#--message-file=}"
    shift
    ;;
  --self-test)
    MODE="self-test"
    shift
    ;;
  -h | --help)
    sed -n '2,50p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

# ── the check itself ────────────────────────────────────────────────────────
# Reads a commit message on stdin. 0 = clean, 3 = marker found, 1 = empty.
check_message() {
  local message
  message="$(cat)"

  if [ -z "${message//[[:space:]]/}" ]; then
    echo "::error::the commit message is empty — refusing to decide whether the head is an auto-push. Not pushing."
    return 1
  fi

  # `grep -i` on the KEY only; the value is compared exactly by the pattern's
  # tail. `^` pins it to column 0 so an indented quotation in a body does not
  # match, and the trailing `[[:space:]]*$` allows a stray CR from a
  # Windows-authored message without allowing a different value.
  if printf '%s\n' "$message" |
    grep -qiE "^${MARKER_KEY}:[[:space:]]*${MARKER_VALUE}[[:space:]]*$"; then
    return 3
  fi
  return 0
}

check_rev() {
  local rev="$1" msg rc=0
  if [ -z "$rev" ]; then
    echo "::error::--rev needs a commit-ish"
    return 2
  fi
  # No `--` separator on purpose: the argument is a revision, never a pathspec.
  msg="$(git log -1 --format=%B "$rev" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "::error::cannot read the commit message of '$rev'. Not pushing."
    return 1
  fi
  printf '%s\n' "$msg" | check_message
}

check_file() {
  local file="$1"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "::error::message file not found: ${file:-<none>}. Not pushing."
    return 1
  fi
  check_message <"$file"
}

report() {
  local rc="$1"
  case "$rc" in
  0) echo "No '${MARKER_KEY}' marker on the head commit — one auto-push is allowed." ;;
  3)
    echo "::error::the head commit already carries '${MARKER_LINE}' — it IS an auto-push, and the artifacts drifted AGAIN on top of it."
    echo "That means a generator is not deterministic: pushing again would loop (push -> run -> drift -> push)."
    echo "Skipping the auto-push. Download the 'regenerated-artifacts' artifact and fix the generator."
    ;;
  esac
  return "$rc"
}

# ── self-test ───────────────────────────────────────────────────────────────
SCRATCH=""
cleanup() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  return 0
}

self_test() {
  local pass=0 fail=0
  SCRATCH="$(mktemp -d)"
  trap cleanup EXIT

  # expect <name> <want-exit> <message>
  expect() {
    local name="$1" want="$2" body="$3"
    local f rc=0 out
    f="$SCRATCH/msg.$RANDOM.txt"
    printf '%s' "$body" >"$f"
    out="$(check_file "$f" 2>&1)" || rc=$?
    if [ "$rc" -eq "$want" ]; then
      pass=$((pass + 1))
      echo "PASS $name"
    else
      fail=$((fail + 1))
      echo "FAIL $name (exit $rc, wanted $want)"
      echo "$out" | sed 's/^/    | /'
    fi
  }

  local human='fix(engine): teach the block compiler about bare returns

Closes #1234.

Generated-By: claude-code (model: x; operator: y)
Signed-off-by: A B <a@b>
'
  local autopush_one_paragraph='chore(ci): apply the regenerated Ball artifacts

Produced by run 1.

Generated-By: claude-code (model: ci; operator: y)
Signed-off-by: A B <a@b>
'"$MARKER_LINE"'
'
  # The shape ci.yml actually produces: every `git commit -m` argument is its
  # own paragraph, so the marker is alone in the final block.
  local autopush_multi_paragraph='chore(ci): apply the regenerated Ball artifacts

Produced by run 1.

Generated-By: claude-code (model: ci; operator: y)

Signed-off-by: A B <a@b>

'"$MARKER_LINE"'
'
  local autopush_first_line="$MARKER_LINE"'

body follows
'
  local lowercase_key='chore(ci): apply

ball-regen-autopush: '"$MARKER_VALUE"'
'
  local quoted_in_prose='docs(ci): explain the loop-breaker

The regeneration commit carries a trailer:

    '"$MARKER_LINE"'

which the next run reads back.
'
  local different_value='chore(ci): apply

'"$MARKER_KEY"': some-other-producer
'
  local prefixed_key='chore(ci): apply

X-'"$MARKER_LINE"'
'
  local no_trailers='chore: bump a dep
'

  expect "a human commit is pushable" 0 "$human"
  expect "one-paragraph autopush trailer is caught" 3 "$autopush_one_paragraph"
  expect "multi-paragraph autopush trailer is caught" 3 "$autopush_multi_paragraph"
  expect "a marker on the subject line is caught" 3 "$autopush_first_line"
  expect "a lowercased trailer key is caught" 3 "$lowercase_key"
  expect "an indented quotation is NOT caught" 0 "$quoted_in_prose"
  expect "a different marker value is NOT caught" 0 "$different_value"
  expect "a prefixed trailer key is NOT caught" 0 "$prefixed_key"
  expect "a plain commit is pushable" 0 "$no_trailers"
  expect "an empty message fails loud" 1 ""
  expect "a whitespace-only message fails loud" 1 "$(printf '   \n\n  \n')"

  # A missing file must fail loud too — "no marker" on an unreadable head is a
  # guess, and a guess here pushes.
  local rc=0
  check_file "$SCRATCH/definitely-absent.txt" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    pass=$((pass + 1))
    echo "PASS a missing message file fails loud"
  else
    fail=$((fail + 1))
    echo "FAIL a missing message file fails loud (exit $rc, wanted 1)"
  fi

  # --print-marker is the SINGLE source of the literal: ci.yml's commit step
  # takes the trailer from here, and this script reads it back. If the two ever
  # diverge the loop-breaker silently stops breaking loops, so assert the exact
  # shape rather than just "non-empty".
  local printed
  printed="$(bash "${BASH_SOURCE[0]}" --print-marker)"
  if [ "$printed" = "$MARKER_KEY: $MARKER_VALUE" ] && [ -n "$MARKER_VALUE" ]; then
    pass=$((pass + 1))
    echo "PASS --print-marker emits '$printed'"
  else
    fail=$((fail + 1))
    echo "FAIL --print-marker emits '$printed'"
  fi

  # And the round trip: a message built from the printed marker must be caught.
  local roundtrip="chore(ci): apply

$printed
"
  expect "the printed marker round-trips into a catch" 3 "$roundtrip"

  echo "Results: $pass passed, $fail failed, $((pass + fail)) total"
  if [ "$pass" -lt 12 ]; then
    echo "::error::self-test executed fewer cases than expected ($pass < 12) — a self-test that ran nothing is not a passing self-test."
    return 1
  fi
  [ "$fail" -eq 0 ]
}

case "$MODE" in
print)
  printf '%s\n' "$MARKER_LINE"
  exit 0
  ;;
self-test)
  self_test
  exit $?
  ;;
rev)
  rc=0
  check_rev "$ARG" || rc=$?
  report "$rc"
  exit $?
  ;;
file)
  rc=0
  check_file "$ARG" || rc=$?
  report "$rc"
  exit $?
  ;;
*)
  echo "::error::one of --print-marker / --rev / --message-file / --self-test is required" >&2
  exit 2
  ;;
esac
