<!-- Parent: ../AGENTS.md -->

# tools

## Purpose
Repo-wide automation scripts for coverage collection, conformance descriptor generation, and Editions golden regeneration. These are run by CI and by developers; they are not part of any Ball package.

## Key Files / Contents

| File | Language | What it does |
|------|----------|--------------|
| `coverage_dart.dart` | Dart | Collects and merges Dart code-coverage across the workspace; used by CI coverage step. Run with `--exclude-tags slow` to skip slow round-trips. |
| `gen_edition_defaults.ps1` | PowerShell | Regenerates `tests/editions/featureset_defaults.binpb` from protoc output. Supports `--check` for drift detection. |
| `gen_edition_defaults.sh` | Bash | POSIX equivalent of the above; use on Linux/macOS/WSL. |
| `gen_conformance_descriptors.ps1` | PowerShell | Generates proto descriptor fixtures under `tests/editions/descriptors/`. |
| `gen_conformance_descriptors.sh` | Bash | POSIX equivalent of the above. |
| `check_cli_verb_parity.py` + `cli_verbs.json` | Python | **The cross-CLI verb-set gate** (issue #570, epic #361): runs each shipped `ball`'s `--help`, extracts its verb set, and checks it against the contract in `cli_verbs.json` (the portable verbs every `ball` must expose, plus each CLI's declared extras and carve-outs). Editing `cli_verbs.json` is how a difference gets ACCEPTED, in a reviewed diff, instead of drifting silently. Run by the always-on `CLI Verb Parity` job (dart/ts/go/python) and, one `--cli` each, by the `rust` and `csharp` jobs which already build their CLI. Its self-test is `test/test_check_cli_verb_parity.py`. |
| `gen_cli_core_goldens.py` | Python | Second half of the cli-core golden pipeline: selects the five parity fixtures out of `dart run cli/tool/gen_cli_parity_goldens.dart`'s output and writes `tests/cli_core_goldens/`, adding the trailing newline every CLI's `writeln` contributes. See that directory's README. |
| `vcpkg-port/` | `make_ci_overlay.py`, `test/test_selfhost_asset_wiring.sh` | **Staging area for an external registry.** Draft `ports/ball-lang/{vcpkg.json,portfile.cmake}` for the `microsoft/vcpkg` submission (issue #368). The port files themselves are never built by this repo's CMake; `make_ci_overlay.py` derives a hermetic CI overlay from them (swapping both network fetches for local paths) for `ci.yml`'s `vcpkg port smoke (x64-linux)` job, and `test/test_selfhost_asset_wiring.sh` pins the self-host sidecar wiring across `release-cpp.yml` / the portfile / the overlay generator / the vcpkg job. See `vcpkg-port/README.md` for the verified submission flow and the maintainer-only steps left to do. |

## For AI Agents

- Run `gen_edition_defaults.{ps1,sh} --check` after any protoc upgrade to detect drift against the golden `featureset_defaults.binpb`; regenerate if drift is reported.
- `coverage_dart.dart` is the authoritative coverage collector; always use `--exclude-tags slow` in non-release CI to avoid timeout.
- These scripts are invoked directly (`dart run tools/coverage_dart.dart`, `tools/gen_edition_defaults.ps1`); they are not pub packages and have no `pubspec.yaml`.
- Do not add per-language tooling here — language-specific scripts belong under their respective `dart/`, `ts/`, or `cpp/` directories. `vcpkg-port/` is the one deliberate exception: it is packaging/distribution staging for an external registry, not a build/test script, and doesn't belong under `cpp/` because its `ports/` tree must never be picked up by this repo's own CMake.
