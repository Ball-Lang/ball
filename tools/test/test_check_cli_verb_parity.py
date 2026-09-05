#!/usr/bin/env python3
"""Self-test for tools/check_cli_verb_parity.py (issue #570).

A measuring instrument must prove itself before its number means anything —
the same discipline the Tier A coverage-study harnesses' self-tests enforce in
the go/python/rust/csharp jobs. This one proves the verb-parity gate:

* it extracts the right verb set from each REAL help-text FORMAT this repo
  ships (Dart's `Commands:`, TS's `COMMANDS`, Go/Python's `Commands:` with
  wrapped continuation lines, clap's and System.CommandLine's `Commands:`),
  including not mistaking a wrapped description line for a verb;
* it FAILS on a CLI missing a portable verb — the exact defect #570 fixed, so
  the gate is shown to go red on the pre-#570 Go/Python verb set;
* it FAILS on an undeclared extra verb, and on a stale `missing` carve-out;
* its positive floors bite: too few CLIs, no CLIs, and a truncated manifest all
  fail rather than silently passing.

Run: python tools/test/test_check_cli_verb_parity.py   (exit 0 = all cases pass)
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CHECKER = REPO / "tools" / "check_cli_verb_parity.py"

FAILURES: list[str] = []
CHECKS = 0


def expect(condition: bool, label: str) -> None:
    global CHECKS
    CHECKS += 1
    if condition:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        FAILURES.append(label)


# ── 1. Help-text extraction, across every format this repo ships ──────────────

# Verbatim shapes (trimmed) of each CLI's real --help output.
HELP_SAMPLES: dict[str, tuple[str, set[str]]] = {
    "dart (Commands: + a dashed verb)": (
        """Ball Language CLI v0.4.0

Usage: ball <command> [arguments]

Commands:
  info     <input.ball.json>   Inspect ball program structure
  round-trip <input.dart>      Encode -> compile -> show diff
  version                      Print version

Options:
  --output <file>              Output file (default: stdout)
""",
        {"info", "round-trip", "version"},
    ),
    "ts (uppercase COMMANDS, no colon)": (
        """ball - the Ball language CLI (v1.68.4)

USAGE
  ball <command> [options]

COMMANDS
  run <program.ball.json>        Execute a Ball program and print stdout.
  audit <program.ball.json>      Static capability analysis (I/O, fs, network, ...).

OPTIONS
  -h, --help                     Print this help message.
""",
        {"run", "audit"},
    ),
    "go/python (wrapped continuation lines)": (
        """ball - the Ball language CLI (Go toolchain)

Commands:
  run      <program.ball.json>   Execute a Ball program via the self-hosted engine
                                 (requires a build with -tags selfhost)
  encode   <source.go>           Encode a Go source file into a Ball program
                                 (-lib: no func main() required; non-runnable)
  version                        Print the CLI version

Programs are read as proto3 JSON.
""",
        {"run", "encode", "version"},
    ),
    "clap / System.CommandLine (Commands: + a help pseudo-verb)": (
        """Usage: ball <COMMAND>

Commands:
  run      Execute a Ball program
  check    Validate a Ball program
  help     Print this message or the help of the given subcommand(s)

Options:
  -h, --help     Print help
