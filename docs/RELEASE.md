# Release & Publishing Pipeline

How a commit on `main` becomes published packages. Two independent lanes —
npm (TypeScript) and pub.dev (Dart) — both cut from the same trunk, both
fully automated. Verified end-to-end 2026-07-02 (npm 1.3.4; pub.dev
0.3.0+1 across all nine packages).

## npm lane (@ball-lang/engine, cli, compiler, encoder)

```
push to main
  └► release.yml
       ├─ Pre-release tests (proto lint, Dart suites, TS engine)
       └─ semantic-release (.releaserc.json)
            ├─ analyzes conventional commits → next repo version vX.Y.Z
            ├─ bumps ALL FOUR ts/*/package.json versions in LOCKSTEP
            ├─ commits CHANGELOG + package.jsons ("chore(release): X.Y.Z [skip ci]")
            ├─ tags vX.Y.Z + creates the GitHub release
            └─ successCmd (@semantic-release/exec) → released_version output
       └► gh workflow run publish-npm.yml --ref vX.Y.Z      ← EXPLICIT dispatch
            └► publish-npm.yml: build+test all four packages, then
               npm publish --provenance via OIDC trusted publishing
```

**Why the explicit dispatch:** semantic-release authenticates with the
default `GITHUB_TOKEN`, and GitHub suppresses workflow triggers for events
created with it (recursion protection). The `release: published` trigger on
publish-npm.yml therefore never fires for automated releases — npm silently
froze at 0.2.x for months before the dispatch existed. The `release:` trigger
is kept only for manually-published releases.

**Versioning:** all four npm packages share the repo version (lockstep,
`.releaserc.json` has one `@semantic-release/npm` entry per `pkgRoot`).

**ts/cli's engine dependency** is `file:../engine` in-repo — dev and CI always
build/test against the engine being released, never a stale registry copy.
publish-npm.yml rewrites it to `^<published engine version>` immediately
before `npm publish`. Do not "fix" the `file:` dep back to a registry range.

**OIDC:** no npm tokens anywhere. Each package on npmjs.com is configured for
trusted publishing from `Ball-Lang/ball` / `publish-npm.yml`. Adding a
package = configure trusted publishing on npmjs.com, add its build/test/
publish steps, add a `pkgRoot` entry to `.releaserc.json`.

## pub.dev lane (nine Dart packages)

```
push to main
  └► release-prepare.yml (skipped on chore(release) commits)
       └─ melos version → rolling release PR on the fixed chore/release branch
          (resets to main + re-applies bumps on every push; exactly one open PR)

squash-merge the release PR              ← the ONLY manual step
  └► release-tag.yml (fires on the chore(release) merge commit)
       ├─ melos tag: <pkg>-v<version> per changed package
       └─ gh workflow run release-publish.yml --ref <pkg>-v<version>  (per package)
            └► release-publish.yml: melos-action publish → pub.dev OIDC
```

**Ordering:** dispatches run concurrently (no `--order-dependents` — the
workspace has dev-dependency cycles that hard-fail melos's topological sort,
and dispatch order wouldn't serialize the runs anyway). Steady-state releases
are order-independent because caret ranges are satisfied by the previously
published versions. Only a catch-up release for a package whose deps have
never reached pub.dev needs manual, tiered dispatch:

```sh
gh workflow run release-publish.yml --ref <pkg>-v<version>   # deps first
```

**pub.dev config per package:** Admin → Automated publishing → GitHub
Actions, repository `Ball-Lang/ball`, tag pattern `<pkg>-v{{version}}`.
A package's very first publish must be manual (`dart pub publish` from its
directory) — the admin page doesn't exist before that. See issue #152 for
the two packages still awaiting the config (ball_rpc, ball_protobuf_gen).

## PyPI lane (`ball-lang` — the whole Python toolchain in ONE wheel)

```
push a tag  python-pypi/vX.Y.Z            ← the ONLY trigger (plus workflow_dispatch)
  └► publish-pypi.yml
       ├─ setup Python 3.13 + Dart, `gen_engine_json.dart`
       ├─ self-host conformance sweep at full Dart parity   ← publish bar
       ├─ derive X.Y.Z from the tag, inject it into python/pyproject.toml
       ├─ bundle_selfhost.py  → ball_engine/_selfhost/engine.ball.json.gz
       ├─ python -m build python/      (sdist + wheel)
       ├─ wheel_smoke.py               ← clean-venv install + all five verbs
       └─ pypa/gh-action-pypi-publish  (Trusted Publishing, OIDC, no token)
  └► verify-published (separate job)
       └─ pip install ball-lang==X.Y.Z FROM PyPI in a fresh venv, then
          --version / check / run against a conformance golden
```

