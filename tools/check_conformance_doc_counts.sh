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
# SCOPE — the PARITY line, `<A> passed, 0 failed, <B> total`, which is a claim
# about the CURRENT corpus, PLUS three sibling shapes (#831/#714/#716) that rot
# the exact same way for a leg/doc that is not at 100%. Deliberately NOT
# matched by the PARITY check:
#   * lines with a nonzero failure count (`246 passed, 74 failed, 320 total`)
#     as narrative prose (e.g. "slice 3's baseline was …") — those are
#     per-moment measurements cited with their own run id, not a claim about
#     HEAD, so "fixing" the number in place would fabricate a measurement
#     nobody re-ran.
#   * CHANGELOG.md — an append-only release log; rewriting it falsifies history.
#   * the degenerate `0 passed, 0 failed, 0 total` sentinel, quoted verbatim in
#     publish-crates/nuget/pypi.yml's comments as the "a sweep that executed
#     NOTHING must not green-light a publish" failure mode those gates exist to
#     reject (#439/#444). It is a quoted counter-example, never a corpus claim —
#     and the corpus is never empty, which this guard itself asserts below.
#   * any occurrence whose line carries the marker `corpus-count: historical`,
#     for phase-log narrative that correctly describes a past moment — the SAME
#     opt-out every check below honors, so one mechanism covers all four shapes.
# Every carve-out is reported in the summary, so silently growing the ignore
# list is visible in the CI log.
#
# The three sibling checks, each closing a reported drift (frozen counts with
# no path back to honesty — the opposite problem from the PARITY line's
# "nothing fixes them" carve-out above):
#   * NONZERO CHEAT-SHEET COMMENT (#831): a `<command> ... # Results: N passed,
#     M failed, T total` trailing comment (M != 0) inside a markdown FENCED
#     CODE BLOCK (a Build & Test cheat sheet). Unlike the narrative prose
#     above, this reads as "run this, get this" — a reader who runs the
#     command gets a DIFFERENT M every time the leg's own pass count moves,
#     which is often. No number is ever right here, so (unless
#     historical-marked) it is simply forbidden; point at the live row in
#     conformance-matrix.yml instead. Scoped to inside a fence so a YAML
#     workflow's own phase-log comments (which also start every line with
#     `#`, by YAML comment syntax) and a markdown table/paragraph quoting the
#     same numbers are left alone — neither is a "do this, get this"
#     instruction.
#   * BARE FIXTURE-COUNT PROSE (#714): a free-floating `<N>-fixture` claim in
#     `.github/workflows/coverage.yml` specifically, outside the parsed
#     `Results:` line shape (its "355-fixture conformance run" comment). Not
#     generalized repo-wide: "N-fixture" alone also reads as a DELTA ("a
#     3-fixture gain") or a named small subset ("the same 5-fixture set"),
#     neither of which is the whole-corpus claim this check targets. An
#     approximate count (`~350-fixture`) is a deliberate hedge, not a claim of
#     precision, and is left alone; an exact one is forbidden (unless
#     historical-marked) for the same reason as above.
#   * BOLD-NUMBER "OF N" DENOMINATOR (#716): `**<passed>** of <N>` (the
#     round-trip-floor-listing shape in docs/TESTING_STRATEGY.md) must equal
#     the derived total, unless historical-marked. Scoped to that one doc —
#     "of N" alone is too generic a shape to safely gate repo-wide.
#
# Usage:
#   bash tools/check_conformance_doc_counts.sh            # gate the repo
#   bash tools/check_conformance_doc_counts.sh --root DIR # a synthetic tree
#   bash tools/check_conformance_doc_counts.sh --expect N # override the
#                                                         # derivation
# Exits 0 when every current-status occurrence of all four shapes is clean;
# 1 otherwise, printing every offending file:line. Dependency-free (bash + awk
# + git/find), so it runs in ci.yml's always-on `proto` job with no toolchain.

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

