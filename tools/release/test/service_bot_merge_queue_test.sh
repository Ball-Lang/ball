#!/usr/bin/env bash
# Self-test for tools/release/service_bot_merge_queue.sh (PR #881 review
# round 3, finding 1: a merge-queue entry ENQUEUED by `GITHUB_TOKEN` gets no
# `merge_group` workflow runs, so its required checks never report).
#
# Runs the REAL script against a stub `gh` on PATH that answers the three API
# reads (the merge-queue GraphQL query, the gh-readonly-queue ref listing, the
# per-workflow run listing) from fixture files, and logs every `workflow run`
# dispatch instead of performing it. The script parses those answers with the
# real `jq`, so its filters are exercised here, not hidden inside `gh --jq`.
# Zero network, zero real credentials.
#
#   bash tools/release/test/service_bot_merge_queue_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../service_bot_merge_queue.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
no() { fail=$((fail + 1)); echo "FAIL  $1"; }

HEAD_SHA="1111111111111111111111111111111111111111"
STALE_SHA="2222222222222222222222222222222222222222"
BASE_SHA="3333333333333333333333333333333333333333"
QUEUE_BRANCH="gh-readonly-queue/main/pr-912-$BASE_SHA"

STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$1 $2" in
  "api graphql")
    if [ -n "${STUB_GRAPHQL_FAIL:-}" ]; then
      echo "gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2
      exit 1
    fi
    cat "${STUB_QUEUE_JSON:?}"
    ;;
  "workflow run") ;;
  *)
    case "$2" in
      repos/*/git/matching-refs/*) cat "${STUB_REFS_JSON:?}" ;;
      repos/*/rules/branches/*) printf '%s' "${STUB_RULES_JSON:-[]}" ;;
      repos/*/actions/workflows/*/runs*)
        wf="${2#*/actions/workflows/}"
        wf="${wf%%/runs*}"
        if [ -f "${STUB_RUNS_DIR:?}/$wf.json" ]; then
          cat "$STUB_RUNS_DIR/$wf.json"
        else
          printf '{"total_count":0,"workflow_runs":[]}'
        fi
        ;;
      *)
        echo "stub gh: unexpected invocation: $*" >&2
        exit 99
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/gh"

GH_LOG="$WORKDIR/gh.log"
RUNS_DIR="$WORKDIR/runs"
mkdir -p "$RUNS_DIR"

# $1: JSON array of merge-queue entry nodes, or the literal `null` for "no
# merge queue configured on this branch".
write_queue() {
  if [ "$1" = "null" ]; then
    printf '{"data":{"repository":{"mergeQueue":null}}}' > "$WORKDIR/queue.json"
  else
    printf '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":%s}}}}}' "$1" > "$WORKDIR/queue.json"
  fi
}

# One entry node. $1 PR number, $2 state, $3 enqueuer login, $4 head oid,
# $5 the merge group commit's date (default: long past the servicer's grace),
# $6 the PR author's login (default: a human).
OLD_DATE="2026-01-01T00:00:00Z"
entry() {
  printf '{"state":"%s","enqueuer":{"login":"%s"},"headCommit":{"oid":"%s","committedDate":"%s"},"pullRequest":{"number":%s,"author":{"login":"%s"},"autoMergeRequest":null}}' \
    "$2" "$3" "$4" "${5:-$OLD_DATE}" "$1" "${6:-ahmednfwela}"
}

# Two refs under the PR's queue prefix: the live merge group (HEAD_SHA) and a
# stale one left by an earlier build of the same entry (STALE_SHA). Only the
# one whose object IS the entry's head commit may be dispatched to.
printf '[{"ref":"refs/heads/gh-readonly-queue/main/pr-912-%s","object":{"sha":"%s"}},{"ref":"refs/heads/%s","object":{"sha":"%s"}}]' \
  "4444444444444444444444444444444444444444" "$STALE_SHA" "$QUEUE_BRANCH" "$HEAD_SHA" > "$WORKDIR/refs.json"

run_service() {
  PATH="$STUBDIR:$PATH" GH_REPO="test-owner/test-repo" GH_LOG="$GH_LOG" \
    STUB_QUEUE_JSON="$WORKDIR/queue.json" STUB_REFS_JSON="$WORKDIR/refs.json" \
    STUB_RUNS_DIR="$RUNS_DIR" STUB_GRAPHQL_FAIL="${STUB_GRAPHQL_FAIL:-}" \
    STUB_RULES_JSON="${STUB_RULES_JSON:-[]}" \
    bash "$SCRIPT" "$@"
}

