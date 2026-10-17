#!/usr/bin/env bash
# Dispatch the required checks for merge-queue entries that `GITHUB_TOKEN`
# enqueued (PR #881 review round 3, finding 1 — issues #755/#879).
#
# WHY THIS EXISTS. `main` requires a merge queue (ruleset 17056238's
# `merge_queue` rule, #756). The bot PRs tools/release/open_bot_pr.sh opens —
# the root release PR, the Go release PR, the coverage-study table PR — arm
# auto-merge with this repo's `GITHUB_TOKEN` (there is no App or PAT
# credential), so once their own dispatched checks pass, GitHub enqueues them
# ON BEHALF OF `github-actions`. A merge group created that way gets ZERO
# workflow runs: its `merge_group` "checks_requested" event is an event the
# `GITHUB_TOKEN` triggered, and GitHub's recursion guard creates no run for
# those (https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow
# — only `workflow_dispatch`/`repository_dispatch` are exempt). Measured
# elsewhere, not assumed: dork-labs/dorkos recorded a GITHUB_TOKEN-enqueued
# queue branch with 0 workflow runs next to a human-enqueued one with 4
# (their merge-tail.yml), and verbara/Verbara.Sdk#24 and
# duckduckgo/content-scope-scripts#2750 both diagnosed entries stuck at
# AWAITING_CHECKS for the same reason. Such an entry never reports its
# required contexts, waits out the queue's `check_response_timeout`
# (90 minutes here), is evicted — and BLOCKS EVERY ENTRY BEHIND IT for that
# whole time, because the queue merges strictly in order.
#
# THE FIX, without a new credential: the same exemption open_bot_pr.sh already
# uses for the bot branch itself. `workflow_dispatch` is exempt from the
# recursion guard, and a required status check is matched by (context name,
# commit SHA) whichever event produced it — the model GitHub documents for
# third-party CI on merge groups, which reports against the
# `gh-readonly-queue/<base>/pr-<N>-<sha>` branch the queue pushes
# (https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue#triggering-merge-group-checks-with-third-party-ci-providers).
# So for every entry ENQUEUED BY the GitHub Actions bot that is
# AWAITING_CHECKS, this dispatches the two workflows that own all 19 required
# contexts onto that entry's own queue branch, unless a live run already
# exists on the entry's head commit. Correct under BOTH hypotheses: if GitHub
# ever does start merge_group runs for such an entry, they are found by that
# head-SHA lookup and nothing is dispatched twice.
#
# Human-enqueued entries are never touched — their merge_group runs start
# normally. Run every 5 minutes by .github/workflows/bot-merge-queue.yml.
#
# Exit status: 0 when every bot entry awaiting checks was serviced (or none
# needed it); non-zero when the queue could not be read — including a null
# queue on a branch whose rules require one — or an entry awaiting checks has
# no queue branch at its head commit. Never "nothing to do" for any of those.
#
# Usage:
#   bash tools/release/service_bot_merge_queue.sh [--dry-run] [--base <branch>]
#
# Requires `gh` (GH_TOKEN with actions: write to dispatch; contents: read and
# pull-requests: read to read the queue) and `jq`. GH_REPO overrides the repo.
set -euo pipefail

BASE="main"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --base) BASE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: service_bot_merge_queue.sh [--dry-run] [--base <branch>]"
      exit 0
      ;;
    *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
  esac
done

# The two workflows that own all 19 required contexts of ruleset 17056238 —
# the same pair every open_bot_pr.sh caller passes as `--dispatch` for the
# bot branch itself (tools/release/check_release_pr_wiring.sh keeps the two
# lists identical).
REQUIRED_CHECK_WORKFLOWS=(ci.yml regression-gates.yml)

# GraphQL spells the GitHub Actions bot actor `github-actions` (REST:
# `github-actions[bot]`); both are accepted.
BOT_LOGINS_JSON='["github-actions","github-actions[bot]"]'

REPO="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

