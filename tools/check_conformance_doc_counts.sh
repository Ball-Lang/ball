#!/usr/bin/env bash
# Drift guard for the conformance-corpus total hard-coded in the docs (#519).
#
# WHY THIS EXISTS: every self-hosted engine's whole-corpus sweep prints the
# canonical `Results: <N> passed, 0 failed, <N> total` line, and that N is
# hand-copied as prose into CLAUDE.md, root AGENTS.md, every language's
# AGENTS.md, .claude/rules/*.md, README.md and even ci.yml's own comments.
# Nothing ever checked them. Each corpus-growing PR updated whichever files it
# happened to touch, so at the time this guard was written FOUR mutually
# inconsistent totals were live in the tree at once — and CLAUDE.md was not even
# self-consistent with itself. Docs that disagree about a measured fact are
# worse than docs with no number: a reader cannot tell which one is the lie.
#
# GROUND TRUTH IS DERIVED, NOT VOTED ON. A consistency-only lint ("all the docs
# agree") cannot tell "all the docs are right" from "all the docs are equally
# wrong" — so this guard computes N mechanically from the repo itself:
#
#     N = the number of tests/conformance/*.ball.json fixtures that have a
#         sibling *.expected_output.txt golden
#
# which is exactly what every engine's runner sweeps; the golden-less fixtures
# are the documented resource-limit/sandbox carve-outs those runners skip (the
# "(K skipped carve-outs)" suffix in the same line). This derivation was
# verified against a real CI measurement before being wired: at main@b16473a6
# the derived value and the `Results:` line printed by all four of the Rust, Go,
# C# and Python jobs in run 33706063554 agreed exactly.
#
# SCOPE — deliberately only the PARITY line, `<A> passed, 0 failed, <B> total`,
# which is a claim about the CURRENT corpus. Deliberately NOT matched:
#   * lines with a nonzero failure count (`246 passed, 74 failed, 320 total`) —
#     those are per-leg measurements (the C# compiler leg, the round-trip legs,
#     the honest zero baselines). Their totals are stale too, but "fixing" them
#     by editing the number would fabricate a measurement nobody re-ran.
#   * CHANGELOG.md — an append-only release log; rewriting it falsifies history.
#   * the degenerate `0 passed, 0 failed, 0 total` sentinel, quoted verbatim in
#     publish-crates/nuget/pypi.yml's comments as the "a sweep that executed
#     NOTHING must not green-light a publish" failure mode those gates exist to
#     reject (#439/#444). It is a quoted counter-example, never a corpus claim —
#     and the corpus is never empty, which this guard itself asserts below.
#   * any occurrence whose line carries the marker `corpus-count: historical`,
#     for phase-log narrative that correctly describes a past moment.
# Every carve-out is reported in the summary, so silently growing the ignore
# list is visible in the CI log.
#
# Usage:
#   bash tools/check_conformance_doc_counts.sh            # gate the repo
#   bash tools/check_conformance_doc_counts.sh --root DIR # a synthetic tree
#   bash tools/check_conformance_doc_counts.sh --expect N # override the
#                                                         # derivation
# Exits 0 when every current-status occurrence equals N; 1 otherwise, printing
# every offending file:line. Dependency-free (bash + awk + git/find), so it runs
# in ci.yml's always-on `proto` job with no toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
EXPECT=""
HISTORICAL_MARKER='corpus-count: historical'

while [ $# -gt 0 ]; do
  case "$1" in
  --root)
    ROOT="$2"
    shift 2
    ;;
  --root=*)
    ROOT="${1#--root=}"
    shift
    ;;
  --expect)
    EXPECT="$2"
    shift 2
    ;;
  --expect=*)
    EXPECT="${1#--expect=}"
    shift
    ;;
  *)
    echo "::error::unknown argument '$1'"
    exit 1
    ;;
  esac
done

[ -d "$ROOT" ] || {
  echo "::error::--root '$ROOT' is not a directory"
  exit 1
}
ROOT="$(cd "$ROOT" && pwd)"