reset() {
  : > "$GH_LOG"
  rm -f "$RUNS_DIR"/*.json
}

# `grep -c` prints 0 AND exits 1 on no match; that is the expected "nothing
# dispatched" answer here, named rather than swallowed.
dispatches() {
  local n
  n="$(grep -c '^workflow run ' "$GH_LOG")" || n=0
  printf '%s\n' "$n"
}

# ── Test 1: no merge queue on the branch -> nothing to service, exit 0 ────
reset
write_queue null
if run_service > "$WORKDIR/log1.txt" 2>&1; then
  if [ "$(dispatches)" = "0" ]; then
    ok "no merge queue configured -> exit 0, nothing dispatched"
  else
    no "no merge queue configured -> nothing dispatched (log: $(cat "$GH_LOG"))"
  fi
else
  no "no merge queue configured -> exit 0 ($(cat "$WORKDIR/log1.txt"))"
fi

# ── Test 1b: GraphQL says "no queue" but the branch's rules REQUIRE one ─────
#    -> the token cannot see the queue: FAIL LOUD, never "nothing to do" ─────
reset
write_queue null
if STUB_RULES_JSON='[{"type":"required_status_checks"},{"type":"merge_queue"}]' \
  run_service > "$WORKDIR/log1b.txt" 2>&1; then
  no "null mergeQueue but a merge_queue rule -> must exit non-zero (exited 0: $(cat "$WORKDIR/log1b.txt"))"
else
  if grep -q "::error::" "$WORKDIR/log1b.txt" && [ "$(dispatches)" = "0" ]; then
    ok "null mergeQueue but a merge_queue rule -> exit non-zero with ::error:: (an unreadable queue is not an absent one)"
  else
    no "null mergeQueue but a merge_queue rule -> ::error:: and nothing dispatched (out: $(cat "$WORKDIR/log1b.txt"))"
  fi
fi

# ── Test 2: a HUMAN-enqueued entry is left alone — its merge_group runs fire
reset
write_queue "[$(entry 905 AWAITING_CHECKS ahmednfwela "$HEAD_SHA")]"
if run_service > "$WORKDIR/log2.txt" 2>&1; then
  if [ "$(dispatches)" = "0" ]; then
    ok "human-enqueued AWAITING_CHECKS entry -> nothing dispatched"
  else
    no "human-enqueued AWAITING_CHECKS entry -> nothing dispatched (log: $(cat "$GH_LOG"))"
  fi
else
  no "human-enqueued AWAITING_CHECKS entry -> exit 0 ($(cat "$WORKDIR/log2.txt"))"
fi

# ── Test 3: a BOT-enqueued entry with no runs on its head -> both required-
#    check workflows dispatched on the merge group's own branch ────────────
reset
write_queue "[$(entry 905 AWAITING_CHECKS ahmednfwela "$STALE_SHA"),$(entry 912 AWAITING_CHECKS github-actions "$HEAD_SHA")]"
if run_service > "$WORKDIR/log3.txt" 2>&1; then
  if grep -qxF "workflow run ci.yml --repo test-owner/test-repo --ref $QUEUE_BRANCH" "$GH_LOG" &&
    grep -qxF "workflow run regression-gates.yml --repo test-owner/test-repo --ref $QUEUE_BRANCH" "$GH_LOG"; then
    ok "bot-enqueued entry, no runs -> ci.yml + regression-gates.yml dispatched on $QUEUE_BRANCH"
  else
    no "bot-enqueued entry, no runs -> both workflows dispatched on $QUEUE_BRANCH (log: $(cat "$GH_LOG"))"
  fi
  if [ "$(dispatches)" = "2" ]; then
    ok "bot-enqueued entry -> exactly two dispatches (the human entry ahead of it untouched)"
  else
    no "bot-enqueued entry -> exactly two dispatches (got $(dispatches), log: $(cat "$GH_LOG"))"
  fi
  if grep -q "head_sha=$HEAD_SHA" "$GH_LOG"; then
    ok "bot-enqueued entry -> existing runs looked up by the merge group's HEAD sha"
  else
    no "bot-enqueued entry -> existing runs looked up by the merge group's HEAD sha (log: $(cat "$GH_LOG"))"
  fi
else
  no "bot-enqueued entry, no runs -> exit 0 ($(cat "$WORKDIR/log3.txt"))"
fi

# ── Test 4: idempotent — a live run is kept; a CANCELLED run is not a run ──
reset
write_queue "[$(entry 912 AWAITING_CHECKS github-actions "$HEAD_SHA")]"
printf '{"total_count":1,"workflow_runs":[{"status":"in_progress","conclusion":null}]}' > "$RUNS_DIR/ci.yml.json"
printf '{"total_count":1,"workflow_runs":[{"status":"completed","conclusion":"cancelled"}]}' > "$RUNS_DIR/regression-gates.yml.json"
if run_service > "$WORKDIR/log4.txt" 2>&1; then
  if ! grep -q "^workflow run ci.yml " "$GH_LOG"; then
    ok "ci.yml already running on the merge group head -> not dispatched again"
  else
    no "ci.yml already running on the merge group head -> not dispatched again (log: $(cat "$GH_LOG"))"
  fi
  if grep -qxF "workflow run regression-gates.yml --repo test-owner/test-repo --ref $QUEUE_BRANCH" "$GH_LOG"; then
    ok "regression-gates.yml's only run was cancelled -> dispatched again"
  else
    no "regression-gates.yml's only run was cancelled -> dispatched again (log: $(cat "$GH_LOG"))"
  fi
else
  no "partially-serviced bot entry -> exit 0 ($(cat "$WORKDIR/log4.txt"))"
fi

# ── Test 5: bot entries not awaiting checks need nothing ──────────────────
reset
write_queue "[$(entry 912 QUEUED github-actions "$HEAD_SHA"),$(entry 913 MERGEABLE github-actions "$STALE_SHA")]"
if run_service > "$WORKDIR/log5.txt" 2>&1; then
  if [ "$(dispatches)" = "0" ]; then
    ok "bot entries QUEUED / MERGEABLE -> nothing dispatched"
  else
    no "bot entries QUEUED / MERGEABLE -> nothing dispatched (log: $(cat "$GH_LOG"))"
  fi
else
  no "bot entries QUEUED / MERGEABLE -> exit 0 ($(cat "$WORKDIR/log5.txt"))"
fi

# ── Test 6: no ref carries the entry's head -> FAIL LOUD, dispatch nothing ─
reset
write_queue "[$(entry 912 AWAITING_CHECKS github-actions "5555555555555555555555555555555555555555")]"
if run_service > "$WORKDIR/log6.txt" 2>&1; then
  no "no gh-readonly-queue ref at the entry's head -> must exit non-zero (exited 0: $(cat "$WORKDIR/log6.txt"))"
else
  if grep -q "::error::" "$WORKDIR/log6.txt" && [ "$(dispatches)" = "0" ]; then
    ok "no gh-readonly-queue ref at the entry's head -> exit non-zero with ::error::, nothing dispatched"
  else
    no "no gh-readonly-queue ref at the entry's head -> ::error:: and nothing dispatched (out: $(cat "$WORKDIR/log6.txt"); gh: $(cat "$GH_LOG"))"
  fi
fi

# ── Test 7: --dry-run reports what it would dispatch and dispatches nothing ─
reset
write_queue "[$(entry 912 AWAITING_CHECKS github-actions "$HEAD_SHA")]"
if run_service --dry-run > "$WORKDIR/log7.txt" 2>&1; then
  if [ "$(dispatches)" = "0" ] && grep -qF "would dispatch ci.yml on $QUEUE_BRANCH" "$WORKDIR/log7.txt"; then
    ok "--dry-run -> names the dispatch it would make, makes none"
  else
    no "--dry-run -> names the dispatch it would make, makes none (out: $(cat "$WORKDIR/log7.txt"); gh: $(cat "$GH_LOG"))"
  fi
else
  no "--dry-run -> exit 0 ($(cat "$WORKDIR/log7.txt"))"
fi

# ── Test 7b: a merge group built moments ago is left for one more tick ────
#    (any merge_group run GitHub does start registers within seconds; deciding
#    "no run is coming" before then could dispatch a duplicate) ─────────────
reset
write_queue "[$(entry 912 AWAITING_CHECKS github-actions "$HEAD_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")]"
if run_service > "$WORKDIR/log7b.txt" 2>&1; then
  if [ "$(dispatches)" = "0" ] && grep -qF "waiting 180s for any merge_group run to register" "$WORKDIR/log7b.txt"; then
    ok "bot merge group inside the grace window -> nothing dispatched yet, exit 0"
  else
    no "bot merge group inside the grace window -> nothing dispatched yet (out: $(cat "$WORKDIR/log7b.txt"); gh: $(cat "$GH_LOG"))"
  fi
else
  no "bot merge group inside the grace window -> exit 0 ($(cat "$WORKDIR/log7b.txt"))"
fi

# ── Test 7c: a bot-AUTHORED PR is serviced whoever the queue records as its
#    enqueuer — skipping it would leave it blocking the queue ──────────────
reset
write_queue "[$(entry 912 AWAITING_CHECKS ahmednfwela "$HEAD_SHA" "$OLD_DATE" github-actions)]"
if run_service > "$WORKDIR/log7c.txt" 2>&1; then
  if [ "$(dispatches)" = "2" ]; then
    ok "bot-authored PR with a non-bot enqueuer and no runs -> both workflows dispatched"
  else
    no "bot-authored PR with a non-bot enqueuer and no runs -> both workflows dispatched (log: $(cat "$GH_LOG"))"
  fi
else
  no "bot-authored PR with a non-bot enqueuer -> exit 0 ($(cat "$WORKDIR/log7c.txt"))"
fi

# ── Test 8: the queue query itself failing is an error, never "empty queue" ─
reset
write_queue "[]"
if STUB_GRAPHQL_FAIL=1 run_service > "$WORKDIR/log8.txt" 2>&1; then
  no "merge-queue query fails -> must exit non-zero (exited 0: $(cat "$WORKDIR/log8.txt"))"
else
  ok "merge-queue query fails -> exit non-zero (never read as an empty queue)"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
