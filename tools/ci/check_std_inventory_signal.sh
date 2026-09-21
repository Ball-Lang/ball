#!/usr/bin/env bash
# Derived-from-source guard for detect-changed-stacks' `std_inventory` signal
# (issue #774).
#
# WHY THIS EXISTS: the canonical std INVENTORY — the `buildStd*Module` builders
# under `dart/shared/lib/` and the `dart/shared/std.{json,bin}` artifacts
# `gen_std.dart` serialises them into — is a CROSS-STACK `dart/` input. Three
# other stacks read those files off disk AT TEST TIME as their source of truth:
#   * rust/shared/src/std_dart_parity.rs
#   * csharp/shared/test/StdModuleBuilderTests.cs
#   * python/encoder/tests/test_ballrt_inverse.py
# `.github/actions/detect-changed-stacks/detect.sh` therefore ORs a
# `std_inventory` signal into `rust`/`csharp`/`python`, so the ONE commit each
# of those gates exists to catch — the Dart inventory moving — is not the one
# commit on which their jobs skip (#751).
#
# That signal was a HAND-WRITTEN SHAPE REGEX (`std(_[a-z_]+)?\.dart`) plus a
# hand-reasoned exclusion of `ts/`, `go/` and `cpp/`. Both halves are closed-set
# assumptions about source that nothing derived and nothing re-checked:
#
#   1. All eight builders HAPPEN to match `std(_[a-z_]+)?\.dart`. A ninth named
#      outside that shape (a digit, a capital, a `_std.dart` suffix order) would
#      silently fail to trip the signal, and the three parity gates would then
#      run against a stale inventory with nothing saying they skipped the change
#      that mattered.
#   2. The exclusion of ts/go/cpp rested on ONE grep at review time
#      ("they reference these files only in prose"). If any of those suites
#      later starts reading the Dart inventory off disk — the same shape
#      rust/csharp/python already have — nothing notices: the new reader simply
#      starts running stale on every std-only PR, with the OR-list never
#      extended.
#
# Same failure shape as #719 (a stale stem reference no gate could see) and
# #708 (a committed artifact no job regenerated).
#
# ── WHAT THIS GUARD CHECKS ──────────────────────────────────────────────────
#
# INVARIANT 1 — the match set is DERIVED, not described. The builder set is
# read out of the builders themselves (`Module buildStd<X>Module(` declarations
# under `dart/shared/lib/`), the artifact names out of `gen_std.dart`'s own
# writes, and the resulting pattern is compared against the GENERATED BLOCK in
# detect.sh. A builder added under ANY filename is drift here, whatever it is
# called. `--write` regenerates the block.
#
# INVARIANT 2 — no stack OUTSIDE the OR-list references the inventory in CODE.
# Which stacks are inside the OR-list is scraped from detect.sh itself, and
# which stacks exist at all from its `infra` prefix list, so there is no second
# table: every stack that is neither `dart/` (the source of truth) nor already
# ORed in is scanned, and a reference that survives comment-stripping FAILS,
# naming the file. Adding that stack to the OR-list is the fix — and doing so
# also removes it from this scan, automatically.
#
# INVARIANT 3 — the signal is actually WIRED. Invariants 1 and 2 are both
# static: they would still pass if `std_inventory` were computed and then read
# by nobody. So every derived path is run through the REAL classifier (sourced,
# the same contract test/truth_table.sh and check_matrix_paths.sh use) and must
# come back `rust=true csharp=true python=true`; sibling `dart/shared/lib`
# files that are NOT builders are the negative control and must not.
#
# POSITIVE FLOORS: a guard that derived zero builders, scanned zero files or
# checked zero paths is not a pass. `--min-builders` is floored at the MEASURED
# count (8 today) so a derivation regex that stops matching cannot read as a
# clean bill of health; lower it deliberately, in the commit that removes a
# builder.
#
# KNOWN LIMIT (documented, not silent): invariant 2 is a literal + segmented-
# join scan over tracked source files, after comment- and docstring-stripping.
# It catches `"dart/shared/lib/std_io.dart"` and `join("dart", "shared", …)`;
# it cannot catch a path assembled from variables at run time. That is the same
# grade of check `docs/TESTING_STRATEGY.md` records for it.
#
# Usage:
#   bash tools/ci/check_std_inventory_signal.sh              # gate the repo
#   bash tools/ci/check_std_inventory_signal.sh --write      # regen the block
#   bash tools/ci/check_std_inventory_signal.sh --self-test  # drive the cases
#
# Needs bash + python3 + git (the runner image ships all three), so it runs in
# ci.yml's always-on `proto` job with no language toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DETECT=""
MIN_BUILDERS=8
WRITE=0
SELF_TEST=0
TAB=$'\t'