# A native Windows jq.exe ends its text output with CRLF, which would leave a
# `\r` on every SHA compared below; strip it so the script (and its self-test)
# behave the same on a developer's Git Bash as on the Linux runner. `pipefail`
# still propagates a jq failure.
jqr() { jq "$@" | tr -d '\r'; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# A failing query aborts the run here (`set -e`): an unreadable queue is an
# error, never an empty one.
gh api graphql -F owner="${REPO%%/*}" -F name="${REPO#*/}" -F branch="$BASE" -f query='
query($owner: String!, $name: String!, $branch: String!) {
  repository(owner: $owner, name: $name) {
    mergeQueue(branch: $branch) {
      entries(first: 100) {
        nodes { state enqueuer { login } headCommit { oid } pullRequest { number } }
      }
    }
  }
}' > "$WORKDIR/queue.json"

# A `null` mergeQueue is ambiguous: GraphQL answers the same for "this branch
# has no queue" and for "this token cannot see it". Reading the latter as the
# former would turn this servicer green while a bot entry blocks the queue, so
# a null is cross-checked against the branch's effective rules (readable by
# any token with metadata access, unlike the ruleset itself).
if jq -e '.data.repository.mergeQueue == null' "$WORKDIR/queue.json" > /dev/null; then
  gh api "repos/$REPO/rules/branches/$BASE" > "$WORKDIR/rules.json"
  if jq -e 'any(.[]; .type == "merge_queue")' "$WORKDIR/rules.json" > /dev/null; then
    echo "::error::$BASE's rules require a merge queue, but the GraphQL mergeQueue for $REPO/$BASE is null — this token cannot read the queue, so bot-enqueued entries cannot be serviced"
    exit 1
  fi
  echo "service_bot_merge_queue: $REPO has no merge queue on $BASE — auto-merge lands bot PRs directly, nothing to service"
  exit 0
fi

# "<pr> <state> <head oid>" for every entry the GitHub Actions bot enqueued.
jqr -r --argjson bots "$BOT_LOGINS_JSON" '
  .data.repository.mergeQueue.entries.nodes[]
  | select((.enqueuer.login // "") as $who | $bots | index($who))
  | "\(.pullRequest.number) \(.state) \(.headCommit.oid // "")"
' "$WORKDIR/queue.json" > "$WORKDIR/bot_entries.txt"

if [ ! -s "$WORKDIR/bot_entries.txt" ]; then
  echo "service_bot_merge_queue: no entry in $BASE's merge queue was enqueued by the GitHub Actions bot — nothing to service"
  exit 0
fi

dispatched=0
already=0
failures=0

# The loop reads the entries on stdin, so every `gh` call inside it reads
# /dev/null instead — a command that consumed stdin would otherwise silently
# swallow the remaining entries.
while read -r pr state oid; do
  if [ "$state" != "AWAITING_CHECKS" ]; then
    echo "PR #$pr: $state — no merge group awaiting checks, nothing to dispatch"
    continue
  fi
  if [ -z "$oid" ]; then
    echo "::error::PR #$pr is AWAITING_CHECKS but its merge-queue entry reports no head commit"
    failures=$((failures + 1))
    continue
  fi

  gh api "repos/$REPO/git/matching-refs/heads/gh-readonly-queue/$BASE/pr-$pr-" < /dev/null > "$WORKDIR/refs.json"
  branch="$(jqr -r --arg oid "$oid" \
    '[.[] | select(.object.sha == $oid) | .ref | sub("^refs/heads/"; "")] | first // ""' \
    "$WORKDIR/refs.json")"
  if [ -z "$branch" ]; then
    echo "::error::PR #$pr is AWAITING_CHECKS at $oid, but no gh-readonly-queue/$BASE/pr-$pr-* branch points at that commit — its required checks cannot be dispatched"
    failures=$((failures + 1))
    continue
  fi

  for wf in "${REQUIRED_CHECK_WORKFLOWS[@]}"; do
    gh api "repos/$REPO/actions/workflows/$wf/runs?head_sha=$oid&per_page=100" < /dev/null > "$WORKDIR/runs.json"
    # A CANCELLED run reports nothing, so it does not count as coverage.
    live="$(jqr '[.workflow_runs[] | select(.conclusion != "cancelled")] | length' "$WORKDIR/runs.json")"
    if [ "$live" -gt 0 ]; then
      echo "PR #$pr: $wf already has $live run(s) on merge group $oid — not dispatching again"
      already=$((already + 1))
    elif [ "$DRY_RUN" -eq 1 ]; then
      echo "PR #$pr: would dispatch $wf on $branch (dry run)"
    else
      echo "PR #$pr: dispatching $wf on $branch (merge group $oid)"
      gh workflow run "$wf" --repo "$REPO" --ref "$branch" < /dev/null
      dispatched=$((dispatched + 1))
    fi
  done
done < "$WORKDIR/bot_entries.txt"

echo "service_bot_merge_queue: dispatched=$dispatched already_running=$already failures=$failures"
[ "$failures" -eq 0 ]
