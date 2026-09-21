#!/usr/bin/env python3
"""Lint: no NEW stdout-only verdict loop in a shell gate (issue #705).

`docs/TESTING_STRATEGY.md` §3a states the rule this enforces:

> A checker that reports "clean" by printing nothing and a checker that could
> not run at all produce the same stdout.

A bash process substitution discards the producer's exit status by construction
— `$?` after `done < <(cmd)` is the loop's, never `cmd`'s, and `set -o pipefail`
does not reach into it. So a leg shaped like

    probs=()
    while IFS= read -r line; do probs+=("$line"); done < <(check "$file")
    if [ "${#probs[@]}" -eq 0 ]; then ok "..."; fi

prints PASS — and counts +1 toward its own positive floor — when `python3` is
absent, an import fails, or the checker dies on a traceback. That is issue #694,
reproduced in PR #662's round-1 review by taking `python3` off PATH.

§3a has said so since #696. It said so in PROSE, which stops nothing: advisory 3
on that PR asked for the mechanical half, and this is it.

## What it checks, and why it is a carve-out list rather than an analysis

Every `done < <(…)` under `tools/**/*.sh` and `cpp/test/*.sh` must be named in
the carve-out list (`tools/verdict_loop_carveouts.tsv` by default) together with
the reason it is safe.

The list is deliberately the whole mechanism. Deciding from the source whether a
particular loop "feeds a verdict" would mean dataflow analysis of bash, and a
wrong answer in the permissive direction is precisely the silent hole under
review. Equally, a process substitution can NEVER capture its producer's status,
so §3a's shape 2 (`out="$(check "$f")"; rc=$?`) is unavailable to this shape by
construction — there is nothing for an analyser to detect. What remains is a
judgement about the surrounding code (a positive floor, a pure in-memory
transformation that cannot "fail to run"), and a judgement belongs in a
reviewed, named list, not in a heuristic.

## The list format

Tab-separated, `#` comments and blank lines ignored:

    <repo-relative path>\t<anchor>\t<reason>

`anchor` is any substring of that loop's PRODUCER — the text inside `<( … )`,
across as many lines as the parentheses span. Anchoring on the producer rather
than on a line number keeps an entry attached to the loop it justifies when the
file moves around it, and means a rewritten producer must be re-justified.

Every entry must match EXACTLY ONE loop:
  * zero  — a stale entry, which would otherwise rot into a blanket exemption;
  * two+  — an ambiguous anchor, which would exempt a site nobody reviewed.
Both are errors, as is an empty reason: naming a site is not justifying it.

## Its own §3a compliance

This checker is the step's last command and the step's status is its own
(`sys.exit`). It reads no other checker's stdout, and it carries a positive
floor: inspecting zero loops is an error, because a pattern that quietly stopped
matching is exactly how this lint would go dead.

Usage:
  python tools/check_verdict_exit_status.py
  python tools/check_verdict_exit_status.py --root <tree> --carveouts <tsv>
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

# `done` redirecting from a process substitution, in any spacing bash accepts.
# Spelled as a pattern rather than a literal so this file is not itself an
# offender in the tree it lints.
LOOP_RE = re.compile(r"done\s*<\s*<\(")

# How far a process substitution may span before it is declared undelimitable.
# The longest in the tree today is 6 lines.
MAX_PRODUCER_LINES = 60


@dataclass(frozen=True)
class Site:
    """One `done < <(…)` loop: where it is, and what it runs."""

    path: str
    line: int
    producer: str


def scanned_files(root: Path) -> list[Path]:
    """`tools/**/*.sh` + `cpp/test/*.sh`, sorted.

    The scope is the one `docs/TESTING_STRATEGY.md` §3a names: the repository's
    shell gates. It is deliberately explicit — a glob over the whole tree would
    quietly start linting vendored or generated scripts nobody here authored.
    """
    files: list[Path] = []
    tools = root / "tools"
    if tools.is_dir():
        files.extend(tools.rglob("*.sh"))
    cpp_test = root / "cpp" / "test"
    if cpp_test.is_dir():
        files.extend(cpp_test.glob("*.sh"))
    return sorted(set(files))


def producer_text(lines: list[str], start: int, open_at: int) -> str | None:
    """The text inside `<( … )` starting at `lines[start][open_at]`.

    Returns `None` when the parentheses never balance within
    [`MAX_PRODUCER_LINES`], which is reported as a loud error rather than a
    skipped site: a lint that guessed where an unbalanced producer ended would
    carve out the wrong text.

    Quoting is honoured well enough to keep a `(` inside `'…'` or `"…"` from
    unbalancing the count — real bash quoting is richer than this, and the
    fallback for anything it cannot delimit is the loud error above, never a
    silent pass.
    """
    depth = 0
    collected: list[str] = []
    for offset in range(min(MAX_PRODUCER_LINES, len(lines) - start)):
        text = lines[start + offset]
        begin = open_at if offset == 0 else 0
        in_single = False
        in_double = False
        escaped = False
        piece: list[str] = []
        for index in range(begin, len(text)):
            char = text[index]
            piece.append(char)
            if escaped:
                escaped = False
                continue
            if char == "\\" and not in_single:
                escaped = True
                continue
            if char == "'" and not in_double:
                in_single = not in_single
                continue
            if char == '"' and not in_single:
                in_double = not in_double
                continue
            if in_single or in_double:
                continue
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    piece.pop()  # the closing paren is not part of the producer
                    collected.append("".join(piece))
                    # Drop the opening `(` of the substitution itself.
                    joined = "\n".join(collected)
                    return joined[1:] if joined.startswith("(") else joined
        collected.append("".join(piece))
    return None


def find_sites(root: Path) -> tuple[list[Site], list[str]]:
    """Every loop in scope, plus the problems found while locating them."""
    sites: list[Site] = []
    problems: list[str] = []
    for path in scanned_files(root):
        rel = path.relative_to(root).as_posix()
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as err:  # unreadable is "could not look", never "clean"
            problems.append(f"{rel}: could not be read: {err}")
            continue
        for index, text in enumerate(lines):
            match = LOOP_RE.search(text)
            if not match:
                continue
            # `<(` — point at the `(` the substitution opens with.
            open_at = match.end() - 1
            producer = producer_text(lines, index, open_at)
            if producer is None:
                problems.append(
                    f"{rel}:{index + 1}: the process substitution could not be delimited "
                    f"within {MAX_PRODUCER_LINES} lines — its parentheses never balance, so "
                    f"neither this lint nor a reader can say what it runs"
                )
                continue
            sites.append(Site(rel, index + 1, producer))
    return sites, problems


def read_carveouts(path: Path) -> tuple[list[tuple[str, str, str]], list[str]]:
    """`(path, anchor, reason)` triples, plus any malformed-entry problems."""
    entries: list[tuple[str, str, str]] = []
    problems: list[str] = []
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as err:
        return [], [f"the carve-out list {path} could not be read: {err}"]
    for number, line in enumerate(raw.splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            problems.append(
                f"{path.name}:{number}: expected 3 tab-separated fields "
                f"(path, anchor, reason), got {len(fields)}: {line!r}"
            )
            continue
        rel, anchor, reason = (field.strip() for field in fields)
        if not rel or not anchor:
            problems.append(
                f"{path.name}:{number}: the path and the anchor must both be non-empty"
            )
            continue
        if not reason:
            problems.append(
                f"{path.name}:{number}: `{rel}` / `{anchor}` has an EMPTY reason — naming a "
                f"site is not justifying it. Say which §3a shape makes this loop safe "
                f"(a positive floor, a pure in-memory transformation, …)."
            )
            continue
        entries.append((rel, anchor, reason))
    return entries, problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(REPO_ROOT), help="tree to lint")
    parser.add_argument(
        "--carveouts",
        default=str(REPO_ROOT / "tools" / "verdict_loop_carveouts.tsv"),
        help="the TSV naming each legitimate site and its reason",
    )
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()

    sites, problems = find_sites(root)
    entries, carve_problems = read_carveouts(Path(args.carveouts))
    problems.extend(carve_problems)

    exempted: set[tuple[str, int]] = set()
    for rel, anchor, _reason in entries:
        matched = [s for s in sites if s.path == rel and anchor in s.producer]
        if len(matched) == 1:
            exempted.add((matched[0].path, matched[0].line))
        elif not matched:
            problems.append(
                f"carve-out `{rel}` / `{anchor}` matched no loop — it is STALE. A carve-out "
                f"that outlives the code it justified is a standing exemption nobody reviewed; "
                f"delete it, or re-anchor it on the producer that replaced it."
            )
        else:
            where = ", ".join(f"{m.path}:{m.line}" for m in matched)
            problems.append(
                f"carve-out `{rel}` / `{anchor}` matched {len(matched)} loops ({where}) — the "
                f"anchor is AMBIGUOUS, so it would exempt a site nobody reviewed. Anchor it on "
                f"text unique to the one loop it justifies."
            )

    for site in sites:
        if (site.path, site.line) in exempted:
            continue
        producer = " ".join(site.producer.split())
        if len(producer) > 120:
            producer = producer[:120] + "…"
        problems.append(
            f"{site.path}:{site.line}: `done < <({producer})` — a process substitution DISCARDS "
            f"its producer's exit status, so a checker that could not run reaches the verdict "
            f"below as the same empty stdout a clean one does (docs/TESTING_STRATEGY.md §3a, "
            f"issue #694). Restructure it (§3a shapes 1-3), or add it to "
            f"{Path(args.carveouts).name} with the reason it is safe."
        )

    print(f"verdict-loop lint: files scanned: {len(scanned_files(root))}")
    print(f"  loops inspected: {len(sites)}")
    print(f"  carve-outs declared: {len(entries)}")

    # Every problem is reported before any verdict is taken. An undelimitable
    # substitution removes a site from `sites`, so an early return on the floor
    # below would swallow the very message that explains why nothing was
    # inspected.
    for problem in problems:
        print(f"::error::{problem}", file=sys.stderr)

    # POSITIVE FLOOR. Zero inspected loops and zero problems are the same exit
    # code, and a pattern that stopped matching — a bash spelling this regex
    # does not know, a scope that moved — is exactly how this lint would go
    # quietly dead while reporting success.
    if not sites:
        print(
            "::error::the verdict-loop lint inspected ZERO loops. Either the scanned scope "
            "(tools/**/*.sh + cpp/test/*.sh) no longer holds any, or the pattern drifted — "
            "both make this gate vacuous, and neither is a pass.",
            file=sys.stderr,
        )
        print("Results: 0 passed, 1 failed, 1 total (verdict-loop lint)")
        return 1

    if problems:
        print(
            f"Results: {max(len(sites) - len(problems), 0)} passed, {len(problems)} failed, "
            f"{len(sites)} total (verdict-loop lint)"
        )
        return 1

    print(f"Results: {len(sites)} passed, 0 failed, {len(sites)} total (verdict-loop lint)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