# ── Ground truth ──────────────────────────────────────────────────────────
FIXTURE_DIR="$ROOT/tests/conformance"
golden_having=0
golden_less=0
if [ -d "$FIXTURE_DIR" ]; then
  for fixture in "$FIXTURE_DIR"/*.ball.json; do
    [ -e "$fixture" ] || continue
    if [ -f "${fixture%.ball.json}.expected_output.txt" ]; then
      golden_having=$((golden_having + 1))
    else
      golden_less=$((golden_less + 1))
    fi
  done
fi

if [ -n "$EXPECT" ]; then
  case "$EXPECT" in
  '' | *[!0-9]*)
    echo "::error::--expect must be a non-negative integer, got '$EXPECT'"
    exit 1
    ;;
  esac
  expected="$EXPECT"
  derivation="--expect override"
else
  if [ "$golden_having" -lt 1 ]; then
    # Fail loud rather than "gate" against a corpus size of zero — a moved or
    # renamed fixture directory must not turn this into a no-op that passes.
    echo "::error::no golden-having fixtures found under $FIXTURE_DIR — cannot derive the corpus total"
    exit 1
  fi
  expected="$golden_having"
  derivation="$golden_having of $((golden_having + golden_less)) tests/conformance/*.ball.json fixtures have a sibling .expected_output.txt golden ($golden_less golden-less carve-outs)"
fi

# ── The files to scan ─────────────────────────────────────────────────────
# Tracked markdown + workflow YAML: the docs plus ci.yml's own explanatory
# comments, which drifted exactly like the prose did.
list_files() {
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" ls-files -z -- '*.md' '*.yml' '*.yaml'
  else
    # Synthetic trees (the unit test) are not git repos.
    find "$ROOT" \( -name '*.md' -o -name '*.yml' -o -name '*.yaml' \) -type f -print0 |
      while IFS= read -r -d '' abs; do printf '%s\0' "${abs#"$ROOT/"}"; done
  fi
}

is_excluded() {
  case "$1" in
  CHANGELOG.md | */CHANGELOG.md) return 0 ;;
  esac
  return 1
}

# ── The scan ──────────────────────────────────────────────────────────────
# The parity line wraps across a newline in several files (a paragraph break
# lands between `... passed,` and `0 failed, ...`), so each line is matched
# joined with its successor; a match is attributed to the line it STARTS on, and
# a match starting past the first line's end is left for that line's own turn.
scan_file() {
  awk -v marker="$HISTORICAL_MARKER" '
    { line[NR] = $0 }
    END {
      re = "[0-9]+[ \t]+passed,[ \t]+0[ \t]+failed,[ \t]+[0-9]+[ \t]+total"
      for (i = 1; i <= NR; i++) {
        s = line[i]
        joined = (i < NR)
        if (joined) s = s " " line[i + 1]
        limit = length(line[i])
        off = 0
        rest = s
        while (match(rest, re)) {
          start = off + RSTART
          if (start <= limit) {
            hit = substr(rest, RSTART, RLENGTH)
            kind = "check"
            if (index(line[i], marker) > 0) kind = "historical"
            else if (joined && index(line[i + 1], marker) > 0) kind = "historical"
            print kind "\t" i "\t" hit
          }
          off = off + RSTART + RLENGTH - 1
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
    }
  ' "$1"
}

checked=0
historical=0
sentinel=0
offenders=""

while IFS= read -r -d '' rel; do
  is_excluded "$rel" && continue
  abs="$ROOT/$rel"
  [ -f "$abs" ] || continue
  while IFS=$'\t' read -r kind lineno hit; do
    [ -n "${kind:-}" ] || continue
    if [ "$kind" = "historical" ]; then
      historical=$((historical + 1))
      continue
    fi
    got_passed="${hit%% *}"
    got_total="$(printf '%s' "$hit" | awk '{ print $(NF - 1) }')"
    if [ "$got_passed" -eq 0 ] && [ "$got_total" -eq 0 ]; then
      sentinel=$((sentinel + 1))
      continue
    fi
    checked=$((checked + 1))
    if [ "$got_passed" != "$expected" ] || [ "$got_total" != "$expected" ]; then
      offenders="${offenders}${rel}:${lineno}: ${hit}"$'\n'
    fi
  done < <(scan_file "$abs")
done < <(list_files)

echo "conformance-count drift guard: expected total $expected ($derivation)"
echo "  occurrences checked: $checked"
echo "  historical occurrences skipped ('$HISTORICAL_MARKER'): $historical"
echo "  '0 passed, 0 failed, 0 total' sentinel quotes skipped: $sentinel"

# Positive floor: an exit code plus an empty offender list cannot tell "every
# doc agrees" from "the pattern stopped matching and nothing was scanned".
if [ "$checked" -lt 1 ]; then
  echo "::error::the conformance-count guard scanned zero current-status occurrences — the docs stopped stating the total, or the pattern drifted"
  exit 1
fi

if [ -n "$offenders" ]; then
  echo "::error::conformance-corpus total drift: these occurrences disagree with the derived total $expected"
  printf '%s' "$offenders" | sed 's/^/  /'
  echo "  fix: update each line to the derived total, or (for phase-log narrative describing a past moment) mark the line '$HISTORICAL_MARKER'"
  exit 1
fi

echo "conformance-count drift guard: OK"