**One distribution, not five.** `python/pyproject.toml` bundles
`python/{runtime,compiler,encoder,engine,cli}` plus the generated `ball.v1`
binding into a single `ball-lang` wheel with a `ball` console script. The five
per-package `pyproject.toml`s stay as they are — ci.yml still runs each suite
from its own directory.

**No generated code ships.** The wheel carries the engine's Ball *source*
(gzipped package data); `ball run` compiles it into a per-user cache dir on
first use (`BALL_CACHE_DIR` overrides the location). See
`python/engine/ball_engine/bootstrap.py`.

**Maintainer setup (one-time, before the first tag):** create a PyPI **pending
publisher** at <https://pypi.org/manage/account/publishing/> — project
`ball-lang`, owner `Ball-Lang`, repository `ball`, workflow `publish-pypi.yml`,
environment left **blank** (like every other registry channel here — the
workflow declares no GitHub environment, and PyPI rejects the OIDC token if the
publisher's environment and the job's disagree). PyPI allows this before the
project exists (unlike crates.io). There is no API-token fallback: without the
publisher the OIDC exchange fails loudly and nothing is pushed.

**Unlike npm/crates/nuget, this lane is also PR-gated**: ci.yml's `python` job
builds the wheel and installs it into a clean venv on every PR, so a broken
combining distribution is caught before a tag is ever cut.

## Go modules lane (`go/<module>/vX.Y.Z`)

The six Go modules are consumed straight from the module proxy — there is no
registry account and nothing to upload; a tag *is* the release. `release-tag.yml`'s
`tag-go-modules` job cuts all six tags on the release commit **in one push** (a
dependent must never resolve to a version that does not exist yet), at the
version single-sourced from the `go/*/go.mod` requires
(`tools/go-module-proxy/build_local_proxy.py --print-version`, which also asserts
all six agree and that no go.mod carries a `replace` directive). It is idempotent
when the tags already exist and refuses to act on a half-tagged set.

