#!/usr/bin/env python3
"""Synthesize a file:// Go module proxy for the six Ball Go modules.

Why this exists (issue #361): the only way to prove that an EXTERNAL consumer
can resolve `github.com/ball-lang/ball/go/<module>` is to resolve it the way
the `go` command does for a real consumer — through a module proxy, with no
`go.work`, no sibling directories on disk, and no `replace` directives. The
published go.mod files name intra-repo dependencies at one version (the Go
module line, currently v0.2.0), which is only resolvable off proxy.golang.org
once the matching `go/<module>/vX.Y.Z` git tags are pushed. This script builds
the exact proxy tree those tags would produce, from the current checkout, so CI
can run that end-to-end resolution BEFORE (and independently of) any tag being
cut.

The version is DERIVED, never passed in: `--print-version` is the single source
of truth for both this proxy and .github/workflows/tag-go-modules.yml, so the
proxy CI proves is, by construction, the proxy the tags will publish. `--version`
is kept only as a redundant cross-check and must equal the derived version — see
`module_version` for the four invariants asserted before it is printed.

The proxy layout is the one documented at https://go.dev/ref/mod#goproxy-protocol:

    <root>/<module path>/@v/list
    <root>/<module path>/@v/<version>.info
    <root>/<module path>/@v/<version>.mod
    <root>/<module path>/@v/<version>.zip

and the zip is the module zip file format from https://go.dev/ref/mod#zip-files:
every path is prefixed with `<module path>@<version>/`.

File selection uses `git ls-files`, so the zip holds exactly the tracked files a
git tag would carry — and only those: any gitignored build output is excluded,
which is what makes the resulting module hashes identical to the ones
proxy.golang.org will compute for the real tag. Since #586 the two generated
artifacts a consumer needs at runtime (`go/engine/compiled/compiled_engine.go`
and `go/cli/compiled/compiled_cli.go`) are TRACKED, so they are inside the zips
and a `go install`-acquired `ball` can run programs and the cli-core verbs;
`Ball Artifact Freshness` in ci.yml is what keeps them honest.

Usage:

    python3 tools/go-module-proxy/build_local_proxy.py <out-dir> [--version vX.Y.Z]
    python3 tools/go-module-proxy/build_local_proxy.py --print-version

Prints the `file://` URL of the generated proxy root on stdout (and nothing
else), so a caller can do `GOPROXY="$(build_local_proxy.py "$dir"),…"`.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import zipfile

# A fixed, deterministic timestamp: the proxy protocol requires a .info file
# with a Time field, but nothing in this smoke depends on its value, and a
# fixed one keeps repeated runs byte-identical.
INFO_TIME = "2026-01-01T00:00:00Z"

_USE_BLOCK = re.compile(r"use\s*\((?P<body>[^)]*)\)", re.MULTILINE)
_MODULE_LINE = re.compile(r"^module\s+(?P<path>\S+)\s*$", re.MULTILINE)
_INTRA_REQUIRE = re.compile(
    r"^\s*(?:require\s+)?github\.com/ball-lang/ball/go/(?P<dep>\w+)\s+(?P<version>v\d+\.\d+\.\d+)",
    re.MULTILINE,
)
_REPLACE_LINE = re.compile(r"^\s*replace\s+", re.MULTILINE)
_WORK_REPLACE = re.compile(
    r"^\s*github\.com/ball-lang/ball/go/(?P<dep>\w+)\s+(?P<version>v\d+\.\d+\.\d+)\s*=>",
    re.MULTILINE,
)
_SEMVER = re.compile(r"^v\d+\.\d+\.\d+$")


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


def workspace_modules(root: pathlib.Path) -> list[str]:
    """The module directories named by go/go.work's `use` block, e.g. ["cli", …].

    Reading them out of go.work (instead of hardcoding a list) means a seventh
    Go module added to the workspace is covered by this smoke automatically.
    """
    text = (root / "go" / "go.work").read_text(encoding="utf-8")
    match = _USE_BLOCK.search(text)
    if match is None:
        raise SystemExit("go/go.work has no `use (...)` block")
    dirs = []
    for raw in match.group("body").splitlines():
        line = raw.split("//", 1)[0].strip()
        if not line:
            continue
        dirs.append(line.lstrip("./"))
    if not dirs:
        raise SystemExit("go/go.work's `use (...)` block is empty")
    # Cross-check against the module directories actually on disk. This script
    # enumerates go.work's `use` block; tools/go-module-proxy/tag_go_modules.sh
    # enumerates `go/*/go.mod` from DISK. If the two sets ever diverge, the tags
    # that get cut cover a DIFFERENT module set than the proxy this smoke
    # proved — a seventh module added to the tree but not to go.work would be
    # tagged untested, and a module dropped from the tree but left in go.work
    # would fail the tag run after a green smoke.
    on_disk = sorted(p.parent.name for p in sorted((root / "go").glob("*/go.mod")))
    if sorted(dirs) != on_disk:
        raise SystemExit(
            "go/go.work's `use (...)` block and the module directories on disk "
            "disagree; the tags are cut from the on-disk set, so they must match "
            f"exactly:\n  go.work use: {sorted(dirs)}\n  on disk:     {on_disk}"
        )
    return sorted(dirs)


def module_path(gomod: pathlib.Path) -> str:
    match = _MODULE_LINE.search(gomod.read_text(encoding="utf-8"))
    if match is None:
        raise SystemExit(f"{gomod} has no `module` line")
    return match.group("path")


def module_version(root: pathlib.Path) -> str:
    """The single version every module names for its intra-repo dependencies.

    This is the version the `go/<module>/vX.Y.Z` tags must carry, so it is the
    one source of truth for both this proxy and the release tagging job. Every
    intra-repo `require` across the workspace must agree, no module's go.mod may
    carry a `replace` directive (`go install` rejects a module whose go.mod has
    one), and go/go.work's own versioned `replace` pins must name that same
    version and cover every required intra-repo module — all three are asserted
    here so a bad edit fails loudly rather than quietly producing an
    unresolvable module set.

    The go.work cross-check is what makes a version bump a single edit that
    cannot half-land. go.work pins `github.com/ball-lang/ball/go/<m> vX.Y.Z =>
    ./<m>`; if that version drifts from the go.mod `require` lines, the `go`
    job's Build step fails with "unknown revision go/<m>/vX.Y.Z" — loud, but
    only after the workspace is already inconsistent. Asserting it here fails in
    this smoke, at the one place that already knows both numbers.
    """
    versions: dict[str, str] = {}
    for mod_dir in workspace_modules(root):
        gomod = root / "go" / mod_dir / "go.mod"
        text = gomod.read_text(encoding="utf-8")
        if _REPLACE_LINE.search(text):
            raise SystemExit(
                f"{gomod} carries a `replace` directive — `go install` rejects those "
                "(issue #361). Put the local pin in go/go.work instead."
            )
        for match in _INTRA_REQUIRE.finditer(text):
            versions[f"go/{mod_dir} -> {match.group('dep')}"] = match.group("version")
    if not versions:
        raise SystemExit("no intra-repo `require` found in any go/*/go.mod")
    distinct = sorted(set(versions.values()))
    if len(distinct) != 1:
        detail = "\n".join(f"  {k}: {v}" for k, v in sorted(versions.items()))
        raise SystemExit(
            "the intra-repo module versions disagree; every go/*/go.mod must name "
            f"the same version:\n{detail}"
        )
    version = distinct[0]

    work_text = (root / "go" / "go.work").read_text(encoding="utf-8")
    work_pins = {
        match.group("dep"): match.group("version")
        for match in _WORK_REPLACE.finditer(work_text)
    }
    if not work_pins:
        raise SystemExit(
            "go/go.work has no versioned `replace github.com/ball-lang/ball/go/<m> "
            "vX.Y.Z => ./<m>` pins — without them the workspace resolves the "
            "intra-repo requires off the public proxy instead of this tree"
        )
    drifted = sorted(
        f"  go/{dep}: go.work pins {pinned}, go.mod requires {version}"
        for dep, pinned in work_pins.items()
        if pinned != version
    )
    if drifted:
        raise SystemExit(
            "go/go.work's replace pins disagree with the go.mod requires; bump "
            "both in lockstep:\n" + "\n".join(drifted)
        )
    required = {key.split(" -> ", 1)[1] for key in versions}
    unpinned = sorted(required - set(work_pins))
    if unpinned:
        detail = ", ".join(f"go/{m}" for m in unpinned)
        raise SystemExit(
            "go/go.work does not pin every required intra-repo module back to "
            f"this tree; missing: {detail}"
        )
    return version


def tracked_files(root: pathlib.Path, rel_dir: str) -> list[str]:
    """Tracked files under rel_dir, as paths relative to rel_dir."""
    out = subprocess.run(
        ["git", "ls-files", "-z", "--", rel_dir],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    prefix = rel_dir.rstrip("/") + "/"
    files = []
    for entry in out.split(b"\0"):
        if not entry:
            continue
        path = entry.decode("utf-8")
        if not path.startswith(prefix):
            continue
        files.append(path[len(prefix):])
    if not files:
        raise SystemExit(f"no tracked files under {rel_dir} — refusing to build an empty module zip")
    return sorted(files)


def build(root: pathlib.Path, out_dir: pathlib.Path, version: str) -> None:
    for mod_dir in workspace_modules(root):
        rel_dir = f"go/{mod_dir}"
        src = root / rel_dir
        path = module_path(src / "go.mod")
        at_v = out_dir / path / "@v"
        at_v.mkdir(parents=True, exist_ok=True)

        (at_v / "list").write_text(f"{version}\n", encoding="utf-8", newline="\n")
        (at_v / f"{version}.info").write_text(
            '{"Version":%s,"Time":%s}\n' % (f'"{version}"', f'"{INFO_TIME}"'),
            encoding="utf-8",
            newline="\n",
        )
        (at_v / f"{version}.mod").write_bytes((src / "go.mod").read_bytes())

        zip_prefix = f"{path}@{version}/"
        with zipfile.ZipFile(at_v / f"{version}.zip", "w", zipfile.ZIP_DEFLATED) as zf:
            for rel in tracked_files(root, rel_dir):
                zf.writestr(zip_prefix + rel, (src / rel).read_bytes())


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "out_dir",
        nargs="?",
        help="directory to write the proxy tree into (omit with --print-version)",
    )
    parser.add_argument(
        "--version",
        default=None,
        help=(
            "redundant cross-check: must EQUAL the version every go/*/go.mod "
            "names (which is the version the go/<module>/vX.Y.Z tags carry); "
            "it is not an override"
        ),
    )
    parser.add_argument(
        "--root",
        default=None,
        help="repository root to read go/go.work and go/*/go.mod from (default: this checkout)",
    )
    parser.add_argument(
        "--print-version",
        action="store_true",
        help="print the version every go/*/go.mod names and exit (used by the release tagging job)",
    )
    args = parser.parse_args(argv)

    root = pathlib.Path(args.root).resolve() if args.root else repo_root()
    # ALWAYS derive, even when --version is given: module_version() is where the
    # four cross-file invariants are asserted, and skipping it for an explicit
    # --version is how a half-bumped tree used to synthesize a perfectly
    # resolvable proxy at a version no tag would ever carry.
    declared = module_version(root)
    if not _SEMVER.fullmatch(declared):
        raise SystemExit(f"module version must look like vX.Y.Z, got {declared!r}")
    version = args.version or declared
    if version != declared:
        raise SystemExit(
            f"--version {version} disagrees with the version go/*/go.mod name "
            f"({declared}). The synthesized proxy MUST carry the version the "
            "go/<module>/vX.Y.Z tags will carry: tag-go-modules.yml derives the "
            "tag from --print-version, and a module zip whose go.mod requires a "
            "version this proxy does not serve either falls through to the "
            "PUBLIC proxy (a false pass, measuring released code instead of this "
            "commit) or fails with 'unknown revision'. To move the line, run "
            "tools/go-module-proxy/bump_go_modules.sh <vX.Y.Z>."
        )

    if args.print_version:
        print(version)
        return 0
    if not args.out_dir:
        parser.error("out_dir is required unless --print-version is given")

    out_dir = pathlib.Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    build(root, out_dir, version)
    print(out_dir.as_uri())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