BEGIN_MARK='# BEGIN generated std_inventory pattern'
END_MARK='# END generated std_inventory pattern'

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
  --detect)
    DETECT="$2"
    shift 2
    ;;
  --detect=*)
    DETECT="${1#--detect=}"
    shift
    ;;
  --min-builders)
    MIN_BUILDERS="$2"
    shift 2
    ;;
  --min-builders=*)
    MIN_BUILDERS="${1#--min-builders=}"
    shift
    ;;
  --write)
    WRITE=1
    shift
    ;;
  --self-test)
    SELF_TEST=1
    shift
    ;;
  -h | --help)
    sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

[ -n "$DETECT" ] || DETECT="$ROOT/.github/actions/detect-changed-stacks/detect.sh"

# ── derivation ──────────────────────────────────────────────────────────────
# Emits a machine-readable spec of the std inventory, derived ONLY from source:
#   BUILDER   <repo-relative path>     a file declaring `Module buildStd*Module(`
#   ARTIFACT  <repo-relative path>     a file gen_std.dart writes
#   OTHERLIB  <repo-relative path>     a dart/shared/lib/*.dart that is neither
#   PATTERN   <regex>                  the alternation those imply
# Fails loud rather than emitting a short spec: an empty derivation is the one
# outcome that would make every downstream check vacuously true.
derive_spec() {
  python3 - "$ROOT" "$MIN_BUILDERS" <<'PY'
import os
import re
import sys

root, min_builders = sys.argv[1], int(sys.argv[2])
lib = os.path.join(root, "dart", "shared", "lib")
gen = os.path.join(root, "dart", "shared", "bin", "gen_std.dart")

if not os.path.isdir(lib):
    print(f"::error::no dart/shared/lib under {root} - nothing to derive the std inventory from")
    sys.exit(1)

# THE source of truth for "is this file a std module builder": the builder
# declaration itself. Not the filename, which is what #774 is about, and not a
# curated list, which would just be the hand-written regex in another file.
DECL = re.compile(r"^Module\s+buildStd[A-Za-z0-9_]*Module\s*\(", re.M)

builders, others = [], []
for name in sorted(os.listdir(lib)):
    if not name.endswith(".dart"):
        continue
    with open(os.path.join(lib, name), encoding="utf-8") as fh:
        text = fh.read()
    (builders if DECL.search(text) else others).append(f"dart/shared/lib/{name}")

if len(builders) < min_builders:
    print(
        f"::error::derived only {len(builders)} std module builder(s) under "
        f"dart/shared/lib (floor {min_builders}). Either a builder was removed "
        "- lower --min-builders in ci.yml in that same commit - or the "
        "`Module buildStd*Module(` derivation stopped matching, in which case "
        "this guard is reading an empty inventory and would pass on anything."
    )
    sys.exit(1)

# The public registration side. A `buildStd*Module` re-exported from a file the
# scan above did not classify as a builder means the inventory lives somewhere
# this guard cannot see - the exact blind spot it exists to close.
ball_base = os.path.join(lib, "ball_base.dart")
if os.path.isfile(ball_base):
    with open(ball_base, encoding="utf-8") as fh:
        base_text = fh.read()
    exported = set(re.findall(r"export\s+'([^']+\.dart)'\s+show\s+buildStd[A-Za-z0-9_]*Module", base_text))
    known = {b.rsplit("/", 1)[1] for b in builders}
    stray = sorted(e for e in exported if e.rsplit("/", 1)[-1] not in known)
    if stray:
        print(
            "::error::dart/shared/lib/ball_base.dart re-exports a buildStd*Module "
            f"from {', '.join(stray)}, which declares no `Module buildStd*Module(` "
            "under dart/shared/lib. The std inventory must be derivable from the "
            "builder declarations - move the builder there or teach this guard."
        )
        sys.exit(1)

# The generated artifacts, taken from gen_std.dart's OWN writes rather than
# spelled here, so renaming std.json/std.bin moves the signal with it.
if not os.path.isfile(gen):
    print(f"::error::{gen} not found - cannot derive which artifacts the std inventory generates")
    sys.exit(1)
with open(gen, encoding="utf-8") as fh:
    gen_text = fh.read()
artifacts = sorted({m for m in re.findall(r"\$outputDir/([A-Za-z0-9_.]+)", gen_text)})
if not artifacts:
    print(
        f"::error::{gen} writes no `$outputDir/<file>` artifact this guard can "
        "see. The std inventory's committed half would then be underived."
    )
    sys.exit(1)

stems = sorted(b.rsplit("/", 1)[1][: -len(".dart")] for b in builders)
alts = ["^dart/shared/lib/(%s)\\.dart$" % "|".join(stems)]
alts += ["^dart/shared/%s$" % a.replace(".", "\\.") for a in artifacts]
pattern = "|".join(alts)

for b in builders:
    print(f"BUILDER\t{b}")
for a in artifacts:
    print(f"ARTIFACT\tdart/shared/{a}")
for o in others:
    print(f"OTHERLIB\t{o}")
print(f"PATTERN\t{pattern}")
PY
}

