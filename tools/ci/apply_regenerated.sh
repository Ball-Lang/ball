#!/usr/bin/env bash
# Apply the Ball artifacts CI regenerated for a PR (issue #619).
#
# WHAT PROBLEM THIS SOLVES: ci.yml's `Ball Artifact Freshness` job regenerates
# every committed Ball artifact and fails on drift. Until #619 the only remedy
# was to run the whole Dart + TS + Go regeneration chain locally — the most
# expensive local step a lane has, on a machine that may not even have the
# toolchains installed. But the job has ALREADY produced the correct bytes: it
# now uploads them as the `regenerated-artifacts` workflow artifact. This script
# downloads that artifact and stages it, so "regenerate" becomes download +
# commit with no local toolchain at all.
#
# SAFETY — IT REFUSES TO APPLY BYTES COMPUTED FROM A DIFFERENT COMMIT. The
# artifacts are a deterministic function of the sources at the run's head SHA.
# Applying a run's output onto a DIFFERENT HEAD would commit artifacts that do
# not correspond to the tree, and the next CI run would simply fail again — with
# a diff nobody can explain. So the run's head SHA must equal the current HEAD,
# and the check is a hard error with an explicit override rather than a warning.
#
# Usage:
#   tools/ci/apply_regenerated.sh <pr-number>       # newest CI run for the PR head
#   tools/ci/apply_regenerated.sh --pr 619
#   tools/ci/apply_regenerated.sh --run 12345678901 # a specific workflow run id
#   tools/ci/apply_regenerated.sh --from-dir DIR    # an already-downloaded copy
#   tools/ci/apply_regenerated.sh --self-test       # drive the cases offline
#
# A bare positional argument is read as a PR number below 1e7 and as a run id at
# or above it (GitHub run ids are ten digits and up; this repo's PR numbers are
# three). Pass --pr/--run to be explicit.
#
# Options:
#   --repo-root DIR    apply into DIR instead of the git root of this checkout
#   --allow-head-drift skip the head-SHA equality check (you are on your own)
#   --repo OWNER/NAME  GitHub repo to query (default: Ball-Lang/ball)
#   --workflow FILE    workflow file to look for runs in (default: ci.yml)
#
# Needs bash + git, plus the GitHub CLI (`gh`, authenticated) for everything
# except --from-dir/--self-test.

set -uo pipefail

REPO="Ball-Lang/ball"
WORKFLOW="ci.yml"
ARTIFACT="regenerated-artifacts"
PR=""
RUN_ID=""
FROM_DIR=""
REPO_ROOT=""
ALLOW_HEAD_DRIFT=0
SELF_TEST=0

die() {
  echo "::error::$*" >&2
  exit 1
}

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
  case "$1" in
  --pr)
    PR="$2"
    shift 2
    ;;
  --pr=*)
    PR="${1#--pr=}"
    shift
    ;;
  --run)
    RUN_ID="$2"
    shift 2
    ;;
  --run=*)
    RUN_ID="${1#--run=}"
    shift
    ;;
  --from-dir)
    FROM_DIR="$2"
    shift 2
    ;;
  --from-dir=*)
    FROM_DIR="${1#--from-dir=}"
    shift
    ;;
  --repo-root)
    REPO_ROOT="$2"
    shift 2
    ;;
  --repo-root=*)
    REPO_ROOT="${1#--repo-root=}"
    shift
    ;;
  --repo)
    REPO="$2"
    shift 2
    ;;
  --repo=*)
    REPO="${1#--repo=}"
    shift
    ;;
  --workflow)
    WORKFLOW="$2"
    shift 2
    ;;
  --workflow=*)
    WORKFLOW="${1#--workflow=}"
    shift
    ;;
  --allow-head-drift)
    ALLOW_HEAD_DRIFT=1
    shift
    ;;
  --self-test)
    SELF_TEST=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    die "unknown option: $1"
    ;;
  *)
    case "$1" in
    '' | *[!0-9]*) die "expected a PR number or run id, got: $1" ;;
    esac
    # Ten-digit-and-up means a workflow run id; anything smaller is a PR number.
    if [ "$1" -ge 10000000 ]; then RUN_ID="$1"; else PR="$1"; fi
    shift
    ;;
  esac