Bumping the Go module line is therefore a normal PR that edits those `require`
lines; the next release commit publishes it. `tools/go-module-proxy/smoke.sh`
(gating in ci.yml's `go` job) proves `go install
github.com/ball-lang/ball/go/cli/cmd/ball@vX.Y.Z` works against a synthesized
proxy before any tag exists.

## C++ `ball` binaries lane (GitHub Release assets)

```
tag vX.Y.Z exists (cut by release.yml / semantic-release)
  └► gh workflow run release-cpp.yml --ref vX.Y.Z     ← EXPLICIT dispatch
       ├─ build matrix: one `ball` per platform, every verb real
       │    (Dart self-host pregeneration + cli-parity gate + run/info smokes)
       ├─ per leg: assert the binary's arch matches its target name
       ├─ per leg: tar + sha256 + `gh release upload --clobber`
       ├─ linux-x64 leg only: the self-host C++ sidecar
       └► checksums job: concatenate every `.sha256` into SHA256SUMS.txt
```

| Target (`matrix.target`) | Runner label (`matrix.os`) | Release assets |
|---|---|---|
| `linux-x64` | `ubuntu-latest` | `ball-vX.Y.Z-linux-x64.tar.gz` + `.sha256` |
| `macos-arm64` | `macos-latest` | `ball-vX.Y.Z-macos-arm64.tar.gz` + `.sha256` |
| `macos-x64` | `macos-15-intel` | `ball-vX.Y.Z-macos-x64.tar.gz` + `.sha256` |

Plus, once per release: `ball-selfhost-cpp-src-vX.Y.Z.tar.gz` + `.sha256`
(the two Dart-generated C++ sources that give a Dart-free consumer — the vcpkg
port — the self-hosted `run`/`info`/`validate`/`tree` verbs; see
`tools/vcpkg-port/README.md`) and `SHA256SUMS.txt`.

**The runner label is load-bearing, not cosmetic.** `macos-latest` is Apple
Silicon; the Intel x86_64 macOS runner is separately labelled. A `macos-x64`
leg pointed at an arm64 label would publish an arm64 binary under an x64
filename — an asset that exists, checksums cleanly, and cannot run on the
machine it names. `macos-15-intel` is a *standard* runner (4 CPU / 14 GB,
architecture Intel; standard runners are free and unlimited on public
repositories, [runners reference][gh-runners]). It replaced `macos-13` — the
old Intel default, retired 2025-12-04 — and is the **last** x86_64 macOS image
Actions will offer, available until August 2027
([actions/runner-images#13045][rimg-13045]). When it retires, so does this leg.

**Why the explicit dispatch:** same GITHUB_TOKEN recursion protection as the
npm lane above — a `push: tags:` trigger would never fire for an automated
release. `release: published` is kept only as a fallback for a manually
published release.

**Not PR-gated, and cannot be.** The workflow only runs against a tag, so a
PR never exercises the matrix. `tools/test/test_release_cpp_targets.sh`
(ci.yml's always-on `Proto Checks` job) is the PR-time stand-in: it pins the
matrix, each target's runner architecture, the asset names the packaging step
derives from `matrix.target`, the single-uploader invariant for the self-host
sidecar, and this table, against each other.

**Rehearsing it before a tag exists.** Dispatch it against a *branch*:

```sh
gh workflow run release-cpp.yml --ref <branch>
```

Every leg then runs the full build, the `cli_parity_tests` gate, the
`run`/`info`/`validate`/`tree` smokes and the architecture assertion, and stops
at `Determine release tag` with an explicit wrong-ref error. That step is
placed after all of the above precisely so this rehearsal is useful, and it is
gated on `github.ref_type == 'tag'` so nothing is ever packaged or published
from a branch. Use it whenever you change the matrix, add a platform, or touch
the build steps — it is the only way to find out that a leg works before a
release depends on it.

[gh-runners]: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
[rimg-13045]: https://github.com/actions/runner-images/issues/13045

## Failure recovery

- **publish-npm failed mid-run:** nothing published (all publishes run after
  every build/test step). Fix, merge (the fix itself cuts the next release),
  or re-dispatch manually: `gh workflow run publish-npm.yml --ref vX.Y.Z`.
- **A release-publish dispatch failed for one package:** re-dispatch just
  that package with its tag (see above); the others are unaffected.
- **"publishing from github is not enabled":** pub.dev-side Automated
  publishing config missing for that package (uploader-only, see above).

---

# Release v2 — per-package semantic-release (gated, not yet live)

Everything above is the **current, live** release flow. This section documents
the **v2** flow that will replace it: a per-package matrix of plain
`semantic-release` configs with **independent per-package versions**, fully
automated on push to main. v2 lands **alongside** the live flow and is **gated
OFF** — merging it changes no release behavior. The cutover (flip the gate,
delete the Melos flow) is a later, separate PR.

## Why

The live flow runs **two** release mechanisms side by side: semantic-release
(npm, lockstep `vX.Y.Z`) and Melos (pub.dev, a rolling `chore/release` PR that a
human squash-merges). They both write `CHANGELOG.md`, which made the Melos PR go
perpetually conflicting after every semantic-release commit (issue #194), and the
human merge is the one manual step in an otherwise-automated pipeline. v2 unifies
**every** publishable package (npm + pub.dev + crates.io + the C++ binary) onto
one mechanism — `semantic-release` — with no manual step.

## Model

One `semantic-release` config per publishable package under
`.github/release/<pkg>.releaserc.json`, each with:

- its own **`tagFormat`** = its **independent version line** (semantic-release
  discovers `lastRelease` from the highest tag matching that format);
- **path-based commit filtering** via the local plugin
  `tools/release/only-package-commits.mjs` (env `SR_PKG_PATHS` or an explicit
  `paths` option), because the repo's commit *scopes* are language/component-level
  (`feat(cpp)`, `fix(rust-compiler)`) and cannot distinguish `ball_engine` from
  `ball_compiler` — only the files a commit touched can. The plugin re-implements
  `semantic-release-monorepo`'s `withOnlyPackageCommits` decorator (same
  `git diff-tree` mechanics) without its hard `package.json` dependency, which the
  Dart/Rust trees don't have.
- Dart/Rust use the official **non-JS recipe** (semantic-release FAQ "Configure
  semantic-release for Non-JavaScript Packages"): the path-filter wrapper
  (commit-analyzer + release-notes-generator) + `@semantic-release/changelog` +
  `@semantic-release/exec` (`prepareCmd` writes the manifest version via
  `tools/release/set_manifest_version.mjs`; `publishCmd` dispatches the existing
  OIDC publish workflow) + `@semantic-release/git` + `@semantic-release/github`.
- npm packages keep `@semantic-release/npm` (`npmPublish: false` — bump the
  `package.json` only; the actual publish stays in `publish-npm.yml`), exactly as
  the live `.releaserc.json` does today.

`.github/workflows/release-v2.yml` runs `semantic-release` **once per package,
SEQUENTIALLY** (each package's `@semantic-release/git` pushes a `chore(release):
… [skip ci]` commit to main; concurrent pushes race into non-fast-forward
rejections). Recursion protection is preserved: the tag semantic-release pushes
is created with `GITHUB_TOKEN`, so the publish backends' `push: tags:` triggers
do **not** fire — each config's `publishCmd` therefore **explicitly dispatches**
its backend with `gh workflow run --ref <tag>`, the same pattern the live
`release.yml` / `release-tag.yml` already use.

### The 15 packages + version continuity

| Config | tagFormat | Ecosystem | Continuity |
|---|---|---|---|
| `ball_base`,`ball_engine`,`ball_compiler`,`ball_cli`,`ball_encoder`,`ball_resolver`,`ball_protobuf`,`ball_protobuf_gen`,`ball_rpc` | `<pkg>-v${version}` | pub.dev | existing `<pkg>-v0.3.*` tags are the anchors → **no seeding**. pub.dev Automated-publishing pattern `<pkg>-v{{version}}` keeps working unchanged. `+N` build metadata is dropped going forward (`0.3.0+6` → `0.4.0`; not a reset). |
| `ts-engine`,`ts-cli`,`ts-compiler`,`ts-encoder` | `@ball-lang/<pkg>-v${version}` | npm | new per-package format — **must seed** at the current published version (see prerequisites), else the first run defaults to `1.0.0` (a regression below the live line). |
| `rust-crates` | `rust-crates/v${version}` | crates.io | **lockstep** — one config for the whole Rust workspace (per the locked maintainer decision; de-lockstep is a later follow-up). The anchor tag `rust-crates/v0.1.0` **already exists** on origin (from the #403 rename / #366 crates.io work), so **no seeding is needed** — the config continues from `0.1.0`. The `/` deliberately dodges the pub.dev `*-v[0-9]…` tag filter. |
| `repo` | `v${version}` | GitHub Release (C++ binary) | continues the existing `vX.Y.Z` line (`v1.42.0` → next); path-scoped to `cpp/**`, drives `release-cpp.yml`. **No seeding.** |

Private packages have **no** config and are correctly excluded:
`ball_self_host_tests` (`publish_to: none`), `@ball-lang/shared` (npm 404,
workspace-internal), and the `publish = false` Rust tool crates.

## Gating

`release-v2.yml` is `workflow_dispatch`-only (no `push:` trigger — it cannot fire
on a merge). A **dry-run** is always allowed; a **real** release additionally
requires the repo variable `RELEASE_V2 == 'true'`. With `RELEASE_V2` unset, a
non-dry-run dispatch is skipped and the live flow stays authoritative. It creates
no tags/commits/releases in dry-run and never modifies the live
`release.yml`/`release-prepare.yml`/`release-tag.yml`/`.releaserc.json`.

## Dry-run evidence (semantic-release 25.0.6)

`npx semantic-release --dry-run` (read-only: all prepare/publish/tag/commit steps
are skipped) per package, run on the branch with
`--branches <branch> --no-ci`, after `cp .github/release/<pkg>.releaserc.json
.releaserc.json` (the same shim `release-v2.yml` uses so the per-package config is
the sole auto-discovered config, since the live root `.releaserc.json` still
exists in this phase):

| Package | Computed next version | Continues the right line? |
|---|---|---|
| `ball_engine` (Dart) | `0.4.0` | ✅ from `ball_engine-v0.3.0+6` (minor bump; `+6` dropped) — no seeding (34 of 314 commits touch `dart/engine`) |
| `ts-engine` (npm) | `1.0.0` | ⚠️ **expected** — no `@ball-lang/engine-v*` tag yet; **confirms the npm seed prerequisite** (225 of 972 commits touch `ts/engine`) |
| `rust-crates` (Rust) | *no release* (continues from `rust-crates/v0.1.0`) | ✅ anchor tag exists; 0 of 9 commits since it touch `rust/` — **no seeding needed** |
| `repo` (C++/meta) | `1.43.0` | ✅ from `v1.42.0`; 1 of 4 commits since touch `cpp/` — no seeding |

To reproduce in CI or locally: `cd tools/release && npm ci`, then from the repo
root for each `<pkg>`:
`cp .github/release/<pkg>.releaserc.json .releaserc.json && GITHUB_TOKEN=… npx --prefix tools/release semantic-release --dry-run --no-ci --branches "$(git branch --show-current)"`.
(On Windows the first-release case — a package with no seed tag — walks the whole
history spawning one `git diff-tree` per commit and is slow; on CI Linux and for
seeded packages it is fast.)

## Human prerequisites (do NOT perform as part of the alongside PR)

1. **Seed the npm per-package git tags** at the **current** published npm
   version, then push:
   `@ball-lang/{engine,cli,compiler,encoder}-v<current npm version>` — or accept
   the `1.0.0` first release. **Dart, Rust, and the `repo` line need none** —
   their anchor tags (`<pkg>-v0.3.*`, `rust-crates/v0.1.0`, `v1.42.0`) already
   exist.
2. **pub.dev Automated-publishing** for the uploader-only packages `ball_rpc`,
   `ball_protobuf_gen`, `ball_protobuf` (issue #152): repo `Ball-Lang/ball`, tag
   pattern `<pkg>-v{{version}}` — required before their `publishCmd` can publish.
3. **crates.io** (issue #366): done. The `ball-lang-*` crates were bootstrapped at
   0.1.0 with `CARGO_REGISTRY_TOKEN`; Trusted Publishing is now configured for all
   five and the token fallback has been removed (OIDC is the only auth path), so
   the `CARGO_REGISTRY_TOKEN` secret can be deleted.
4. **Confirm the release bot may push** `chore(release): … [skip ci]` commits +
   tags to `main` with `GITHUB_TOKEN` (the live npm semantic-release already
   does). `RELEASE_PAT` is likely **removable** — it existed only for the deleted
   Melos `create-pull-request` flow.

## Cutover checklist (a later, separate PR)

1. Do the prerequisites above (seed tags; pub.dev configs; crates.io bootstrap).
2. Split `publish-npm.yml` to accept a `package` input and publish one package
   per dispatch (the ts configs already pass `-f package=<name>`; **the current
   `publish-npm.yml` has no such input yet** — this split is a cutover task, and
   the `publishCmd` never runs before cutover so it is not a live break).
3. `ball_cli` only: `dart/cli/lib/src/version.g.dart` is generated from
   `dart/cli/pubspec.yaml` (issue #363) and is guarded by a CI `gen_version.dart
   --check`. A `ball_cli` version bump must regenerate it, or that guard fails on
   the next push. At cutover, add Dart SDK setup (+ `dart pub get`) to the release
   job and extend `ball_cli.releaserc.json`'s `prepareCmd` with
   `dart run tool/gen_version.dart`, adding `dart/cli/lib/src/version.g.dart` to its
   `@semantic-release/git` assets. (Left out here so all 9 Dart configs stay
   uniform while the release job has no Dart toolchain.)
4. Set `RELEASE_V2=true`, rename `release-v2.yml` → `release.yml`, and in the
   same PR delete the Melos flow: `release-prepare.yml`, `release-tag.yml`, the
   root `.releaserc.json`, `PACKAGES_CHANGELOG.md`, and the `pubspec.yaml`
   `melos: command: version:` block (Melos stays as a dev task-runner).
5. **Rollback** = revert that one PR. The publish backends
   (`release-publish.yml`, `publish-npm.yml`, `publish-crates.yml`,
   `release-cpp.yml`) are untouched throughout, so publishing works under either
   regime; seeded tags are inert if unused.

## Later follow-ups

- **Rust de-lockstep** (optional): split `rust-crates` into per-crate configs +
  per-crate versions + per-crate `publish-crates.yml` dispatch. Kept lockstep for
  now per the locked decision.
- Retire or repurpose the root `CHANGELOG.md` as the `repo`/C++ meta line's
  changelog at cutover.