# read_block — the pattern currently committed in detect.sh's generated block,
# or nothing when the block is absent (which is itself the #774 finding).
read_block() {
  python3 - "$DETECT" "$BEGIN_MARK" "$END_MARK" <<'PY'
import re
import sys

path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
except FileNotFoundError:
    sys.exit(0)
m = re.search(
    re.escape(begin) + r".*?^\s*local std_inventory_re='([^']*)'.*?" + re.escape(end),
    text,
    re.S | re.M,
)
if m:
    print(m.group(1))
PY
}

# render_block — the exact lines detect.sh must carry for <pattern>.
render_block() {
  local pattern="$1"
  cat <<EOF
  $BEGIN_MARK — DO NOT EDIT BY HAND.
  # Derived from the \`Module buildStd*Module(\` declarations under
  # dart/shared/lib/ and the artifacts dart/shared/bin/gen_std.dart writes.
  # Regenerate: bash tools/ci/check_std_inventory_signal.sh --write
  local std_inventory_re='$pattern'
  $END_MARK
EOF
}

# write_block — replace (or, on a file that has none, refuse to invent) the
# generated block. Refusing is deliberate: silently appending a block to an
# arbitrary file is how a --write turns a typo'd --detect into a wrong "fix".
write_block() {
  local pattern="$1" tmp rc=0
  tmp="$(mktemp)"
  render_block "$pattern" >"$tmp"
  python3 - "$DETECT" "$BEGIN_MARK" "$END_MARK" "$tmp" <<'PY' || rc=$?
import re
import sys

path, begin, end, rendered_path = sys.argv[1:5]
with open(rendered_path, encoding="utf-8") as fh:
    rendered = fh.read()
with open(path, encoding="utf-8") as fh:
    text = fh.read()
pat = re.compile(r"^[ \t]*" + re.escape(begin) + r".*?" + re.escape(end) + r"[ \t]*\r?\n", re.S | re.M)
if not pat.search(text):
    print(
        f"::error::{path} carries no '{begin}' ... '{end}' block to rewrite. "
        "Add the two marker lines around the std_inventory pattern first - this "
        "script will not invent a block in an arbitrary file."
    )
    sys.exit(1)
with open(path, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(pat.sub(lambda _: rendered, text, count=1))
print(f"rewrote the generated std_inventory pattern in {path}")
PY
  rm -f "$tmp"
  return "$rc"
}

# ── invariant 2: no off-list stack reads the inventory in CODE ──────────────
# The stack set and the OR-list are both scraped from detect.sh, so this scan
# re-targets itself the moment either moves.
scan_cross_stack() {
  python3 - "$ROOT" "$DETECT" <<'PY'
import os
import re
import subprocess
import sys

root, detect = sys.argv[1], sys.argv[2]

try:
    with open(detect, encoding="utf-8") as fh:
        dtext = fh.read()
except FileNotFoundError:
    print(f"::error::classifier not found: {detect}")
    sys.exit(1)

# Every stack that has its own output and job: the `infra` fail-safe's prefix
# list is the classifier's own enumeration of them.
m = re.search(r"grep -qvE '\^\(([^)]*)\)'", dtext)
if not m:
    print(
        "::error::could not find the `infra` prefix list in the classifier - "
        "this scan derives the stack set from it and must not guess."
    )
    sys.exit(1)
stacks = [s.strip().rstrip("/") for s in m.group(1).split("|") if s.strip()]

# Which of them already OR `std_inventory` into their output.
ored = set(re.findall(r'\$std_inventory" = true \].*?echo "([a-z_]+)=true"', dtext))
if not ored:
    print(
        "::error::no stack in the classifier ORs `std_inventory` into its "
        "output - the signal would be computed and read by nobody."
    )
    sys.exit(1)

# dart/ IS the inventory, so it is never a cross-stack reader.
targets = [s for s in stacks if s != "dart" and s not in ored]
if not targets:
    print(
        "::error::every stack already ORs `std_inventory`, so this scan has "
        "nothing to check. That is a real state (and a fine one), but it must "
        "be reached deliberately - drop this invariant rather than letting it "
        "silently check zero files."
    )
    sys.exit(1)

try:
    listed = subprocess.run(
        ["git", "-C", root, "ls-files", "--"] + targets,
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
except (subprocess.CalledProcessError, FileNotFoundError) as exc:
    print(f"::error::`git ls-files` failed under {root}: {exc}")
    sys.exit(1)

# Source + config extensions only. Documentation (.md) is prose by definition,
# and a binary or lockfile cannot read a path.
SLASH = {".ts", ".mts", ".cts", ".js", ".mjs", ".cjs", ".go", ".c", ".cc",
         ".cpp", ".cxx", ".h", ".hh", ".hpp", ".cs", ".rs", ".java"}
HASH = {".py", ".sh", ".bash", ".txt", ".yml", ".yaml", ".cmake", ".toml", ".cfg"}
NONE = {".json"}


def strip_slash(text):
    """Blank out // and /* */ comments, preserving offsets and line count.

    `//go:embed` survives: it LOOKS like a comment and is a real off-disk read,
    which is exactly the shape this scan exists to catch.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//" and not text.startswith("//go:embed", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(c if c == "\n" else " " for c in text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def strip_hash(text):
    """Blank out # comments and triple-quoted strings, preserving offsets.

    A Python module docstring is prose — the repo's own cpp/test/*.py explain
    the Dart inventory inside one.
    """
    def blank(match):
        return "".join(c if c == "\n" else " " for c in match.group(0))

    text = re.sub(r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'', blank, text)
    out = []
    for line in text.split("\n"):
        i = line.find("#")
        out.append(line if i < 0 else line[:i] + " " * (len(line) - i))
    return "\n".join(out)


# Needles: the inventory's own path prefix (so a `std*.dart` glob counts too)
# and the committed artifacts.
NEEDLES = ["dart/shared/lib/std", "dart/shared/std.json", "dart/shared/std.bin"]
# The segmented form a path join produces: os.path.join(root, "dart", "shared", …).
SEGMENTED = re.compile(r"""["']dart["']\s*,\s*["']shared["']""")
# `//go:embed` survives comment-stripping (see strip_slash) and is an off-disk
# read spelled as a comment, so it gets its own sweep.
EMBED = re.compile(r"//go:embed[^\n]*")
# String literals, including JS/TS template literals (which may span lines).
STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'|`(?:[^`\\]|\\.)*`', re.S)
# Languages whose files carry BARE (unquoted) paths as a matter of course. In
# ts/go/c++/python a needle outside both a comment and a string literal is not
# valid syntax, so only these need the unquoted sweep.
BARE = {".sh", ".bash", ".cmake", ".yml", ".yaml", ".txt", ".toml", ".cfg"}

# A REFERENCE is a path-shaped string literal — `"dart/shared/std.json"`,
# `join("dart/shared/lib", name)`, `` `${root}/dart/shared/std.json` `` — or a
# segmented join. A needle inside a literal that also contains WHITESPACE is a
# sentence, i.e. the same prose a comment would carry (the repo has five such
# diagnostic messages in ts/ and cpp/ today); flagging those would make this
# gate noise instead of a signal. Documented in docs/TESTING_STRATEGY.md.
hits, scanned = [], 0
for rel in listed:
    ext = os.path.splitext(rel)[1]
    if ext in SLASH:
        stripper = strip_slash
    elif ext in HASH:
        stripper = strip_hash
    elif ext in NONE:
        def stripper(t):
            return t  # JSON has no comment syntax
    else:
        continue
    full = os.path.join(root, rel)
    try:
        with open(full, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError):
        continue
    scanned += 1
    code = stripper(text)

    def lineno_at(pos):
        return code.count("\n", 0, pos) + 1

    def excerpt(pos):
        start = code.rfind("\n", 0, pos) + 1
        end = code.find("\n", pos)
        return code[start:end if end >= 0 else len(code)].strip()[:160]

    masked = list(code)
    for m in STRING.finditer(code):
        body = m.group(0)[1:-1]
        for ch in range(m.start(), m.end()):
            masked[ch] = " "
        needle = next((n for n in NEEDLES if n in body), None)
        if needle is not None and not re.search(r"\s", body):
            hits.append((rel, lineno_at(m.start()), f"path literal containing {needle}", excerpt(m.start())))
    if ext in BARE:
        rest = "".join(masked)
        for needle in NEEDLES:
            for m in re.finditer(re.escape(needle), rest):
                hits.append((rel, lineno_at(m.start()), f"unquoted {needle}", excerpt(m.start())))
    for m in SEGMENTED.finditer(code):
        hits.append((rel, lineno_at(m.start()), "a segmented dart/shared path join", excerpt(m.start())))
    for m in EMBED.finditer(code):
        needle = next((n for n in NEEDLES if n in m.group(0)), None)
        if needle is not None:
            hits.append((rel, lineno_at(m.start()), f"a //go:embed of {needle}", excerpt(m.start())))

if scanned < 1:
    print(
        f"::error::scanned ZERO source files under {', '.join(targets)} - a scan "
        "that found nothing to scan is not a pass. Check that `git ls-files` "
        "sees this checkout."
    )
    sys.exit(1)

print(f"cross-stack scan: {scanned} tracked source file(s) under {', '.join(t + '/' for t in targets)} "
      f"(stacks already ORing std_inventory: {', '.join(sorted(ored))}).")

if hits:
    print(
        "::error::a stack OUTSIDE the `std_inventory` OR-list references the "
        "canonical Dart std inventory in CODE (not a comment). That stack's "
        "tests would then run against a STALE inventory on every std-only PR, "
        "because detect-changed-stacks never starts its job for one. Fix it by "
        "ORing `$std_inventory` into that stack's output in "
        ".github/actions/detect-changed-stacks/detect.sh (plus a truth-table "
        "row) - which also removes it from this scan - or by dropping the "
        "off-disk read."
    )
    for rel, lineno, why, line in sorted(set(hits)):
        print(f"  {rel}:{lineno}: {why}")
        print(f"      {line}")
    bad = len({h[0] for h in hits})
    print(f"Results: {scanned - bad} passed, {bad} failed, {scanned} total (cross-stack scan)")
    sys.exit(1)

print(f"Results: {scanned} passed, 0 failed, {scanned} total (cross-stack scan)")
PY
}

# ── the gate ────────────────────────────────────────────────────────────────
run_gate() {
  local spec rc=0
  spec="$(derive_spec)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$spec"
    return 1
  fi

  local want_pattern have_pattern
  want_pattern="$(printf '%s\n' "$spec" | sed -n "s/^PATTERN${TAB}//p")"
  if [ -z "$want_pattern" ]; then
    echo "::error::derivation produced no pattern"
    return 1
  fi

  local builders artifacts others n_builders
  builders="$(printf '%s\n' "$spec" | sed -n "s/^BUILDER${TAB}//p")"
  artifacts="$(printf '%s\n' "$spec" | sed -n "s/^ARTIFACT${TAB}//p")"
  others="$(printf '%s\n' "$spec" | sed -n "s/^OTHERLIB${TAB}//p")"
  # awk, not `grep -c` — grep exits 1 on zero matches, which would need a
  # `|| true` that swallows a real failure along with the empty case.
  n_builders="$(printf '%s\n' "$builders" | awk 'NF { n++ } END { print n + 0 }')"

  echo "Derived std inventory from source ($n_builders builder(s), floor $MIN_BUILDERS):"
  printf '  builder   %s\n' $builders
  printf '  artifact  %s\n' $artifacts
  echo ""

  if [ "$WRITE" -eq 1 ]; then
    write_block "$want_pattern" || return 1
    return 0
  fi

  # ── invariant 1: the committed pattern IS the derived one ────────────────
  have_pattern="$(read_block)"
  if [ -z "$have_pattern" ]; then
    echo "::error::$DETECT carries no generated \`std_inventory\` pattern block. Its match set is a hand-written shape regex, so a std module builder added under a filename outside that shape would silently fail to trip the signal and the rust/csharp/python parity gates would run against a stale inventory (issue #774). Replace the hand-written line with the block below — \`bash tools/ci/check_std_inventory_signal.sh --write\` does it once the markers are in place:"
    render_block "$want_pattern" | sed 's/^/    /'
    echo "Results: 0 passed, 1 failed, 1 total (derived pattern)"
    return 1
  fi
  if [ "$have_pattern" != "$want_pattern" ]; then
    echo "::error::$DETECT's generated \`std_inventory\` pattern is STALE — the std inventory moved and the signal did not follow it (issue #774). Regenerate with: bash tools/ci/check_std_inventory_signal.sh --write"
    echo "  committed: $have_pattern"
    echo "  derived:   $want_pattern"
    echo "Results: 0 passed, 1 failed, 1 total (derived pattern)"
    return 1
  fi
  echo "derived pattern matches the block committed in $DETECT."
  echo "  $want_pattern"
  echo "Results: 1 passed, 0 failed, 1 total (derived pattern)"
  echo ""

  # ── invariant 3: the signal is wired into rust/csharp/python ─────────────
  if [ ! -f "$DETECT" ]; then
    echo "::error::the classifier $DETECT is missing — the signal cannot be checked against the real outputs."
    return 1
  fi
  # shellcheck source=/dev/null
  . "$DETECT" || {
    echo "::error::could not source $DETECT"
    return 1
  }

  local consumers
  consumers="$(python3 - "$DETECT" <<'PY'
import re
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()
print(" ".join(sorted(set(re.findall(r'\$std_inventory" = true \].*?echo "([a-z_]+)=true"', text)))))
PY
)"
  if [ -z "$consumers" ]; then
    echo "::error::no stack ORs \`std_inventory\` into its output in $DETECT — the signal would be computed and read by nobody."
    return 1
  fi

  echo "signal wiring (stacks ORing std_inventory: $consumers):"
  local path out missing pass=0 fail=0 stack
  for path in $builders $artifacts; do
    out="$(ball_classify_stacks "$path" "")"
    missing=""
    for stack in $consumers; do
      grep -qx "$stack=true" <<<"$out" || missing="$missing $stack"
    done
    if [ -n "$missing" ]; then
      fail=$((fail + 1))
      printf '  %-40s -> MISSING:%s\n' "$path" "$missing"
      echo "::error::the classifier does NOT start$missing for \`$path\`, a derived member of the std inventory. Those stacks' parity gates read that file off disk, so they would run against a stale inventory on the very commit that moved it."
    else
      pass=$((pass + 1))
      printf '  %-40s -> %s\n' "$path" "$(tr ' ' ',' <<<"$consumers")"
    fi
  done

  # Negative control: a dart/shared/lib file that declares no builder must not
  # drag those three stacks in, or `std_inventory` is just `^dart/shared/`
  # under another name. Files the classifier already flags as `self_host`
  # legitimately start every stack for a different reason and are skipped —
  # loudly, so the skip can never quietly empty this control.
  local controls=0
  for path in $others; do
    out="$(ball_classify_stacks "$path" "")"
    if grep -qx "self_host=true" <<<"$out"; then
      printf '  %-40s -> (skipped: self_host input)\n' "$path"
      continue
    fi
    controls=$((controls + 1))
    missing=""
    for stack in $consumers; do
      grep -qx "$stack=true" <<<"$out" && missing="$missing $stack"
    done
    if [ -n "$missing" ]; then
      fail=$((fail + 1))
      printf '  %-40s -> WIDENED:%s\n' "$path" "$missing"
      echo "::error::\`$path\` declares no std module builder, yet the classifier starts$missing for it — the \`std_inventory\` pattern has widened into its whole directory."
    else
      pass=$((pass + 1))
      printf '  %-40s -> none (negative control)\n' "$path"
    fi
  done

  if [ "$controls" -lt 1 ]; then
    echo "::error::the negative control checked ZERO non-builder files — with nothing to widen into, this invariant proves nothing."
    return 1
  fi
  if [ "$pass" -lt 1 ]; then
    echo "::error::the signal-wiring check ran ZERO cases."
    return 1
  fi
  echo "Results: $pass passed, $fail failed, $((pass + fail)) total (signal wiring)"
  [ "$fail" -eq 0 ] || return 1
  echo ""

  # ── invariant 2: cross-stack readers ─────────────────────────────────────
  scan_cross_stack || return 1
  return 0
}