# ── Sibling scan 1: a nonzero-failure Results line reintroduced as a trailing
# shell comment inside a Build & Test FENCED CODE BLOCK (#831) — "run this
# command, get this count" cheat-sheet prose. Scoped to markdown files, lines
# inside a ``` fence, carrying a literal `#` before the match. That scope is
# deliberately narrow: a YAML workflow comment (e.g. conformance-matrix.yml's
# own phase-log narrative, which ALSO starts every line with `#` — it is a
# comment file by syntax) and a markdown table row or paragraph quoting the
# same numbers in backticks are ordinary narrative, not a "do this, get this"
# instruction, and are intentionally left to the main nonzero-failure
# carve-out above (the SAME disambiguation PR #809's review drew for the
# C# roundtrip line vs. the Phase-4/5/7 narrative around it).
scan_nonzero_comment_file() {
  case "$1" in
  *.md) ;;
  *) return 0 ;;
  esac
  awk -v marker="$HISTORICAL_MARKER" '
    BEGIN { infence = 0 }
    {
      line = $0
      trimmed = line
      sub(/^[ \t]*/, "", trimmed)
      if (trimmed ~ /^```/) {
        infence = !infence
        next
      }
      if (!infence) next
      hashpos = index(line, "#")
      if (hashpos == 0) next
      re = "[0-9]+[ \t]+passed,[ \t]+[0-9]+[ \t]+failed,[ \t]+[0-9]+[ \t]+total"
      rest = line
      off = 0
      while (match(rest, re)) {
        start = off + RSTART
        hit = substr(rest, RSTART, RLENGTH)
        if (hashpos < start) {
          split(hit, parts, " ")
          failedval = parts[3]
          if (failedval != "0") {
            kind = (index(line, marker) > 0) ? "historical" : "offender"
            print kind "\t" NR "\t" hit
          }
        }
        off = off + RSTART + RLENGTH - 1
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# ── Sibling scan 2: a bare "<N>-fixture" prose count (#714) — the same rot,
# a different shape (free-floating prose, not the parsed `Results:` line).
# Scoped to EXACTLY the file issue #714 names: `.github/workflows/coverage.yml`
# — "N-fixture" alone is too generic a shape to gate repo-wide (it also reads
# as a DELTA, "a 3-fixture gain", or a named small subset, "the same 5-fixture
# set", neither of which is the whole-corpus claim this check targets). A
# `~`-prefixed count is a deliberate hedge ("approximately"), not a claim of
# precision, and is left alone.
scan_fixture_count_file() {
  case "$1" in
  */.github/workflows/coverage.yml) ;;
  *) return 0 ;;
  esac
  awk -v marker="$HISTORICAL_MARKER" '
    {
      line = $0
      re = "[0-9]+-fixture"
      rest = line
      off = 0
      while (match(rest, re)) {
        start = off + RSTART
        approx = (start > 1 && substr(line, start - 1, 1) == "~")
        if (!approx) {
          hit = substr(rest, RSTART, RLENGTH)
          kind = (index(line, marker) > 0) ? "historical" : "offender"
          print kind "\t" NR "\t" hit
        }
        off = off + RSTART + RLENGTH - 1
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

checked=0
historical=0
sentinel=0
offenders=""
nz_offenders=0
nz_historical=0
nz_list=""
fx_offenders=0
fx_historical=0
fx_list=""

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
  while IFS=$'\t' read -r kind lineno hit; do
    [ -n "${kind:-}" ] || continue
    if [ "$kind" = "historical" ]; then
      nz_historical=$((nz_historical + 1))
      continue
    fi
    nz_offenders=$((nz_offenders + 1))
    nz_list="${nz_list}${rel}:${lineno}: ${hit}"$'\n'
  done < <(scan_nonzero_comment_file "$abs")
  while IFS=$'\t' read -r kind lineno hit; do
    [ -n "${kind:-}" ] || continue
    if [ "$kind" = "historical" ]; then
      fx_historical=$((fx_historical + 1))
      continue
    fi
    fx_offenders=$((fx_offenders + 1))
    fx_list="${fx_list}${rel}:${lineno}: ${hit}"$'\n'
  done < <(scan_fixture_count_file "$abs")
done < <(list_files)

# ── Sibling scan 3: the bold-number "**<N>** of <M>" denominator (#716) —
# the round-trip-floor-listing shape in docs/TESTING_STRATEGY.md. Scoped to
# that one file: "of <M>" alone is far too generic a shape to gate repo-wide
# (e.g. "fixed 4 of 10 packages" has nothing to do with the fixture corpus),
# but immediately after a bold-markdown number it is, in this repo today, used
# for exactly one thing.
bo_checked=0
bo_historical=0
bo_list=""
TESTING_STRATEGY="$ROOT/docs/TESTING_STRATEGY.md"
if [ -f "$TESTING_STRATEGY" ]; then
  while IFS=$'\t' read -r kind lineno hit; do
    [ -n "${kind:-}" ] || continue
    if [ "$kind" = "historical" ]; then
      bo_historical=$((bo_historical + 1))
      continue
    fi
    bo_checked=$((bo_checked + 1))
    got_total="${hit##* }"
    if [ "$got_total" != "$expected" ]; then
      bo_list="${bo_list}docs/TESTING_STRATEGY.md:${lineno}: ${hit}"$'\n'
    fi
  done < <(awk -v marker="$HISTORICAL_MARKER" '
    {
      line = $0
      re = "\\*\\*[0-9]+\\*\\*[ \t]+of[ \t]+[0-9]+"
      rest = line
      off = 0
      while (match(rest, re)) {
        hit = substr(rest, RSTART, RLENGTH)
        kind = (index(line, marker) > 0) ? "historical" : "check"
        print kind "\t" NR "\t" hit
        off = off + RSTART + RLENGTH - 1
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$TESTING_STRATEGY")
fi

echo "conformance-count drift guard: expected total $expected ($derivation)"
echo "  occurrences checked: $checked"
echo "  historical occurrences skipped ('$HISTORICAL_MARKER'): $historical"
echo "  '0 passed, 0 failed, 0 total' sentinel quotes skipped: $sentinel"
echo "  nonzero cheat-sheet comments (#831): $nz_offenders forbidden, $nz_historical historical-skipped"
echo "  bare '<N>-fixture' prose counts (#714): $fx_offenders forbidden, $fx_historical historical-skipped"
echo "  docs/TESTING_STRATEGY.md 'of <N>' denominators (#716): $bo_checked checked, $bo_historical historical-skipped"

# Positive floor: an exit code plus an empty offender list cannot tell "every
# doc agrees" from "the pattern stopped matching and nothing was scanned".
if [ "$checked" -lt 1 ]; then
  echo "::error::the conformance-count guard scanned zero current-status occurrences — the docs stopped stating the total, or the pattern drifted"
  exit 1
fi

failed=0

if [ -n "$offenders" ]; then
  echo "::error::conformance-corpus total drift: these occurrences disagree with the derived total $expected"
  printf '%s' "$offenders" | sed 's/^/  /'
  echo "  fix: update each line to the derived total, or (for phase-log narrative describing a past moment) mark the line '$HISTORICAL_MARKER'"
  failed=1
fi

if [ -n "$nz_list" ]; then
  echo "::error::a nonzero-failure Results line was reintroduced as a cheat-sheet comment (#831):"
  printf '%s' "$nz_list" | sed 's/^/  /'
  echo "  fix: replace the frozen count with a pointer at the live row in conformance-matrix.yml, or (for phase-log narrative describing a past moment) mark the line '$HISTORICAL_MARKER'"
  failed=1
fi

if [ -n "$fx_list" ]; then
  echo "::error::a bare '<N>-fixture' prose count was found outside the parsed Results: line (#714):"
  printf '%s' "$fx_list" | sed 's/^/  /'
  echo "  fix: describe the mechanism instead of a count that will go stale, hedge it with a leading '~' if it is deliberately approximate, or (for phase-log narrative describing a past moment) mark the line '$HISTORICAL_MARKER'"
  failed=1
fi

if [ -n "$bo_list" ]; then
  echo "::error::docs/TESTING_STRATEGY.md's 'of <N>' denominator disagrees with the derived total $expected (#716):"
  printf '%s' "$bo_list" | sed 's/^/  /'
  echo "  fix: update the denominator to the derived total, or (for phase-log narrative describing a past moment) mark the line '$HISTORICAL_MARKER'"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "conformance-count drift guard: OK"
