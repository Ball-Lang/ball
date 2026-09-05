#!/usr/bin/env bash
# Freshness guard for the pub.dev (Dart) release lane (#551).
#
# WHY THIS EXISTS: every release guard in this repo before it asserted
# REACHABILITY — that a channel's trigger chain *can* fire
# (`check_release_dispatch_wiring.sh`) or that the lane is shaped so it fires
# without a human (`check_pubdev_release_wiring.sh`). Neither can see the
# failure #551 actually reported: a perfectly-wired, perfectly-green lane that
# simply had not shipped since 2026-07-06, because its one manual step stopped
# happening. Nothing anywhere compared a REGISTRY's live state to `main`.
#
# This does. Two legs, both derived from the repo — no hardcoded package list,
# no hardcoded version:
#
#   drift    the version in dart/<pkg>/pubspec.yaml must equal pub.dev's
#            reported `latest.version`. A local version ahead of pub.dev means a
#            release commit landed and its publish never did; pub.dev ahead of
#            main means someone published out of band.
#
#   staleness  the newest commit touching dart/<pkg>/ must not be more than
#            MAX_STALE_DAYS newer than pub.dev's publish timestamp for
#            `latest.version`. This is the leg that catches a stalled lane: a
#            stalled lane holds its bumps OUTSIDE main (inside an unmerged
#            rolling release PR, as #272 did for two months), so the drift leg
#            keeps passing while consumers fall further behind. Version equality
#            alone is necessary and not sufficient.
#
# The staleness leg is deliberately generous. It is not "release on every
# commit" — it is "if this package's code has been moving for over a month and
# pub.dev has not, something is wrong and someone should look". Doc-only churn
# under a package directory can trip it; the fix in that case is to cut a
# release, which is now a merge away rather than a human merge of a rolling PR.
#
# WHERE IT RUNS: the network legs run on a schedule
# (.github/workflows/pubdev-freshness.yml, weekly + workflow_dispatch), NOT on
# every PR — a per-PR hard dependency on pub.dev's API would redden unrelated
# work on a registry hiccup, and pub.dev does not change between two pushes of
# the same PR anyway. The comparison logic is still PR-gated through
# `--self-test`, which drives every classification offline against synthetic
# fixtures (ci.yml's `Proto Checks` job) — so a guard that silently stopped
# comparing anything cannot reach main.
#
# Usage:
#   bash tools/release/check_pubdev_freshness.sh              # live check
#   bash tools/release/check_pubdev_freshness.sh --self-test  # offline, no network
#
# Env: MAX_STALE_DAYS (default 30)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MAX_STALE_DAYS="${MAX_STALE_DAYS:-30}"

PY="python3"
command -v "$PY" >/dev/null 2>&1 || PY="python"
command -v "$PY" >/dev/null 2>&1 || {
  echo "::error::neither python3 nor python is on PATH — this guard needs one to parse pub.dev JSON"
  exit 1
}

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "PASS  $1"
}

no() {
  fail=$((fail + 1))
  echo "FAIL  $1"
  shift
  local line
  for line in "$@"; do printf '  %s\n' "$line"; done
}

# ── The classification, in one place, so --self-test exercises exactly the code
#    the live run uses. Prints `<verdict>\t<detail>`; verdict is OK or STALE or
#    DRIFT or UNKNOWN.
#    Args: pkg local_version pubdev_version pubdev_published_iso last_commit_iso
classify() {
  MAX_STALE_DAYS="$MAX_STALE_DAYS" "$PY" - "$@" <<'PY'
import sys
from datetime import datetime, timezone
import os

pkg, local_v, pub_v, pub_published, last_commit = sys.argv[1:6]
max_days = int(os.environ["MAX_STALE_DAYS"])

def parse(ts):
    if not ts:
        return None
    ts = ts.strip().replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(ts)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)

if not pub_v:
    print(f"UNKNOWN\t{pkg}: pub.dev reported no latest version")
    sys.exit(0)
if not local_v:
    print(f"UNKNOWN\t{pkg}: no version: in the local pubspec.yaml")
    sys.exit(0)

# Exact string equality on purpose: pub.dev versions carry Dart build metadata
# (0.3.0+6), which semver comparison treats as equal to 0.3.0 and would hide a
# real mismatch. Two versions that differ at all are a mismatch worth a look.
if local_v != pub_v:
    print(f"DRIFT\t{pkg}: main has {local_v}, pub.dev serves {pub_v}")
    sys.exit(0)

published = parse(pub_published)
committed = parse(last_commit)
if published is None or committed is None:
    print(f"UNKNOWN\t{pkg}: missing publish ({pub_published!r}) or commit ({last_commit!r}) timestamp")
    sys.exit(0)

behind = (committed - published).days
if behind > max_days:
    print(
        f"STALE\t{pkg}: pub.dev serves {pub_v} published {published.date()}, "
        f"but dart/ code for it last changed {committed.date()} "
        f"({behind} days later, limit {max_days})"
    )