# ── self-test ───────────────────────────────────────────────────────────────
SCRATCH=""
cleanup() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  return 0
}

# make_tree <dir> <extra builder basename or ''> — a minimal repo-shaped tree
# with three std builders (one of them named OUTSIDE the legacy
# `std(_[a-z_]+)?\.dart` shape when asked), a non-builder sibling, gen_std.dart,
# and an `other/` stack. Initialised as a git repo because the cross-stack scan
# enumerates tracked files.
make_tree() {
  local dir="$1" extra="${2:-}"
  mkdir -p "$dir/dart/shared/lib" "$dir/dart/shared/bin" "$dir/other/src"
  local b
  for b in std std_collections; do
    printf 'Module build%sModule() {\n  return Module();\n}\n' \
      "$(python3 -c "import sys;print('Std'+''.join(p.capitalize() for p in sys.argv[1].split('_')[1:]))" "$b")" \
      >"$dir/dart/shared/lib/$b.dart"
  done
  printf 'const x = 1;\n' >"$dir/dart/shared/lib/ball_proto.dart"
  if [ -n "$extra" ]; then
    printf 'Module buildStdRegexModule() {\n  return Module();\n}\n' >"$dir/dart/shared/lib/$extra.dart"
  fi
  cat >"$dir/dart/shared/bin/gen_std.dart" <<'EOF'
void main(List<String> args) {
  final outputDir = args[0];
  File('$outputDir/std.json').writeAsStringSync('');
  File('$outputDir/std.bin').writeAsBytesSync([]);
}
EOF
  printf '// nothing to see here\nconst a = 1;\n' >"$dir/other/src/a.ts"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" add -A 2>/dev/null
}

