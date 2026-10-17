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

# `dry_run` is declared `type: boolean` on every release workflow's
# `workflow_dispatch` input, which means the `inputs.dry_run` expression
# context carries a REAL boolean — not the string "true"/"false" that
# `github.event.inputs.dry_run` always carries regardless of declared type.
# GitHub Actions' `==` converts a boolean operand to a number (false -> 0)
# and a non-numeric string operand to NaN before comparing, so
# `inputs.dry_run == 'false'` (or `'true'`) is ALWAYS false — confirmed by
# dispatching go-release.yml's `open-release-pr` job with `-f dry_run=true`
# and observing both of its `inputs.dry_run`-gated steps report `skipped`
# (PR #881 review). `release.yml`'s own `finish-release` job had the
# identical bug on its `workflow_dispatch` branch — silent because the
# `push`/`schedule` OR-terms already cover every real trigger, so it only
# ever mattered for a manual `-f dry_run=false` dispatch. A comparison
# against a step OUTPUT (always a string, e.g. `steps.cfg.outputs.dry_run ==
# 'false'`) is NOT this bug and must not be flagged — only `inputs.dry_run`
# compared to a quoted literal is.
QUOTED_BOOL_DRY_RUN_PATTERN="inputs\\.dry_run[[:space:]]*==[[:space:]]*['\"](true|false)['\"]"