done

# ── apply a downloaded artifact tree into the checkout ──────────────────────
# The artifact's entries ARE repo-relative paths (the workflow stages them that
# way), so applying is a copy plus a `git add`. Kept as its own function with no
# network in it, which is what makes the self-test able to drive the real code
# path instead of a re-implementation of it.
apply_from_dir() {
  local src="$1" root="$2"
  [ -d "$src" ] || die "not a directory: $src"
  [ -d "$root/.git" ] || die "not a git checkout: $root"

  local files=()
  local rel
  while IFS= read -r rel; do
    files+=("$rel")
  done < <(cd "$src" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

  # POSITIVE FLOOR. An empty artifact applied without complaint would let a lane
  # commit nothing, re-push, and watch the same gate fail again — the "nothing
  # ran looks like everything passed" shape this repo refuses everywhere else.
  if [ "${#files[@]}" -eq 0 ]; then
    die "the artifact contains no files — nothing to apply. Re-read the failing run; the freshness job uploads this artifact only when a committed artifact actually drifted."
  fi

  # Validate EVERY entry before copying ANY of them — a half-applied artifact is
  # worse than a refused one.
  local f
  for f in "${files[@]}"; do
    case "$f" in
    /* | *..*) die "refusing to apply a suspicious artifact path: $f" ;;
    esac
  done

  for f in "${files[@]}"; do
    mkdir -p "$root/$(dirname "$f")"
    cp -- "$src/$f" "$root/$f"
  done

  (cd "$root" && git add -- "${files[@]}") || die "git add failed"

  echo "Applied ${#files[@]} regenerated file(s) into $root:"
  printf '  %s\n' "${files[@]}"
  echo
  local staged
  staged="$(cd "$root" && git diff --cached --name-only | wc -l | tr -d ' ')"
  echo "Results: ${#files[@]} applied, $staged staged"
  if [ "$staged" -eq 0 ]; then
    echo "NOTE: every applied file already matched the checkout, so nothing is staged."
    echo "      That means the drift CI saw is not reproducible from this commit —"
    echo "      check that your HEAD is the commit the run was started from."
  fi
  echo
  echo "Next: git commit -m 'chore: apply the CI-regenerated Ball artifacts'"
}

# ── resolve the run and download ────────────────────────────────────────────
resolve_run_for_pr() {
  local pr="$1" head_sha run
  command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is required to resolve a PR; install it or pass --from-dir"
  head_sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)" ||
    die "could not read PR #$pr from $REPO"
  [ -n "$head_sha" ] || die "PR #$pr has no head SHA"
  run="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --commit "$head_sha" \
    --limit 1 --json databaseId --jq '.[0].databaseId')" ||
    die "could not list runs for $head_sha"
  [ -n "$run" ] && [ "$run" != "null" ] ||
    die "no $WORKFLOW run found for PR #$pr's head $head_sha — has CI started yet?"
  printf '%s' "$run"
}

run_head_sha() {
  local run="$1"
  command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is required"
  gh run view "$run" --repo "$REPO" --json headSha --jq .headSha
}

# ── self-test ───────────────────────────────────────────────────────────────
SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; return 0; }

self_test() {
  local pass=0 fail=0
  SCRATCH="$(mktemp -d)"
  trap cleanup EXIT

  local checkout="$SCRATCH/repo"
  mkdir -p "$checkout/ts/cli/src" "$checkout/go/cli/compiled"
  (
    cd "$checkout"
    git init -q .
    git config user.email t@example.com
    git config user.name t
    printf 'STALE\n' >ts/cli/src/compiled_cli.ts
    printf 'package compiled\n' >go/cli/compiled/compiled_cli.go
    git add -A
    git commit -qm init
  ) >/dev/null 2>&1

  # A FABRICATED artifact dir, shaped exactly like what the workflow uploads:
  # repo-relative paths, LF bytes.
  local art="$SCRATCH/artifact"
  mkdir -p "$art/ts/cli/src" "$art/go/cli/compiled"
  printf 'FRESH\n' >"$art/ts/cli/src/compiled_cli.ts"
  printf 'package compiled\n// fresh\n' >"$art/go/cli/compiled/compiled_cli.go"

  local out rc

  # 1. the happy path applies the bytes and stages them
  rc=0
  out="$(apply_from_dir "$art" "$checkout" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] &&
    [ "$(cat "$checkout/ts/cli/src/compiled_cli.ts")" = "FRESH" ] &&
    printf '%s' "$out" | grep -q "^Results: 2 applied, 2 staged$" &&
    (cd "$checkout" && git diff --cached --name-only | grep -q '^ts/cli/src/compiled_cli.ts$'); then
    pass=$((pass + 1))
    echo "PASS applies the artifact and stages every file"
  else
    fail=$((fail + 1))
    echo "FAIL applies the artifact and stages every file (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  # 2. LF is preserved byte-for-byte (a CRLF checkout must not corrupt the copy)
  if [ "$(wc -c <"$checkout/ts/cli/src/compiled_cli.ts" | tr -d ' ')" = "6" ]; then
    pass=$((pass + 1))
    echo "PASS preserves LF bytes exactly"
  else
    fail=$((fail + 1))
    echo "FAIL preserves LF bytes exactly (got $(wc -c <"$checkout/ts/cli/src/compiled_cli.ts") bytes, wanted 6)"
  fi

  # 3. the positive floor: an EMPTY artifact is an error, never a silent no-op
  local empty="$SCRATCH/empty"
  mkdir -p "$empty"
  rc=0
  out="$(apply_from_dir "$empty" "$checkout" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no files to apply\|contains no files"; then
    pass=$((pass + 1))
    echo "PASS an empty artifact fails loud (positive floor)"
  else
    fail=$((fail + 1))
    echo "FAIL an empty artifact fails loud (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  # 4. a path-traversal entry is refused
  local eviltmp="$SCRATCH/evil"
  mkdir -p "$eviltmp/nested"
  printf 'x\n' >"$eviltmp/nested/ok.txt"
  mkdir -p "$eviltmp/up..down"
  printf 'x\n' >"$eviltmp/up..down/bad.txt"
  rc=0
  out="$(apply_from_dir "$eviltmp" "$checkout" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "suspicious artifact path"; then
    pass=$((pass + 1))
    echo "PASS a '..' artifact path is refused"
  else
    fail=$((fail + 1))
    echo "FAIL a '..' artifact path is refused (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  # 5. a non-checkout destination is refused
  rc=0
  out="$(apply_from_dir "$art" "$SCRATCH/nope" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass=$((pass + 1))
    echo "PASS a non-git destination is refused"
  else
    fail=$((fail + 1))
    echo "FAIL a non-git destination is refused"
  fi

  # 6. the head-SHA guard: a run computed from another commit is refused, and
  #    the whole --from-dir flow honours it. BALL_APPLY_RUN_HEAD_SHA is the
  #    injection seam the real `gh run view` fills in.
  rc=0
  out="$(BALL_APPLY_RUN_HEAD_SHA=0000000000000000000000000000000000000000 \
    bash "${BASH_SOURCE[0]}" --from-dir "$art" --repo-root "$checkout" --run 12345678901 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "was computed from"; then
    pass=$((pass + 1))
    echo "PASS refuses an artifact computed from a different HEAD"
  else
    fail=$((fail + 1))
    echo "FAIL refuses an artifact computed from a different HEAD (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  # 7. …and accepts it when the run's head IS this HEAD
  local head
  head="$(cd "$checkout" && git rev-parse HEAD)"
  printf 'FRESHER\n' >"$art/ts/cli/src/compiled_cli.ts"
  rc=0
  out="$(BALL_APPLY_RUN_HEAD_SHA="$head" \
    bash "${BASH_SOURCE[0]}" --from-dir "$art" --repo-root "$checkout" --run 12345678901 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$checkout/ts/cli/src/compiled_cli.ts")" = "FRESHER" ]; then
    pass=$((pass + 1))
    echo "PASS applies when the run's head matches HEAD"
  else
    fail=$((fail + 1))
    echo "FAIL applies when the run's head matches HEAD (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  # 8. a bare positional is classified as PR vs run id
  rc=0
  out="$(bash "${BASH_SOURCE[0]}" --from-dir "$art" --repo-root "$checkout" --allow-head-drift 619 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "PR #619"; then
    pass=$((pass + 1))
    echo "PASS a small bare number is read as a PR number"
  else
    fail=$((fail + 1))
    echo "FAIL a small bare number is read as a PR number (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  rc=0
  out="$(bash "${BASH_SOURCE[0]}" --from-dir "$art" --repo-root "$checkout" --allow-head-drift 12345678901 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "run 12345678901"; then
    pass=$((pass + 1))
    echo "PASS a large bare number is read as a run id"
  else
    fail=$((fail + 1))
    echo "FAIL a large bare number is read as a run id (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  # 9. a non-numeric positional is rejected
  rc=0
  out="$(bash "${BASH_SOURCE[0]}" nonsense 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "expected a PR number or run id"; then
    pass=$((pass + 1))
    echo "PASS a non-numeric argument is rejected"
  else
    fail=$((fail + 1))
    echo "FAIL a non-numeric argument is rejected (exit $rc)"
  fi

  echo "Results: $pass passed, $fail failed, $((pass + fail)) total"
  if [ "$pass" -lt 10 ]; then
    echo "::error::self-test executed fewer cases than expected ($pass < 10) — a self-test that ran nothing is not a passing self-test."
    return 1
  fi
  [ "$fail" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

# ── main ────────────────────────────────────────────────────────────────────
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "not inside a git checkout — pass --repo-root DIR"
fi

if [ -n "$PR" ]; then
  echo "Resolving the latest $WORKFLOW run for PR #$PR on $REPO …"
fi
if [ -z "$RUN_ID" ] && [ -n "$PR" ] && [ -z "$FROM_DIR" ]; then
  RUN_ID="$(resolve_run_for_pr "$PR")" || exit 1
fi
if [ -z "$RUN_ID" ] && [ -z "$FROM_DIR" ]; then
  usage >&2
  die "pass a PR number, --run <id>, or --from-dir <dir>"
fi
[ -n "$RUN_ID" ] && echo "Using run $RUN_ID."

# Head-SHA equality. `BALL_APPLY_RUN_HEAD_SHA` short-circuits the `gh` call so
# the self-test can drive this branch offline; in normal use it is unset.
if [ -n "$RUN_ID" ] && [ "$ALLOW_HEAD_DRIFT" -eq 0 ]; then
  run_head="${BALL_APPLY_RUN_HEAD_SHA:-}"
  [ -n "$run_head" ] || run_head="$(run_head_sha "$RUN_ID")"
  local_head="$(cd "$REPO_ROOT" && git rev-parse HEAD)"
  if [ "$run_head" != "$local_head" ]; then
    die "run $RUN_ID was computed from $run_head but HEAD is $local_head. These artifacts are a function of the sources at that commit, so applying them here would commit bytes the tree does not produce. Check out that commit (or push and wait for a run on this one), or pass --allow-head-drift if you truly mean to."
  fi
  echo "Run head matches HEAD ($local_head)."
fi

if [ -z "$FROM_DIR" ]; then
  command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is required to download an artifact"
  DL="$(mktemp -d)"
  trap 'rm -rf "$DL"' EXIT
  echo "Downloading the '$ARTIFACT' artifact from run $RUN_ID …"
  gh run download "$RUN_ID" --repo "$REPO" --name "$ARTIFACT" --dir "$DL" ||
    die "could not download the '$ARTIFACT' artifact from run $RUN_ID. The freshness job uploads it only when a committed artifact drifted — if that job passed, there is nothing to apply."
  FROM_DIR="$DL"
fi

apply_from_dir "$FROM_DIR" "$REPO_ROOT"
