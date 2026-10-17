#!/usr/bin/env bash
# Static wiring guard for the "release via PR" shape (issue #755).
#
# WHY THIS EXISTS: the defect #755 reported was `release.yml` running
# `npx semantic-release` for real against `main`, whose core unconditionally
# pushes a version-bump commit (and `coverage-study.yml`'s separate
# `git push origin HEAD:refs/heads/main`) straight to the protected branch —
# both rejected outright by the `Protect main` ruleset's required-status-
# checks rule (GH013) since 2026-09-13. This pins the two parts of the fix so
# neither regresses silently:
#   (1) the dangerous DIRECT-PUSH-TO-MAIN pattern never reappears in any
#       workflow (a textual sweep — the same "grep .github/workflows for git
#       push" check #755's own Definition of Done asked for, made permanent);
#   (2) the two call sites that used to do it are wired to the shared
#       release-via-PR helper scripts instead.
#
# Deliberately textual/grep-based against the DOCUMENTED pattern (same style
# as check_release_dispatch_wiring.sh), not a YAML parser: it asserts the
# things that make the channel safe, not the incidental shape of the YAML
# around them.
#
# Usage:
#   bash tools/release/check_release_pr_wiring.sh
#   bash tools/release/check_release_pr_wiring.sh --self-test
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "PASS  $1"
}
no() {
  fail=$((fail + 1))
  echo "FAIL  $1"
}

# The exact rejected pattern (#755's repro): a raw push of the current branch
# straight onto `main`. Any workflow doing this hits GH013 the moment `main`
# has ANY required status check (the ruleset enforces on the push itself, not
# on who performs it) — so this is swept across every workflow file, not just
# the two historically-known offenders.
DIRECT_PUSH_PATTERN='git push[^|&;]*(origin[[:space:]]+)?HEAD:(refs/heads/)?main\b'