# make_detect <file> <pattern|LEGACY|NOBLOCK> — a classifier with the real
# script's contract (sourceable, defines `ball_classify_stacks`) whose
# std_inventory match set is expressed in one of three shapes:
#   <pattern>  the post-#774 shape: a generated, marked block
#   LEGACY     the pre-#774 shape: a hand-written inline regex, no markers
#   NOBLOCK    a pattern variable, but no markers around it
make_detect() {
  local file="$1" mode="$2"
  {
    echo '#!/usr/bin/env bash'
    echo 'ball_classify_stacks() {'
    echo '  local files="$1"'
    echo '  m() { grep -qE "$1" <<<"$files"; }'
    echo '  local infra=false'
    echo "  if grep -qvE '^(dart/|other/|rust/)' <<<\"\$files\"; then infra=true; fi"
    echo '  local self_host=false'
    echo "  if m '^dart/shared/lib/cli_core\\.dart\$'; then self_host=true; fi"
    echo '  local std_inventory=false'
    case "$mode" in
    LEGACY)
      echo "  if m '^dart/shared/lib/std(_[a-z_]+)?\\.dart\$|^dart/shared/std\\.(json|bin)\$'; then std_inventory=true; fi"
      ;;
    NOBLOCK)
      echo "  local std_inventory_re='^dart/shared/lib/std\\.dart\$'"
      echo '  if m "$std_inventory_re"; then std_inventory=true; fi'
      ;;
    *)
      echo "  $BEGIN_MARK"
      echo "  local std_inventory_re='$mode'"
      echo "  $END_MARK"
      echo '  if m "$std_inventory_re"; then std_inventory=true; fi'
      ;;
    esac
    echo '  if m '"'"'^rust/'"'"' || [ "$std_inventory" = true ]; then echo "rust=true"; else echo "rust=false"; fi'
    echo '  echo "self_host=$self_host"'
    echo '  echo "infra=$infra"'
    echo '}'
  } >"$file"
}