else:
    print(f"OK\t{pkg}: {pub_v} published {published.date()}, newest change {committed.date()} ({behind}d)")
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# Self-test: the comparison logic, offline, on synthetic inputs. Runs on every
# PR. A guard whose classifier silently stopped classifying would otherwise be
# indistinguishable from a healthy registry.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  echo "== self-test (offline; MAX_STALE_DAYS=$MAX_STALE_DAYS) =="
  expect() {
    local want="$1" label="$2"
    shift 2
    local got
    got="$(classify "$@" | cut -f1)"
    if [ "$got" = "$want" ]; then
      ok "$label -> $want"
    else
      no "$label -> $want" "classifier returned '$got'"
    fi
  }

  # A healthy package: versions equal, published after the last code change.
  expect OK "fresh package" \
    demo 1.2.3 1.2.3 2026-09-01T00:00:00Z 2026-09-02T00:00:00Z
  # The #551 shape: versions still equal (the bumps are stuck outside main), but
  # the package's code has moved on for two months.
  expect STALE "stalled lane (versions equal, code two months newer)" \
    demo 0.3.0+3 0.3.0+3 2026-07-03T18:00:00Z 2026-09-04T00:00:00Z
  # Exactly at the limit is not yet stale; one day past it is.
  expect OK "boundary: exactly MAX_STALE_DAYS behind" \
    demo 1.0.0 1.0.0 2026-08-01T00:00:00Z "$("$PY" -c "
import sys
from datetime import datetime, timedelta, timezone
print((datetime(2026,8,1,tzinfo=timezone.utc)+timedelta(days=int('$MAX_STALE_DAYS'))).isoformat())")"
  expect STALE "boundary: one day past MAX_STALE_DAYS" \
    demo 1.0.0 1.0.0 2026-08-01T00:00:00Z "$("$PY" -c "
import sys
from datetime import datetime, timedelta, timezone
print((datetime(2026,8,1,tzinfo=timezone.utc)+timedelta(days=int('$MAX_STALE_DAYS')+1)).isoformat())")"
  # A release commit landed on main but its publish never ran.
  expect DRIFT "local bump never published" \
    demo 0.4.0 0.3.0+3 2026-07-03T18:00:00Z 2026-09-04T00:00:00Z
  # Someone published from a laptop.
  expect DRIFT "pub.dev ahead of main" \
    demo 0.3.0 0.4.0 2026-09-01T00:00:00Z 2026-09-02T00:00:00Z
  # Missing data must never read as healthy.
  expect UNKNOWN "pub.dev returned no version" \
    demo 1.0.0 "" "" 2026-09-04T00:00:00Z
  expect UNKNOWN "unparseable timestamps" \
    demo 1.0.0 1.0.0 "not-a-date" 2026-09-04T00:00:00Z

  total=$((pass + fail))
  MIN=8
  case "$pass$fail$total" in
  *[!0-9]*)
    echo "::error::pub.dev freshness self-test produced a non-numeric tally"
    exit 1
    ;;
  esac
  if [ "$total" -lt "$MIN" ]; then
    echo "::error::pub.dev freshness self-test ran $total cases, expected at least $MIN — the sweep itself is broken"
    exit 1
  fi
  echo "Results: $pass passed, $fail failed, $total total"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Live check.
# ─────────────────────────────────────────────────────────────────────────────
echo "== pub.dev freshness (MAX_STALE_DAYS=$MAX_STALE_DAYS) =="

checked=0
for pubspec in "$ROOT"/dart/*/pubspec.yaml; do
  [ -f "$pubspec" ] || continue
  name="$(grep -m1 -E '^name:[[:space:]]*[A-Za-z0-9_]+' "$pubspec" | awk '{print $2}')"
  [ -n "$name" ] || continue
  grep -qE '^publish_to:[[:space:]]*none' "$pubspec" && continue
  local_v="$(grep -m1 -E '^version:[[:space:]]*\S+' "$pubspec" | awk '{print $2}')"
  dir="dart/$(basename "$(dirname "$pubspec")")"

  meta="$(curl -sSf --max-time 30 "https://pub.dev/api/packages/$name" 2>/dev/null |
    "$PY" -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('\t'); raise SystemExit(0)
latest = d.get('latest') or {}
print((latest.get('version') or '') + '\t' + (latest.get('published') or ''))
")"
  pub_v="$(printf '%s' "$meta" | cut -f1)"
  pub_at="$(printf '%s' "$meta" | cut -f2)"

  # Newest commit touching the package directory, from the repo itself.
  last_commit="$(git -C "$ROOT" log -1 --format=%cI -- "$dir" 2>/dev/null)"

  verdict="$(classify "$name" "$local_v" "$pub_v" "$pub_at" "$last_commit")"
  kind="$(printf '%s' "$verdict" | cut -f1)"
  detail="$(printf '%s' "$verdict" | cut -f2-)"
  checked=$((checked + 1))

  case "$kind" in
  OK) ok "$detail" ;;
  STALE)
    no "$name is not stale on pub.dev" "$detail" \
      "the release lane has not shipped this package while its code kept moving —" \
      "check .github/workflows/pubdev-release.yml's recent runs (#551)"
    ;;
  DRIFT)
    no "$name's published version matches main" "$detail" \
      "a bump on main that never published, or a publish that never landed on main"
    ;;
  *)
    no "$name could be evaluated" "$detail"
    ;;
  esac
done

total=$((pass + fail))
# Positive floor: with nine publishable packages, a sweep that evaluated fewer
# than five of them did not do its job — a curl that failed for every package
# would otherwise report a clean zero-failure run.
MIN=5
case "$pass$fail$total$checked" in
*[!0-9]*)
  echo "::error::pub.dev freshness guard produced a non-numeric tally"
  exit 1
  ;;
esac
if [ "$checked" -lt "$MIN" ]; then
  echo "::error::pub.dev freshness guard evaluated $checked packages, expected at least $MIN — the sweep itself is broken"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