check_no_direct_push_to_main() {
  local workflows_dir="$1"
  local hit=0
  local file
  for file in "$workflows_dir"/*.yml; do
    [ -f "$file" ] || continue
    # Strip full-line comments first: a line explaining the HISTORY of this
    # defect (as this very fix's own commit messages/comments do) must not
    # trip the sweep — only an actual, executable occurrence should.
    if grep -v '^[[:space:]]*#' "$file" | grep -Eq "$DIRECT_PUSH_PATTERN"; then
      no "no workflow pushes straight to main — $file still does"
      hit=1
    fi
  done
  [ "$hit" -eq 0 ] && ok "no workflow under $workflows_dir pushes straight to main (git push … HEAD:main)"
}

check_release_yml_wiring() {
  local release_yml="$1"
  [ -f "$release_yml" ] || {
    no "release.yml exists at $release_yml"
    return
  }

  if grep -Eq 'run: *npx semantic-release\b' "$release_yml"; then
    no "release.yml no longer runs \`npx semantic-release\` directly (that is the rejected direct-push path)"
  else
    ok "release.yml does not run \`npx semantic-release\` directly"
  fi

  if grep -q 'tools/release/open_release_pr.sh' "$release_yml"; then
    ok "release.yml's release job calls tools/release/open_release_pr.sh (Phase 1)"
  else
    no "release.yml's release job calls tools/release/open_release_pr.sh (Phase 1)"
  fi

  if grep -q 'tools/release/finish_release.sh' "$release_yml"; then
    ok "release.yml's release job calls tools/release/finish_release.sh (Phase 2)"
  else
    no "release.yml's release job calls tools/release/finish_release.sh (Phase 2)"
  fi

  # The release job's git operations (push the release branch, push the tag)
  # need the checkout's credentials to still be usable afterwards.
  if grep -A3 'name: Semantic Release' "$release_yml" | grep -q 'persist-credentials: *false'; then
    no "release.yml's release job must NOT set persist-credentials: false (its scripts push with plain git)"
  else
    ok "release.yml's release job keeps checkout credentials persisted"
  fi
}

check_coverage_study_wiring() {
  local wf="$1"
  [ -f "$wf" ] || {
    no "coverage-study.yml exists at $wf"
    return
  }

  if grep -q 'tools/release/open_bot_pr.sh' "$wf"; then
    ok "coverage-study.yml's publish job calls tools/release/open_bot_pr.sh"
  else
    no "coverage-study.yml's publish job calls tools/release/open_bot_pr.sh"
  fi

  # PR #881 review finding 3: open_bot_pr.sh needs `pull-requests: write`
  # (gh pr list/create/edit/merge) and `actions: write` (the two
  # `gh workflow run` dispatches) on top of `contents: write` (the branch
  # push) — the job-level permissions block that overrides the workflow's
  # `contents: read` default must grant all three, or every `gh pr`/
  # `gh workflow run` call 403s the first time this job actually has
  # something to commit. Scoped to the `publish:` job's own block (from its
  # `publish:` line to EOF — it is the last job in the file) so a stricter
  # grant elsewhere in the file can never satisfy this by accident.
  local publish_block
  publish_block="$(awk '/^  publish:/{found=1} found' "$wf")"
  if [ -z "$publish_block" ]; then
    no "coverage-study.yml has a publish: job"
  else
    local scope
    for scope in 'contents: write' 'pull-requests: write' 'actions: write'; do
      if printf '%s\n' "$publish_block" | grep -qF "$scope"; then
        ok "coverage-study.yml's publish job permissions grant $scope"
      else
        no "coverage-study.yml's publish job permissions grant $scope (tools/release/open_bot_pr.sh's gh pr/gh workflow run calls 403 without it)"
      fi
    done
  fi
}

check_scripts_exist() {
  local script
  for script in \
    open_bot_pr.sh open_release_pr.sh finish_release.sh \
    compute_next_release.mjs apply_version_bump.mjs check_release_freshness.sh; do
    if [ -f "$ROOT/tools/release/$script" ]; then
      ok "tools/release/$script exists"
    else
      no "tools/release/$script exists"
    fi
  done
}

check_freshness_alarm_exists() {
  local wf="$ROOT/.github/workflows/release-freshness.yml"
  if [ -f "$wf" ] && grep -q 'check_release_freshness.sh' "$wf"; then
    ok "release-freshness.yml exists and runs check_release_freshness.sh"
  else
    no "release-freshness.yml exists and runs check_release_freshness.sh"
  fi
}

check_freshness_alarm_permissions() {
  local wf="$1"
  [ -f "$wf" ] || {
    no "release-freshness.yml exists"
    return
  }

  # PR #881 review (round 2) finding 2: `check_release_freshness.sh` runs
  # `compute_next_release.mjs`, whose `semantic-release` core calls
  # `verifyAuth()` (a `git push --dry-run`) UNCONDITIONALLY, even under
  # `dryRun: true` — GitHub 403s a dry-run push from a `contents: read`
  # token, so the workflow-level `contents: read` default this file
  # otherwise wants everywhere else must be overridden on the `freshness`
  # job specifically, or the alarm is red every week with an auth error
  # regardless of whether `main` is actually stale. Scoped to the
  # `freshness:` job's own block (from its line to EOF — it is the only job
  # in the file) so a stricter grant elsewhere can never satisfy this by
  # accident.
  local job_block
  job_block="$(awk '/^  freshness:/{found=1} found' "$wf")"
  if [ -z "$job_block" ]; then
    no "release-freshness.yml has a freshness: job"
  else
    local scope
    for scope in 'contents: write' 'pull-requests: read'; do
      if printf '%s\n' "$job_block" | grep -qF "$scope"; then
        ok "release-freshness.yml's freshness job permissions grant $scope"
      else
        no "release-freshness.yml's freshness job permissions grant $scope (compute_next_release.mjs's semantic-release verifyAuth() dry-run push 403s without it)"
      fi
    done
  fi
}

run_checks() {
  local workflows_dir="$1"
  check_no_direct_push_to_main "$workflows_dir"
  check_release_yml_wiring "$workflows_dir/release.yml"
  check_coverage_study_wiring "$workflows_dir/coverage-study.yml"
  check_freshness_alarm_permissions "$workflows_dir/release-freshness.yml"
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # Positive control: THIS repo's real, already-fixed workflows must pass.
  pass=0
  fail=0
  run_checks "$ROOT/.github/workflows"
  check_scripts_exist
  check_freshness_alarm_exists
  local real_pass=$pass real_fail=$fail
  if [ "$real_fail" -eq 0 ]; then
    echo "PASS  self-test: the real repo's workflows pass every check ($real_pass checks)"
  else
    echo "FAIL  self-test: the real repo's workflows must pass every check ($real_fail failing)"
  fi

  # Negative control: a workflow carrying the EXACT rejected pattern must be
  # caught. Three spellings the real history actually used.
  mkdir -p "$tmp/workflows"
  cat > "$tmp/workflows/bad1.yml" <<'EOF'
name: bad1
jobs:
  x:
    steps:
      - run: git push origin HEAD:refs/heads/main
EOF
  cat > "$tmp/workflows/bad2.yml" <<'EOF'
name: bad2
jobs:
  x:
    steps:
      - run: git push origin HEAD:main
EOF
  cat > "$tmp/workflows/good.yml" <<'EOF'
name: good
jobs:
  x:
    steps:
      # A comment documenting the HISTORY of this defect — e.g. "this used to
      # `git push origin HEAD:refs/heads/main`" — must never itself trip the
      # sweep; only an executable occurrence should.
      - run: bash tools/release/open_bot_pr.sh --branch bot/x --title t --body-file f
EOF

  pass=0
  fail=0
  check_no_direct_push_to_main "$tmp/workflows"
  local neg_pass=$pass neg_fail=$fail
  # Expect exactly 2 failures (bad1.yml, bad2.yml) and the rest (1 ok) passes.
  if [ "$neg_fail" -eq 2 ] && [ "$neg_pass" -eq 0 ]; then
    echo "PASS  self-test: negative control — both direct-push spellings are caught, the clean file reports no failure line"
  else
    echo "FAIL  self-test: negative control (got pass=$neg_pass fail=$neg_fail, want pass=0 fail=2)"
  fi

  rm -f "$tmp/workflows/bad1.yml" "$tmp/workflows/bad2.yml"
  pass=0
  fail=0
  check_no_direct_push_to_main "$tmp/workflows"
  local cleanonly_pass=$pass cleanonly_fail=$fail
  if [ "$cleanonly_fail" -eq 0 ] && [ "$cleanonly_pass" -eq 1 ]; then
    echo "PASS  self-test: negative control — the clean file alone passes"
  else
    echo "FAIL  self-test: negative control — the clean file alone passes (got pass=$cleanonly_pass fail=$cleanonly_fail)"
  fi

  # Negative control for finding 2's guard: a release-freshness.yml missing
  # either permission scope must be caught, and one carrying both must pass.
  cat > "$tmp/workflows/bad-freshness.yml" <<'EOF'
name: bad-freshness
permissions:
  contents: read
jobs:
  freshness:
    runs-on: ubuntu-latest
    steps:
      - run: bash tools/release/check_release_freshness.sh
EOF
  cat > "$tmp/workflows/good-freshness.yml" <<'EOF'
name: good-freshness
permissions:
  contents: read
jobs:
  freshness:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: read
    steps:
      - run: bash tools/release/check_release_freshness.sh
EOF

  pass=0
  fail=0
  check_freshness_alarm_permissions "$tmp/workflows/bad-freshness.yml"
  local badfresh_pass=$pass badfresh_fail=$fail
  if [ "$badfresh_fail" -eq 2 ] && [ "$badfresh_pass" -eq 0 ]; then
    echo "PASS  self-test: negative control — a freshness job missing both scopes is caught (2 failures)"
  else
    echo "FAIL  self-test: negative control — a freshness job missing both scopes is caught (got pass=$badfresh_pass fail=$badfresh_fail, want pass=0 fail=2)"
  fi

  pass=0
  fail=0
  check_freshness_alarm_permissions "$tmp/workflows/good-freshness.yml"
  local goodfresh_pass=$pass goodfresh_fail=$fail
  if [ "$goodfresh_fail" -eq 0 ] && [ "$goodfresh_pass" -eq 2 ]; then
    echo "PASS  self-test: negative control — a freshness job granting both scopes passes"
  else
    echo "FAIL  self-test: negative control — a freshness job granting both scopes passes (got pass=$goodfresh_pass fail=$goodfresh_fail)"
  fi

  [ "$real_fail" -eq 0 ] && [ "$neg_fail" -eq 2 ] && [ "$neg_pass" -eq 0 ] && [ "$cleanonly_fail" -eq 0 ] &&
    [ "$badfresh_fail" -eq 2 ] && [ "$badfresh_pass" -eq 0 ] && [ "$goodfresh_fail" -eq 0 ] && [ "$goodfresh_pass" -eq 2 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

run_checks "$ROOT/.github/workflows"
check_scripts_exist
check_freshness_alarm_exists

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