check_no_quoted_boolean_dry_run_comparison() {
  local workflows_dir="$1"
  local hit=0
  local file
  for file in "$workflows_dir"/*.yml; do
    [ -f "$file" ] || continue
    if grep -v '^[[:space:]]*#' "$file" | grep -Eq "$QUOTED_BOOL_DRY_RUN_PATTERN"; then
      no "no workflow compares inputs.dry_run (a real boolean) to a quoted string — $file still does"
      hit=1
    fi
  done
  [ "$hit" -eq 0 ] && ok "no workflow under $workflows_dir compares inputs.dry_run to a quoted 'true'/'false' (always false)"
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
    compute_next_release.mjs apply_version_bump.mjs check_release_freshness.sh \
    service_bot_merge_queue.sh; do
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

# PR #881 review round 3, finding 1: `main` requires a merge queue, and a bot
# PR whose auto-merge `GITHUB_TOKEN` armed is enqueued on behalf of
# `github-actions` — a merge group that starts no `merge_group` workflow run.
# tools/release/service_bot_merge_queue.sh (run on a schedule by
# bot-merge-queue.yml) dispatches the required-check workflows onto it instead.
# This pins (a) that the servicer is actually scheduled, runs that script, and
# may dispatch; and (b) that the workflows it dispatches for a merge group are
# EXACTLY the ones each bot-PR caller dispatches for its own branch — if a
# third workflow ever starts owning a required context and is added to the
# callers only, the bot PR's own checks would pass and its merge group would
# still never report that context.
check_merge_queue_servicer() {
  local wf="$1" servicer="$2"
  shift 2
  [ -f "$wf" ] || {
    no "bot-merge-queue.yml exists at $wf"
    return
  }
  [ -f "$servicer" ] || {
    no "service_bot_merge_queue.sh exists at $servicer"
    return
  }

  if grep -Eq '^[[:space:]]*-[[:space:]]*cron:' "$wf"; then
    ok "bot-merge-queue.yml runs on a schedule"
  else
    no "bot-merge-queue.yml runs on a schedule (a bot merge group nobody services blocks the queue for 90 minutes)"
  fi
  if grep -q 'tools/release/service_bot_merge_queue.sh' "$wf"; then
    ok "bot-merge-queue.yml runs tools/release/service_bot_merge_queue.sh"
  else
    no "bot-merge-queue.yml runs tools/release/service_bot_merge_queue.sh"
  fi
  if grep -qF 'actions: write' "$wf"; then
    ok "bot-merge-queue.yml grants actions: write (gh workflow run)"
  else
    no "bot-merge-queue.yml grants actions: write (its gh workflow run dispatches 403 without it)"
  fi

  local want
  want="$(sed -n 's/^REQUIRED_CHECK_WORKFLOWS=(\(.*\))$/\1/p' "$servicer" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')"
  if [ -z "$want" ]; then
    no "service_bot_merge_queue.sh declares REQUIRED_CHECK_WORKFLOWS=(…) on one line (nothing to compare)"
    return
  fi
  local caller got
  for caller in "$@"; do
    got="$(grep -oE -- '--dispatch [^[:space:]\\]+' "$caller" | awk '{print $2}' | sort | tr '\n' ' ')"
    if [ -z "$got" ]; then
      no "$(basename "$caller") passes --dispatch to open_bot_pr.sh (found none)"
    elif [ "$got" = "$want" ]; then
      ok "$(basename "$caller")'s --dispatch set ($got) matches the merge-queue servicer's"
    else
      no "$(basename "$caller")'s --dispatch set ($got) matches the merge-queue servicer's REQUIRED_CHECK_WORKFLOWS ($want)"
    fi
  done
}

# Every step that drives semantic-release — even as a dry run — needs a GitHub
# token in its environment: @semantic-release/github's verifyConditions refuses
# to run without one ("SemanticReleaseError: No GitHub token specified.",
# release.yml's dry-run rehearsal, run 39064722119, the first rehearsal after
# #881). python3 + PyYAML because the token can sit in the step's OR the job's
# `env:` mapping, which only a real parse can tell apart from a comment.
SEMREL_STEP_PATTERN='compute_next_release\.mjs|open_release_pr\.sh|open_go_release_pr\.sh|npx semantic-release'

check_semantic_release_steps_have_token() {
  local workflows_dir="$1" out rc
  out="$(python3 - "$workflows_dir" "$SEMREL_STEP_PATTERN" <<'PY'
import glob
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the runner image ships PyYAML
    print("ERROR PyYAML is required (pip install pyyaml)")
    sys.exit(2)

workflows_dir, pattern = sys.argv[1], re.compile(sys.argv[2])
TOKENS = ("GH_TOKEN", "GITHUB_TOKEN")
seen = 0
for path in sorted(glob.glob(os.path.join(workflows_dir, "*.yml"))):
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    for job_id, job in (doc.get("jobs") or {}).items():
        job_env = (job or {}).get("env") or {}
        for step in (job or {}).get("steps") or []:
            run = step.get("run") or ""
            if not pattern.search(run):
                continue
            seen += 1
            env = dict(job_env)
            env.update(step.get("env") or {})
            name = step.get("name") or run.strip().splitlines()[0]
            if any(t in env for t in TOKENS):
                print(f"OK {os.path.basename(path)}:{job_id}: '{name}' has a GitHub token in env")
            else:
                print(f"MISSING {os.path.basename(path)}:{job_id}: '{name}' runs semantic-release with no GH_TOKEN/GITHUB_TOKEN in its step or job env")
print(f"SEEN {seen}")
PY
)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    no "semantic-release token check ran (python3 exit $rc: $out)"
    return
  fi
  local line seen=0 missing=0
  while IFS= read -r line; do
    case "$line" in
      MISSING*) no "${line#MISSING }"; missing=1 ;;
      SEEN*) seen="${line#SEEN }" ;;
    esac
  done <<< "$out"
  if [ "$seen" -eq 0 ]; then
    no "found at least one semantic-release step under $workflows_dir to check (found none - the pattern went stale)"
  elif [ "$missing" -eq 0 ]; then
    ok "every one of the $seen semantic-release step(s) under $workflows_dir has GH_TOKEN/GITHUB_TOKEN in its env"
  fi
}

run_checks() {
  local workflows_dir="$1"
  check_no_direct_push_to_main "$workflows_dir"
  check_semantic_release_steps_have_token "$workflows_dir"
  check_no_quoted_boolean_dry_run_comparison "$workflows_dir"
  check_release_yml_wiring "$workflows_dir/release.yml"
  check_coverage_study_wiring "$workflows_dir/coverage-study.yml"
  check_freshness_alarm_permissions "$workflows_dir/release-freshness.yml"
  check_merge_queue_servicer "$workflows_dir/bot-merge-queue.yml" \
    "$ROOT/tools/release/service_bot_merge_queue.sh" \
    "$ROOT/tools/release/open_release_pr.sh" \
    "$ROOT/tools/release/open_go_release_pr.sh" \
    "$workflows_dir/coverage-study.yml"
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

  # Negative control for check_no_quoted_boolean_dry_run_comparison: both
  # quoted spellings are caught, a step-OUTPUT comparison (always a real
  # string, never this bug) is not, and the bare-boolean form is not either.
  cat > "$tmp/workflows/bad-dryrun1.yml" <<'EOF'
name: bad-dryrun1
jobs:
  x:
    if: inputs.dry_run == 'false'
    steps:
      - run: echo hi
EOF
  cat > "$tmp/workflows/bad-dryrun2.yml" <<'EOF'
name: bad-dryrun2
jobs:
  x:
    steps:
      - if: inputs.dry_run == 'true'
        run: echo hi
EOF
  cat > "$tmp/workflows/good-dryrun.yml" <<'EOF'
name: good-dryrun
jobs:
  x:
    steps:
      - if: steps.cfg.outputs.dry_run == 'false'
        run: echo hi
      - if: inputs.dry_run
        run: echo hi
      - if: ${{ !inputs.dry_run }}
        run: echo hi
EOF

  pass=0
  fail=0
  check_no_quoted_boolean_dry_run_comparison "$tmp/workflows"
  local dryrun_pass=$pass dryrun_fail=$fail
  if [ "$dryrun_fail" -eq 2 ] && [ "$dryrun_pass" -eq 0 ]; then
    echo "PASS  self-test: negative control — both quoted inputs.dry_run spellings are caught, the clean file reports no failure line"
  else
    echo "FAIL  self-test: negative control — quoted inputs.dry_run comparisons (got pass=$dryrun_pass fail=$dryrun_fail, want pass=0 fail=2)"
  fi

  rm -f "$tmp/workflows/bad-dryrun1.yml" "$tmp/workflows/bad-dryrun2.yml"
  pass=0
  fail=0
  check_no_quoted_boolean_dry_run_comparison "$tmp/workflows"
  local dryrunclean_pass=$pass dryrunclean_fail=$fail
  if [ "$dryrunclean_fail" -eq 0 ] && [ "$dryrunclean_pass" -eq 1 ]; then
    echo "PASS  self-test: negative control — the clean inputs.dry_run file alone passes (step-output and bare-boolean forms are not flagged)"
  else
    echo "FAIL  self-test: negative control — the clean inputs.dry_run file alone passes (got pass=$dryrunclean_pass fail=$dryrunclean_fail)"
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

  # Negative controls for check_merge_queue_servicer: a servicer whose list
  # drifted from the callers', and a workflow that is no longer scheduled,
  # are each caught; the matching pair passes.
  cat > "$tmp/servicer.sh" <<'EOF'
REQUIRED_CHECK_WORKFLOWS=(ci.yml regression-gates.yml)
EOF
  cat > "$tmp/servicer-drifted.sh" <<'EOF'
REQUIRED_CHECK_WORKFLOWS=(ci.yml)
EOF
  cat > "$tmp/caller.sh" <<'EOF'
"$HERE/open_bot_pr.sh" \
  --branch release/next \
  --dispatch ci.yml \
  --dispatch regression-gates.yml \
  --merge-method squash
EOF
  cat > "$tmp/good-servicer.yml" <<'EOF'
on:
  schedule:
    - cron: "*/5 * * * *"
jobs:
  service:
    permissions:
      actions: write
    steps:
      - run: bash tools/release/service_bot_merge_queue.sh
EOF
  cat > "$tmp/unscheduled-servicer.yml" <<'EOF'
on:
  workflow_dispatch:
jobs:
  service:
    permissions:
      actions: write
    steps:
      - run: bash tools/release/service_bot_merge_queue.sh
EOF

  pass=0
  fail=0
  check_merge_queue_servicer "$tmp/good-servicer.yml" "$tmp/servicer.sh" "$tmp/caller.sh"
  local goodsvc_pass=$pass goodsvc_fail=$fail
  if [ "$goodsvc_fail" -eq 0 ] && [ "$goodsvc_pass" -eq 4 ]; then
    echo "PASS  self-test: negative control — a scheduled servicer whose list matches the caller passes"
  else
    echo "FAIL  self-test: negative control — a scheduled servicer whose list matches the caller passes (got pass=$goodsvc_pass fail=$goodsvc_fail, want pass=4 fail=0)"
  fi

  pass=0
  fail=0
  check_merge_queue_servicer "$tmp/good-servicer.yml" "$tmp/servicer-drifted.sh" "$tmp/caller.sh"
  local driftsvc_fail=$fail
  if [ "$driftsvc_fail" -eq 1 ]; then
    echo "PASS  self-test: negative control — a servicer dispatching fewer workflows than the caller is caught"
  else
    echo "FAIL  self-test: negative control — a servicer dispatching fewer workflows than the caller is caught (got fail=$driftsvc_fail, want 1)"
  fi

  pass=0
  fail=0
  check_merge_queue_servicer "$tmp/unscheduled-servicer.yml" "$tmp/servicer.sh" "$tmp/caller.sh"
  local unschedsvc_fail=$fail
  if [ "$unschedsvc_fail" -eq 1 ]; then
    echo "PASS  self-test: negative control — an unscheduled servicer workflow is caught"
  else
    echo "FAIL  self-test: negative control — an unscheduled servicer workflow is caught (got fail=$unschedsvc_fail, want 1)"
  fi

  # Negative control: a semantic-release step with no token anywhere (the exact
  # shape of release.yml's rehearsal step before this guard) must be caught; a
  # step-level and a job-level token must each satisfy it.
  mkdir -p "$tmp/semrel-bad" "$tmp/semrel-good"
  cat > "$tmp/semrel-bad/release.yml" <<'EOF'
name: bad
jobs:
  release:
    steps:
      - name: Rehearsal
        run: node tools/release/compute_next_release.mjs
EOF
  cat > "$tmp/semrel-good/release.yml" <<'EOF'
name: good
jobs:
  release:
    steps:
      - name: Rehearsal
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: node tools/release/compute_next_release.mjs
  go:
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - run: bash tools/release/open_go_release_pr.sh
EOF
  pass=0
  fail=0
  check_semantic_release_steps_have_token "$tmp/semrel-bad"
  local semrelbad_fail=$fail semrelbad_pass=$pass
  if [ "$semrelbad_fail" -eq 1 ] && [ "$semrelbad_pass" -eq 0 ]; then
    echo "PASS  self-test: negative control — a semantic-release step with no GitHub token is caught"
  else
    echo "FAIL  self-test: negative control — a semantic-release step with no GitHub token is caught (got pass=$semrelbad_pass fail=$semrelbad_fail, want pass=0 fail=1)"
  fi
  pass=0
  fail=0
  check_semantic_release_steps_have_token "$tmp/semrel-good"
  local semrelgood_fail=$fail semrelgood_pass=$pass
  if [ "$semrelgood_fail" -eq 0 ] && [ "$semrelgood_pass" -eq 1 ]; then
    echo "PASS  self-test: negative control — step-level and job-level tokens both satisfy the check"
  else
    echo "FAIL  self-test: negative control — step-level and job-level tokens both satisfy the check (got pass=$semrelgood_pass fail=$semrelgood_fail, want pass=1 fail=0)"
  fi

  [ "$real_fail" -eq 0 ] && [ "$neg_fail" -eq 2 ] && [ "$neg_pass" -eq 0 ] && [ "$cleanonly_fail" -eq 0 ] &&
    [ "$semrelbad_fail" -eq 1 ] && [ "$semrelbad_pass" -eq 0 ] && [ "$semrelgood_fail" -eq 0 ] && [ "$semrelgood_pass" -eq 1 ] &&
    [ "$dryrun_fail" -eq 2 ] && [ "$dryrun_pass" -eq 0 ] && [ "$dryrunclean_fail" -eq 0 ] && [ "$dryrunclean_pass" -eq 1 ] &&
    [ "$badfresh_fail" -eq 2 ] && [ "$badfresh_pass" -eq 0 ] && [ "$goodfresh_fail" -eq 0 ] && [ "$goodfresh_pass" -eq 2 ] &&
    [ "$goodsvc_fail" -eq 0 ] && [ "$goodsvc_pass" -eq 4 ] && [ "$driftsvc_fail" -eq 1 ] && [ "$unschedsvc_fail" -eq 1 ]
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