""",
        {"run", "check", "help"},
    ),
}


def test_extraction() -> None:
    print("extract_verbs over every real help-text format:")
    sys.path.insert(0, str(REPO / "tools"))
    from check_cli_verb_parity import extract_verbs  # noqa: PLC0415

    for label, (text, expected) in HELP_SAMPLES.items():
        got = extract_verbs(text)
        expect(got == expected, f"{label}: {sorted(got)} == {sorted(expected)}")


# ── 2. End-to-end runs against synthetic CLIs + manifests ─────────────────────

def fake_cli(tmp: Path, name: str, verbs: list[str]) -> str:
    """A one-file CLI whose --help lists `verbs` in a Commands block."""
    body = "\n".join(f"  {v}     do {v}" for v in verbs)
    script = tmp / f"{name}_cli.py"
    script.write_text(
        "import sys\n"
        f'print("""ball - fake {name}\n\nCommands:\n{body}\n\nOptions:\n  -h, --help  help\n""")\n',
        encoding="utf-8",
    )
    return f"{sys.executable} {script}"


def write_manifest(tmp: Path, manifest: dict) -> Path:
    path = tmp / "manifest.json"
    path.write_text(json.dumps(manifest), encoding="utf-8")
    return path


def run_checker(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(CHECKER), *args],
        cwd=str(REPO), capture_output=True, text=True, timeout=300,
    )


BASE_MANIFEST = {
    "portable": ["run", "compile", "encode", "check", "info", "validate", "tree", "version"],
    "ignore": ["help"],
    "clis": {
        "alpha": {"extras": [], "missing": []},
        "beta": {"extras": [], "missing": []},
    },
}
FULL = BASE_MANIFEST["portable"]


def test_end_to_end(tmp: Path) -> None:
    print("\nend-to-end gate behaviour:")

    manifest = write_manifest(tmp, BASE_MANIFEST)
    alpha_full = fake_cli(tmp, "alpha", FULL)
    beta_full = fake_cli(tmp, "beta", FULL)

    r = run_checker([
        "--cli", f"alpha={alpha_full}", "--cli", f"beta={beta_full}",
        "--manifest", str(manifest), "--min-clis", "2",
    ])
    expect(r.returncode == 0, f"two conformant CLIs pass (rc={r.returncode}, {r.stderr.strip()})")
    expect("8 verbs" in r.stdout, "the pass line reports the portable set size")

    # The exact pre-#570 defect: a CLI with only the core four.
    beta_core4 = fake_cli(tmp, "beta", ["run", "compile", "encode", "check"])
    r = run_checker([
        "--cli", f"alpha={alpha_full}", "--cli", f"beta={beta_core4}",
        "--manifest", str(manifest), "--min-clis", "2",
    ])
    expect(r.returncode == 1, "a CLI missing info/validate/tree/version FAILS")
    for verb in ("info", "validate", "tree", "version"):
        expect(f"missing the portable verb '{verb}'" in r.stderr, f"  ... and names {verb!r}")

    # An undeclared extra verb.
    alpha_extra = fake_cli(tmp, "alpha", [*FULL, "audit"])
    r = run_checker([
        "--cli", f"alpha={alpha_extra}", "--manifest", str(manifest),
    ])
    expect(r.returncode == 1, "an undeclared extra verb FAILS")
    expect("exposes 'audit'" in r.stderr, "  ... and names it")

    # ... which the manifest can accept, deliberately.
    accepted = json.loads(json.dumps(BASE_MANIFEST))
    accepted["clis"]["alpha"]["extras"] = ["audit"]
    r = run_checker([
        "--cli", f"alpha={alpha_extra}", "--manifest", str(write_manifest(tmp, accepted)),
    ])
    expect(r.returncode == 0, "a DECLARED extra verb passes")

    # A stale carve-out: `missing` that is no longer missing.
    stale = json.loads(json.dumps(BASE_MANIFEST))
    stale["clis"]["alpha"]["missing"] = ["tree"]
    r = run_checker([
        "--cli", f"alpha={alpha_full}", "--manifest", str(write_manifest(tmp, stale)),
    ])
    expect(r.returncode == 1, "a stale `missing` carve-out FAILS")
    expect("declares 'tree' as missing" in r.stderr, "  ... and says so")

    # A CLI the manifest never declares.
    r = run_checker([
        "--cli", f"gamma={alpha_full}", "--manifest", str(manifest),
    ])
    expect(r.returncode == 1, "an undeclared CLI FAILS")

    # ── Positive floors ──
    r = run_checker([
        "--cli", f"alpha={alpha_full}", "--manifest", str(manifest), "--min-clis", "4",
    ])
    expect(r.returncode == 1, "too few CLIs FAILS (--min-clis floor)")

    r = run_checker(["--manifest", str(manifest)])
    expect(r.returncode == 1, "no --cli at all FAILS")

    truncated = {"portable": ["run"], "ignore": [], "clis": {"alpha": {}}}
    r = run_checker([
        "--cli", f"alpha={alpha_full}", "--manifest", str(write_manifest(tmp, truncated)),
    ])
    expect(r.returncode == 1, "a truncated portable set FAILS (contract floor)")

    # A CLI whose --help crashes must never read as "no verbs".
    broken = tmp / "broken_cli.py"
    broken.write_text("import sys\nsys.exit(3)\n", encoding="utf-8")
    r = run_checker([
        "--cli", f"alpha={sys.executable} {broken}", "--manifest", str(manifest),
    ])
    expect(r.returncode != 0, "a crashing --help FAILS")


def main() -> int:
    if not CHECKER.is_file():
        print(f"[self-test] {CHECKER} is missing", file=sys.stderr)
        return 1
    test_extraction()
    with tempfile.TemporaryDirectory(prefix="cli-verb-parity-selftest-") as tmpdir:
        test_end_to_end(Path(tmpdir))

    print(f"\n[self-test] {CHECKS} checks, {len(FAILURES)} failed")
    # Positive floor on the self-test itself.
    if CHECKS < 15:
        print(f"[self-test] only {CHECKS} checks ran; the self-test itself is broken",
              file=sys.stderr)
        return 1
    if FAILURES:
        for f in FAILURES:
            print(f"[self-test] FAILED: {f}", file=sys.stderr)
        return 1
    print("[self-test] OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