self_test() {
  local pass=0 fail=0
  SCRATCH="$(mktemp -d)"
  trap cleanup EXIT

  # expect <name> <want-exit> <root> <detect> [needle...]
  # run_gate reads the script-level ROOT/DETECT/MIN_BUILDERS/WRITE, so they are
  # assigned outright rather than as a `VAR=x run_gate` prefix: bash keeps such
  # assignments after a FUNCTION returns, which would silently leak the last
  # case's fixture into the next one.
  expect() {
    local name="$1" want="$2" root="$3" detect="$4"
    shift 4
    local out rc=0 ok=1 needle
    ROOT="$root"
    DETECT="$detect"
    MIN_BUILDERS=1
    WRITE=0
    out="$(run_gate 2>&1)" || rc=$?
    [ "$rc" -eq "$want" ] || ok=0
    for needle in "$@"; do
      case "$out" in
      *"$needle"*) ;;
      *) ok=0 ;;
      esac
    done
    if [ "$ok" -eq 1 ]; then
      pass=$((pass + 1))
      echo "PASS $name"
    else
      fail=$((fail + 1))
      echo "FAIL $name (exit $rc, wanted $want)"
      printf '%s\n' "$out" | sed 's/^/    | /'
    fi
  }

  local t_plain="$SCRATCH/plain" t_extra="$SCRATCH/extra"
  make_tree "$t_plain"
  make_tree "$t_extra" regex_std

  local plain_pattern='^dart/shared/lib/(std|std_collections)\.dart$|^dart/shared/std\.bin$|^dart/shared/std\.json$'
  local extra_pattern='^dart/shared/lib/(regex_std|std|std_collections)\.dart$|^dart/shared/std\.bin$|^dart/shared/std\.json$'

  local d_ok="$SCRATCH/d_ok.sh" d_legacy="$SCRATCH/d_legacy.sh"
  local d_noblock="$SCRATCH/d_noblock.sh" d_stale="$SCRATCH/d_stale.sh"
  make_detect "$d_ok" "$plain_pattern"
  make_detect "$d_legacy" LEGACY
  make_detect "$d_noblock" NOBLOCK
  make_detect "$d_stale" "$plain_pattern"

  # 1. The shape this guard exists to produce: a generated block carrying
  #    exactly the derived pattern. Everything downstream must then pass too.
  expect "derived-block-is-green" 0 "$t_plain" "$d_ok" \
    "derived pattern matches the block" "0 failed, 1 total (derived pattern)" \
    "negative control" "0 failed"

  # 2. THE #774 CASE. A builder named outside `std(_[a-z_]+)?\.dart`
  #    (`regex_std.dart`) exists; the committed block still lists the other two.
  #    The guard must name it rather than let the signal run stale.
  expect "off-shape-builder-is-caught" 1 "$t_extra" "$d_stale" \
    "is STALE" "regex_std"

  # 3. The pre-#774 shape itself: a hand-written regex with no generated block
  #    is a description of the match set, not a derivation of it, and is
  #    rejected even though it happens to match every builder in this tree.
  expect "hand-written-shape-regex-is-rejected" 1 "$t_plain" "$d_legacy" \
    "carries no generated" "hand-written shape regex"
  expect "missing-block-markers-rejected" 1 "$t_plain" "$d_noblock" \
    "carries no generated"

  # 4. Negative control on the guard's own derivation: a tree whose builders
  #    the classifier does not match must be RED, or invariant 3 is decoration.
  local d_narrow="$SCRATCH/d_narrow.sh"
  make_detect "$d_narrow" '^dart/shared/lib/std\.dart$|^dart/shared/std\.bin$|^dart/shared/std\.json$'
  expect "under-matching-pattern-is-caught" 1 "$t_plain" "$d_narrow" "is STALE"

  # 5. Negative control the other way: a pattern that swallows the whole
  #    directory passes invariant 1 only if it IS the derived one, so force the
  #    widened case through a hand-built block whose regex is too broad.
  local d_wide="$SCRATCH/d_wide.sh"
  make_detect "$d_wide" '^dart/shared/lib/.*\.dart$|^dart/shared/std\.bin$|^dart/shared/std\.json$'
  expect "widened-pattern-is-caught" 1 "$t_plain" "$d_wide" "is STALE"

  # 6. A stack outside the OR-list that reads the inventory in CODE is caught,
  #    and the same reference in a COMMENT is not.
  local t_reader="$SCRATCH/reader"
  make_tree "$t_reader"
  printf 'const p = "dart/shared/lib/std_collections.dart";\n' >"$t_reader/other/src/reader.ts"
  git -C "$t_reader" add -A 2>/dev/null
  expect "off-list-code-reader-is-caught" 1 "$t_reader" "$d_ok" \
    "references the" "other/src/reader.ts"

  local t_comment="$SCRATCH/comment"
  make_tree "$t_comment"
  printf '// see dart/shared/lib/std_collections.dart for the declaration\nconst p = 1;\n' \
    >"$t_comment/other/src/prose.ts"
  git -C "$t_comment" add -A 2>/dev/null
  expect "off-list-comment-is-allowed" 0 "$t_comment" "$d_ok" "cross-stack scan"

  # 6b. The carve-out the scan rests on: a DIAGNOSTIC MESSAGE that names the
  #     Dart inventory is prose in a string, not an off-disk read. ts/ and cpp/
  #     carry five of these today; flagging them would make the gate noise.
  local t_message="$SCRATCH/message"
  make_tree "$t_message"
  printf 'const e = "dart/shared/lib/std_io.dart declares this function; add a lowering";\n' \
    >"$t_message/other/src/message.ts"
  git -C "$t_message" add -A 2>/dev/null
  expect "diagnostic-message-string-is-allowed" 0 "$t_message" "$d_ok" "cross-stack scan"

  # 6c. `//go:embed` LOOKS like a comment and IS an off-disk read, so it must
  #     survive comment-stripping.
  local t_embed="$SCRATCH/embed"
  make_tree "$t_embed"
  mkdir -p "$t_embed/other/embed"
  printf '//go:embed dart/shared/std.json\nvar stdJSON string\n' >"$t_embed/other/embed/e.go"
  git -C "$t_embed" add -A 2>/dev/null
  expect "go-embed-directive-is-caught" 1 "$t_embed" "$d_ok" "other/embed/e.go"

  # 7. The segmented form a path join produces is caught too — a literal-only
  #    scan would read `join("dart", "shared", "std.json")` as clean.
  local t_join="$SCRATCH/join"
  make_tree "$t_join"
  mkdir -p "$t_join/other/tool"
  printf 'import os\np = os.path.join(ROOT, "dart", "shared", "std.json")\n' \
    >"$t_join/other/tool/read.py"
  git -C "$t_join" add -A 2>/dev/null
  expect "segmented-path-join-is-caught" 1 "$t_join" "$d_ok" "segmented dart/shared path join"

  # 8. Floors. A derivation that finds fewer builders than the floor, and a
  #    classifier nobody wired the signal into, are both hard errors.
  local out rc=0
  ROOT="$t_plain"
  DETECT="$d_ok"
  MIN_BUILDERS=99
  WRITE=0
  out="$(run_gate 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && [[ "$out" == *"floor 99"* ]]; then
    pass=$((pass + 1))
    echo "PASS builder-floor-bites"
  else
    fail=$((fail + 1))
    echo "FAIL builder-floor-bites (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/    | /'
  fi

  local d_unwired="$SCRATCH/d_unwired.sh"
  make_detect "$d_unwired" "$plain_pattern"
  sed -i 's/|| \[ "\$std_inventory" = true \]//' "$d_unwired"
  expect "unwired-signal-is-caught" 1 "$t_plain" "$d_unwired" "read by nobody"

  # 9. --write actually produces the block the gate then accepts, and it
  #    REFUSES a file with no markers rather than inventing one.
  local d_written="$SCRATCH/d_written.sh"
  make_detect "$d_written" "$plain_pattern"
  ROOT="$t_extra"
  DETECT="$d_written"
  MIN_BUILDERS=1
  WRITE=1
  run_gate >/dev/null 2>&1
  expect "write-produces-an-accepted-block" 0 "$t_extra" "$d_written" \
    "derived pattern matches the block" "regex_std"

  local d_markerless="$SCRATCH/d_markerless.sh" wrc=0
  make_detect "$d_markerless" LEGACY
  ROOT="$t_plain"
  DETECT="$d_markerless"
  MIN_BUILDERS=1
  WRITE=1
  out="$(run_gate 2>&1)" || wrc=$?
  if [ "$wrc" -eq 1 ] && [[ "$out" == *"will not invent a block"* ]]; then
    pass=$((pass + 1))
    echo "PASS write-refuses-a-markerless-file"
  else
    fail=$((fail + 1))
    echo "FAIL write-refuses-a-markerless-file (exit $wrc)"
    printf '%s\n' "$out" | sed 's/^/    | /'
  fi

  local total=$((pass + fail))
  if [ "$total" -lt 1 ]; then
    echo "::error::self-test ran zero cases"
    exit 1
  fi
  echo "Results: $pass passed, $fail failed, $total total (self-test)"
  [ "$fail" -eq 0 ] || exit 1
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit 0
fi

run_gate
