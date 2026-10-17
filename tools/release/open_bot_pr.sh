#!/usr/bin/env bash
# Shared helper: push the current (already-committed) HEAD to a bot branch,
# open-or-update a PR against `main`, dispatch the workflows that produce
# this repo's required status checks against that branch's head SHA, and arm
# auto-merge (issue #755 — "release via auto-merged PR").
#
# WHY NOT A PLAIN `git push origin HEAD:refs/heads/main`: the `Protect main`
# ruleset (17056238) requires 19 status checks on every push to `main` itself
# (added 2026-09-13), so a bot's direct push is rejected outright (GH013).
# This script is the ONE replacement for every workflow that used to push a
# bot commit straight to main — release.yml's semantic-release step and
# coverage-study.yml's "Publish coverage table" job both call it now.
#
# WHY `gh workflow run <file> --ref <branch>` GETS THE CHECKS RUNNING WITHOUT
# A GITHUB APP / PAT: GitHub's documented GITHUB_TOKEN recursion-protection
# ("events triggered by the GITHUB_TOKEN will not create a new workflow run")
# names exactly two exceptions — `workflow_dispatch` and `repository_dispatch`
# — and this is independently confirmed in the wild: a PR *opened* with
# GITHUB_TOKEN does NOT get its `pull_request`-triggered required checks run
# at all (see docs/RELEASE.md "Release via PR" for citations). So a bot PR's
# required contexts (ci.yml + regression-gates.yml's 19 job names) would never
# appear and the PR would hang forever. Dispatching those two workflows via
# `workflow_dispatch` on this branch IS the exempted path, and GitHub's
# required_status_checks rule matches by (context name, head SHA) regardless
# of which event produced the check run — the same mechanism that lets a
# human unblock a PR by re-running a required workflow manually.
#
# Usage:
#   open_bot_pr.sh --branch <name> --title <title> --body-file <path> \
#     [--dispatch <workflow.yml>]... \
#     [--merge-method squash|merge|rebase] \
#     [--merge-subject <text>] [--merge-body-file <path>]
#
# Requires: a git identity already configured, `HEAD` already committed on
# top of an up-to-date `main`, and `gh` authenticated with `contents: write`,
# `pull-requests: write` and `actions: write` (to dispatch the check
# workflows).
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: open_bot_pr.sh --branch <name> --title <title> --body-file <path>
         [--dispatch <workflow.yml>]...
         [--merge-method squash|merge|rebase]
         [--merge-subject <text>] [--merge-body-file <path>]
EOF
}

BRANCH=""
TITLE=""
BODY_FILE=""
MERGE_METHOD="squash"
MERGE_SUBJECT=""
MERGE_BODY_FILE=""
DISPATCH=()

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --dispatch) DISPATCH+=("$2"); shift 2 ;;
    --merge-method) MERGE_METHOD="$2"; shift 2 ;;
    --merge-subject) MERGE_SUBJECT="$2"; shift 2 ;;
    --merge-body-file) MERGE_BODY_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$BRANCH" ] || { echo "::error::--branch is required" >&2; exit 2; }
[ -n "$TITLE" ] || { echo "::error::--title is required" >&2; exit 2; }
[ -n "$BODY_FILE" ] || { echo "::error::--body-file is required" >&2; exit 2; }
[ -f "$BODY_FILE" ] || { echo "::error::--body-file $BODY_FILE does not exist" >&2; exit 2; }

case "$MERGE_METHOD" in
  squash) MERGE_FLAG="--squash" ;;
  merge) MERGE_FLAG="--merge" ;;
  rebase) MERGE_FLAG="--rebase" ;;
  *) echo "::error::--merge-method must be squash, merge or rebase, got: $MERGE_METHOD" >&2; exit 2 ;;
esac

REPO="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

echo "::group::push $BRANCH (force — bot-owned branch, rewritten each run)"
git push --force origin "HEAD:refs/heads/$BRANCH"
echo "::endgroup::"

EXISTING_PR="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // ""')"

if [ -z "$EXISTING_PR" ]; then
  echo "::group::open PR"
  PR_URL="$(gh pr create --repo "$REPO" --head "$BRANCH" --base main --title "$TITLE" --body-file "$BODY_FILE")"
  PR_NUM="${PR_URL##*/}"
  echo "opened $PR_URL"
  echo "::endgroup::"
else
  PR_NUM="$EXISTING_PR"
  echo "::group::update PR #$PR_NUM"
  gh pr edit "$PR_NUM" --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE"
  echo "::endgroup::"
fi

for wf in ${DISPATCH[@]+"${DISPATCH[@]}"}; do
  echo "::group::dispatch $wf on $BRANCH (produces this PR's required checks)"
  gh workflow run "$wf" --repo "$REPO" --ref "$BRANCH"
  echo "::endgroup::"
done

echo "::group::arm auto-merge on PR #$PR_NUM"
MERGE_ARGS=(pr merge "$PR_NUM" --repo "$REPO" --auto "$MERGE_FLAG")
[ -n "$MERGE_SUBJECT" ] && MERGE_ARGS+=(--subject "$MERGE_SUBJECT")
[ -n "$MERGE_BODY_FILE" ] && MERGE_ARGS+=(--body-file "$MERGE_BODY_FILE")
gh "${MERGE_ARGS[@]}"
echo "::endgroup::"

echo "pr_number=$PR_NUM"
