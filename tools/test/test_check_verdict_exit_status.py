#!/usr/bin/env python3
"""Negative controls for `tools/check_verdict_exit_status.py` (issue #705).

`docs/TESTING_STRATEGY.md` §3a says a leg's verdict must consume the checker's
EXIT STATUS, not only its stdout — and names the shape that breaks the rule:

    probs=()
    while IFS= read -r line; do probs+=("$line"); done < <(check "$file")
    if [ "${#probs[@]}" -eq 0 ]; then ok "..."; fi

A process substitution DISCARDS the producer's exit status by construction, so
"the checker found nothing" and "the checker could not run at all" arrive as the
same empty stdout, and the leg reports PASS — counting +1 toward its own
positive floor — for a check that never happened (#694, reproduced in PR #662's
round-1 review by taking `python3` off PATH).

That rule was PROSE. Nothing stopped the next one being written, which is
advisory 3 on PR #696 and the reason this lint exists: every such loop under
`tools/**/*.sh` and `cpp/test/*.sh` must be named in
`tools/verdict_loop_carveouts.tsv` together with the reason it is safe.

A checker nobody has watched fail is not a gate, so these cases run FIRST in the
`proto` job and drive the real script over fabricated trees: an uncarved
offender, a carved one, a stale entry, an ambiguous anchor, an empty reason, a
multi-line substitution, an undelimitable one, a tree with no loops at all, and
— the positive control — this repository, which must pass.

Run:  python tools/test/test_check_verdict_exit_status.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER = REPO_ROOT / "tools" / "check_verdict_exit_status.py"
CARVEOUTS = REPO_ROOT / "tools" / "verdict_loop_carveouts.tsv"

_passed = 0
_failed = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global _passed, _failed
    if ok:
        _passed += 1
        print(f"PASS  {name}")
    else:
        _failed += 1
        print(f"FAIL  {name}" + (f" — {detail}" if detail else ""))


def run(root: Path, carveouts: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(CHECKER),
            "--root",
            str(root),
            "--carveouts",
            str(carveouts),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


# A leg shaped exactly like the one §3a forbids: the producer's status is gone,
# and the verdict below reads only the collected stdout.
OFFENDER = """#!/usr/bin/env bash
set -euo pipefail
probs=()
while IFS= read -r line; do
  probs+=("$line")
done < <(fabricated_offender_check "$1")
if [ "${#probs[@]}" -eq 0 ]; then
  echo "OK"
else
  exit 1
fi
"""

# The same loop with the §3a shape-3 escape: an explicit positive floor, so
# "nothing came back" cannot reach the ok branch.
FLOORED = """#!/usr/bin/env bash
set -euo pipefail
seen=0
while IFS= read -r line; do
  seen=$((seen + 1))
done < <(fabricated_floored_check "$1")
if [ "$seen" -lt 1 ]; then
  echo "scanned nothing" >&2
  exit 1
fi
echo "OK"
"""

# The producer spans several lines, so the `done` line carries no text after
# `<(` at all — the shape the go-release wiring guard uses.
MULTILINE = """#!/usr/bin/env bash
set -euo pipefail
files=()
while IFS= read -r f; do
  files+=("$f")
done < <(
  {
    printf '%s\\n' "fabricated_multiline_first"
    printf '%s\\n' "fabricated_multiline_second"
  } | sort -u
)
echo "${#files[@]}"
"""

# The closing paren never arrives — the script is not delimitable, and a lint
# that guessed where the producer ended would carve out the wrong text.
UNBALANCED = """#!/usr/bin/env bash
set -euo pipefail
while IFS= read -r f; do
  :
done < <(fabricated_unbalanced_check "$1"
"""

CLEAN = """#!/usr/bin/env bash
set -euo pipefail
out="$(some_check "$1")"
rc=$?
[ "$rc" -eq 0 ] || exit 1
printf '%s\\n' "$out"
"""


def case(
    name: str,
    files: dict[str, str],
    carveouts: str,
    want_ok: bool,
    want_fragment: str = "",
) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for rel, text in files.items():
            write(root / rel, text)
        carve = root / "carveouts.tsv"
        carve.write_text(carveouts, encoding="utf-8")
        result = run(root, carve)
        blob = result.stdout + result.stderr
        ok = (result.returncode == 0) == want_ok
        if ok and want_fragment:
            ok = want_fragment in blob
        check(
            name,
            ok,
            f"exit={result.returncode} (wanted {'0' if want_ok else 'non-zero'}), "
            f"output: {blob.strip()[:400]}",
        )


def main() -> int:
    check("the checker exists", CHECKER.is_file(), f"no {CHECKER}")
    check("the carve-out list exists", CARVEOUTS.is_file(), f"no {CARVEOUTS}")
    if not CHECKER.is_file():
        print(f"Results: {_passed} passed, {_failed} failed, {_passed + _failed} total")
        return 1

    case(
        "an uncarved `done < <(...)` verdict loop is REJECTED, by file and line",
        {"tools/offender.sh": OFFENDER},
        "",
        want_ok=False,
        want_fragment="tools/offender.sh:6",
    )

    case(
        "the same loop passes once the carve-out list names it AND says why",
        {"tools/offender.sh": OFFENDER},
        "tools/offender.sh\tfabricated_offender_check\t"
        "fabricated fixture; the verdict below is floored\n",
        want_ok=True,
    )

    case(
        "a carve-out whose reason is EMPTY is rejected — naming a site is not "
        "justifying it",
        {"tools/offender.sh": OFFENDER},
        "tools/offender.sh\tfabricated_offender_check\t\n",
        want_ok=False,
        want_fragment="reason",
    )

    case(
        "a STALE carve-out (its anchor matches no loop) is an error, so the "
        "list cannot silently rot into a blanket exemption",
        {"tools/offender.sh": OFFENDER},
        "tools/offender.sh\tfabricated_offender_check\tfabricated fixture\n"
        "tools/offender.sh\tfabricated_removed_check\tdeleted two refactors ago\n",
        want_ok=False,
        want_fragment="matched no",
    )

    case(
        "an AMBIGUOUS anchor (it matches two loops in one file) is an error — "
        "one entry must not exempt a site nobody reviewed",
        {
            "tools/two.sh": OFFENDER
            + "\nwhile IFS= read -r l; do :; done "
            + "< <(fabricated_offender_check \"$2\")\n"
        },
        "tools/two.sh\tfabricated_offender_check\tambiguous on purpose\n",
        want_ok=False,
        want_fragment="matched 2",
    )

    case(
        "a loop that ALREADY has a positive floor is still rejected without a "
        "carve-out — the lint does not try to infer safety from bash source, "
        "and an inference that guessed wrong in the permissive direction is "
        "exactly the hole under review",
        {"tools/floored.sh": FLOORED},
        "",
        want_ok=False,
        want_fragment="tools/floored.sh:6",
    )

    case(
        "and it passes the moment the list records that floor as the reason",
        {"tools/floored.sh": FLOORED},
        "tools/floored.sh\tfabricated_floored_check\t"
        "floor: the `seen -lt 1` arm below exits 1 on empty output\n",
        want_ok=True,
    )

    case(
        "a MULTI-LINE process substitution is found and its anchor may come "
        "from the continuation lines",
        {"tools/multi.sh": MULTILINE},
        "tools/multi.sh\tfabricated_multiline_second\tfabricated fixture\n",
        want_ok=True,
    )

    case(
        "the same multi-line loop with no carve-out is REJECTED (the `done` "
        "line alone carries no producer text, and that must not hide it)",
        {"tools/multi.sh": MULTILINE},
        "",
        want_ok=False,
        want_fragment="tools/multi.sh:6",
    )

    case(
        "a process substitution whose parentheses never balance is a LOUD "
        "error, never a skipped site",
        {"tools/unbalanced.sh": UNBALANCED},
        "",
        want_ok=False,
        want_fragment="could not be delimited",
    )

    case(
        "POSITIVE FLOOR: a tree with shell scripts but no such loop at all is "
        "an error — the pattern drifting into matching nothing is exactly how "
        "this lint would go quietly dead",
        {"tools/clean.sh": CLEAN},
        "",
        want_ok=False,
        want_fragment="ZERO loops",
    )

    case(
        "a `.sh` file OUTSIDE the linted scope is not scanned (the scope is "
        "tools/**/*.sh + cpp/test/*.sh, and a silent widening would be just as "
        "wrong as a silent narrowing)",
        {"tools/clean.sh": CLEAN, "cpp/src/elsewhere.sh": OFFENDER},
        "",
        want_ok=False,
        want_fragment="ZERO loops",
    )

    case(
        "cpp/test/*.sh IS scanned",
        {"cpp/test/offender.sh": OFFENDER},
        "",
        want_ok=False,
        want_fragment="cpp/test/offender.sh:6",
    )

    # ── The positive control ────────────────────────────────────────────────
    # Fabricated trees can only prove the checker's verdicts. This proves the
    # real invocation the `proto` job runs is green on the real tree, so a case
    # above cannot pass while the shipped gate is broken.
    real = subprocess.run(
        [sys.executable, str(CHECKER)],
        capture_output=True,
        text=True,
        check=False,
        cwd=str(REPO_ROOT),
    )
    check(
        "POSITIVE CONTROL: the repository's own tools/**/*.sh + cpp/test/*.sh "
        "pass the lint",
        real.returncode == 0,
        f"exit={real.returncode}: {(real.stdout + real.stderr).strip()[:600]}",
    )
    check(
        "and it reports how many loops it actually inspected",
        "loops inspected:" in real.stdout,
        real.stdout.strip()[:400],
    )

    total = _passed + _failed
    print(f"Results: {_passed} passed, {_failed} failed, {total} total")
    if total < 1:
        print("ERROR: the self-test asserted nothing.", file=sys.stderr)
        return 1
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
