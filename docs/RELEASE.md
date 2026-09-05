# Release & Publishing Pipeline

How a commit on `main` becomes published packages. Seven lanes — npm, pub.dev,
PyPI, Go modules, C++ binaries, crates.io and NuGet — all cut from the same
trunk, **all fully automated with no human step in any critical path**.

> **The invariant that matters.** No release lane may contain a manual action.
> The pub.dev lane used to: `melos version` opened a rolling `chore/release` PR
> that a maintainer squash-merged. Every automated part of that lane worked and
> stayed green, and it still shipped nothing from 2026-07-06 to 2026-09-05,
> because PR #272 was never merged (issue #551). A human step that stops
> happening is invisible — the automation *around* it keeps reporting success.
> Three guards now pin this: `tools/release/check_pubdev_release_wiring.sh`
> (every PR — the lane's shape),
> `tools/release/check_pubspec_workspace_consistency.mjs` (every PR, and again
> after each release run — the workspace invariants `melos version` used to hold
> for free) and `.github/workflows/pubdev-freshness.yml` (weekly — pub.dev's live
> state versus `main`).

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

**Independent per-package versions**, one `semantic-release` run per package, no
rolling PR and no human step (issue #551).

```
push to main
  └► release.yml → semantic-release (as in the npm lane above)
       └► gh workflow run pubdev-release.yml --ref main    ← EXPLICIT dispatch
            └► pubdev-release.yml
                 ├─ lockstep_plan.mjs --fetch-published → the LIVE pub.dev graph
                 └─ for each of the nine packages, IN ORDER,
                 semantic-release with .github/release/<pkg>.releaserc.json
                   ├─ only-package-commits.mjs: only commits touching
                   │  dart/<pkg>/ count toward this package's version
                   │  …unless SR_FORCE_RELEASE says otherwise (lockstep, below)
                   ├─ verifyReleaseCmd
                   │    └─ lockstep_plan.mjs --record → this run's decisions,
                   │       so the packages that follow can see them
                   ├─ prepareCmd
                   │    ├─ set_manifest_version.mjs  → dart/<pkg>/pubspec.yaml
                   │    ├─ sync_pubspec_deps.mjs     → re-pin sibling ranges in
                   │    │                               ALL TEN member pubspecs
                   │    └─ (ball_cli only) gen_version.dart → version.g.dart
                   ├─ @semantic-release/changelog → dart/<pkg>/CHANGELOG.md
                   ├─ @semantic-release/git  → chore(release): <pkg> X.Y.Z [skip ci]
                   │                            (commits dart/*/pubspec.yaml)
                   │                            + tag <pkg>-vX.Y.Z
                   └─ publishCmd
                        └► gh workflow run release-publish.yml --ref <pkg>-vX.Y.Z
                             └► release-publish.yml
                                  ├─ melos-action publish → pub.dev OIDC
                                  └─ verify-published (separate job): poll the
                                     pub.dev API for the version, resolve it as
                                     an external consumer, check every resolved
                                     Ball sibling against the tag's own tree,
                                     and for ball_cli `dart pub global activate`
                                     + run it
                      (before each: lockstep_plan.mjs --decide → SR_FORCE_RELEASE)
            └► (after the loop) check_pubspec_workspace_consistency.mjs
               + `dart pub get` — prove main still resolves
```

**Why `--ref main` and not the `vX.Y.Z` tag** the three sibling dispatches use:
they build a released tree, this one *runs* semantic-release, whose
`@semantic-release/git` step pushes commits and tags to a **branch**. A detached
tag ref leaves it no branch to release from. It is dispatched (not
`push:`-triggered) so it starts only after `release.yml` has finished pushing its
own release commit — two push-triggered releasers would race main.

**Why sequential, never a matrix:** each package's `@semantic-release/git` pushes
its own commit to main; concurrent pushes lose to non-fast-forward rejections.

**Why the sibling sweep is workspace-wide, not per-package.**
`sync_pubspec_deps.mjs` re-pins sibling constraints (`ball_base: ^0.3.0+3` →
`^0.4.0`) by reading each sibling's version **from the working tree**.
`melos version` used to do this as one workspace-wide transaction;
semantic-release's per-package model has no workspace view, so the sweep
reconstructs it — and it must sweep **every** member of the workspace, not just
the package being released:

* All ten packages under `dart/` (the nine publishable ones plus the private
  `ball_self_host_tests`) are members of one pub workspace, and **pub resolves a
  workspace as a unit**. Bump `ball_base` to `0.4.0` while any member still asks
  for `^0.3.0+3` and `dart pub get` at the repo root fails outright —
  `Because ball_self_host_tests depends on ball_engine ^0.3.0+6 and
  ball_workspace depends on ball_engine, version solving failed.` That breaks
  main for every contributor, breaks the release job's own
  `dart run tool/gen_version.dart` step, and breaks `melos bootstrap` inside
  `release-publish.yml`.
* `dart/self_host` can never fix itself: a private package has no release config
  by design, so nothing would ever re-pin it.

So each config runs `sync_pubspec_deps.mjs --workspace-root=.` and commits
`dart/*/pubspec.yaml`. Without the sweep the lane would also publish
`ball_cli 0.4.0` still requiring `ball_base ^0.3.0+3` — resolvable, green, and
semantically wrong (a caret on a `0.x` version pins the minor, so `^0.3.0+3`
never admits `0.4.0`).

**Why a re-pinned sibling must release in the SAME run (lockstep, issue #566).**
The sweep rewrites every member's pins in the **repo**. A member with no
releasable commits of its own is swept too — and then not published, because
`only-package-commits.mjs` correctly finds nothing to release for it. pub.dev
therefore keeps serving that package's **old** pubspec while every package that
*did* publish moved on, and the published graph splits in half. The first live
run (33953248977, 2026-09-05) did exactly this: it published seven packages on
the 0.4.0 line and skipped `ball_resolver` and `ball_rpc`, leaving

```
Because ball_resolver >=0.3.0+3 depends on ball_base ^0.3.0+3 and
  ball_engine >=0.4.0 depends on ball_base ^0.4.0,
  ball_resolver >=0.3.0+3 is incompatible with ball_engine >=0.4.0.
```

so that an outside `dart pub get` on `ball_cli: ^0.4.0` failed outright. Nothing
in the repo was wrong — `check_pubspec_workspace_consistency.mjs` and
`dart pub get` on main were both green, because the sweep had made the *tree*
consistent. The split existed only in the registry.

The lane therefore plans against **pub.dev state**, not the tree:

* Before the loop, `lockstep_plan.mjs --fetch-published` snapshots what pub.dev
  serves right now — every publishable package's latest version and its
  runtime `dependencies:`.
* Before each package, `lockstep_plan.mjs --decide --package=<pkg>` asks one
  question: does that package's **published** pubspec pin a workspace sibling at
  a version this run moves out from under it? If yes it prints `patch`, the loop
  passes it in as `SR_FORCE_RELEASE`, and `only-package-commits.mjs` promotes
  its no-release verdict to that level. A real analyzer verdict always wins.
* Each config's `verifyReleaseCmd` records what semantic-release decided
  (`lockstep_plan.mjs --record`), so the next package's `--decide` sees it.
  `verifyRelease` is one of the four lifecycle steps semantic-release also runs
  under `--dry-run` (`prepare`, `publish`, `addChannel`, `success` and `fail`
  are the ones it skips), which is what makes `dry_run=true` a faithful
  rehearsal of the plan rather than a guess.

The rule is deliberately **narrow**: a pin that was merely *rewritten* but is
still satisfiable does not force a release. `ball_cli 0.4.0` pinning
`ball_resolver ^0.3.0+3` still admits a `ball_resolver 0.3.1`, so republishing
it would be noise. The broad alternative — "any `chore(release):` commit
touching my paths is a patch trigger" — is self-sustaining: every run's sweep
commits touch every pubspec that pins a bumped sibling, so every run would
republish all nine packages forever, including runs where nothing under `dart/`
changed. Because the loop is deps-first, one forward pass is a fixpoint, and
re-planning the world a run produced releases nothing.

`node tools/release/lockstep_plan.mjs --self-test` (ci.yml, every PR) drives the
whole simulation on fixtures, including the live nine-package graph above.

**Why the release ORDER is load-bearing, and how it is gated.** Because each
release commits the whole workspace's pubspecs, a package released *before* one
of its dependencies publishes a tarball still pinned to that dependency's old
version. So `PACKAGES` in `pubdev-release.yml` is a genuine topological order of
the **runtime** `dependencies:` graph, deps first:

```
ball_protobuf → ball_base → ball_resolver → ball_encoder → ball_engine
             → ball_compiler → ball_rpc → ball_protobuf_gen → ball_cli
```

That order exists because this workspace's cycles
(`ball_base`↔`ball_protobuf`, `ball_engine`↔`ball_encoder`,
`ball_protobuf_gen`→`ball_rpc`) are **all dev-dependency edges** — the runtime
graph is acyclic. pub never resolves a dependency's `dev_dependencies` for a
consumer, so a dev-only edge can leave one tarball's dev pin a release behind;
that is invisible to consumers and self-corrects on that package's next release.

`tools/release/check_pubspec_workspace_consistency.mjs` (every PR) recomputes
that graph from the pubspecs and fails if the loop is not a valid deps-first
order of it, if it does not name exactly the publishable packages, if any member
carries a sibling constraint the workspace cannot satisfy, or if any release
config stopped sweeping/committing the whole workspace. The release job re-runs
it plus `dart pub get` after the loop, so a partial release reports the damage in
the run that caused it.

**Why `verify-published` alone is not the backstop.** Resolving is necessary and
not sufficient: `ball_compiler 0.4.0` published still requiring
`ball_encoder ^0.3.2` resolves *cleanly* for an outside consumer, because
`0.3.2` is still on pub.dev. So `verify-published` also runs
`tools/release/check_published_siblings.py`, which compares the consumer's
`pubspec.lock` against the repo tree **at the release tag**: every Ball sibling
it resolved must be at least the version that tree declares. A sibling resolved
*newer* is fine (publishes are dispatched asynchronously). Its classifier is
`--self-test`ed on every PR, since the live step only runs during a real publish.

**Version continuity:** the existing `<pkg>-v0.3.*` tags are the anchors, so
there is no seeding and no reset — `ball_engine-v0.3.0+6` → `0.4.0`. The Dart
`+N` build-number suffix is intentionally dropped going forward
(`set_manifest_version.mjs` emits a pure `X.Y.Z`).

**Ordering of the *uploads* themselves:** unordered, deliberately. `publishCmd`
dispatches `release-publish.yml` and returns, so the nine publish runs overlap
even though the semantic-release loop that started them is strictly ordered.
That is safe: pub.dev resolves a package's caret ranges against **previously
published** versions of its dependencies, so once every package has published at
least once — true for all nine since 2026-07-02 — an upload never has to wait
for a sibling's upload. Do not add ordering logic to the *dispatch*; the release
loop's order is what carries the dependency constraint. The one case that needs
manual sequencing is a catch-up release for a package whose deps have *never*
reached pub.dev, via tiered dispatch:

```sh
gh workflow run release-publish.yml --ref <pkg>-v<version>   # deps first
```

**pub.dev config per package:** Admin → Automated publishing → GitHub Actions,
repository `Ball-Lang/ball`, tag pattern `<pkg>-v{{version}}` — which is exactly
each config's `tagFormat`, so nothing pub.dev-side changed at cutover. All nine
are configured (issue #152, closed). A package's very first publish must be
manual (`dart pub publish` from its directory) — the admin page doesn't exist
before that.

**On pub.dev's "must be triggered by pushing a git tag" rule**
(<https://dart.dev/tools/pub/automated-publishing>): `release-publish.yml` is
invoked with `gh workflow run --ref <pkg>-v<version>`, a `workflow_dispatch` at a
**tag ref**. pub.dev matches the OIDC token's `ref` claim against the configured
tag pattern, and accepts this — every real publish this repo has done arrived
that way (e.g. runs `28782924129`–`28782934612`, 2026-07-06, published
`ball_cli`/`ball_compiler`/`ball_engine` at `0.3.0+6`). The explicit dispatch is
required because the tag is created with `GITHUB_TOKEN`, and GitHub's recursion
protection means a `push: tags:` trigger never fires for it.

**Adding a tenth Dart package:** add `.github/release/<pkg>.releaserc.json`
(copy any of the nine), list it in `pubdev-release.yml`'s `PACKAGES` loop **after
every package it depends on at runtime**, and configure Automated publishing on
pub.dev after its first manual publish. Two guards fail on every PR until that
is done, and neither has a hardcoded package list:
`check_pubdev_release_wiring.sh` discovers publishable packages from
`dart/*/pubspec.yaml` (so one cannot silently fall outside the lane), and
`check_pubspec_workspace_consistency.mjs` recomputes the runtime graph (so the
new entry cannot silently sit in the wrong place in the loop).

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
registry account and nothing to upload; a tag *is* the release.

```
push to main
  └► release.yml → semantic-release (as in the npm lane above)
       └► gh workflow run tag-go-modules.yml --ref vX.Y.Z   ← EXPLICIT dispatch
            └► tag-go-modules.yml: one `git push` creating all six
               go/<module>/vA.B.C tags on the released commit
```

`tag-go-modules.yml` cuts all six tags **in one push** (a dependent must never
resolve to a version that does not exist yet), at the version single-sourced from
the `go/*/go.mod` requires (`tools/go-module-proxy/build_local_proxy.py
--print-version`, which also asserts all six agree and that no go.mod carries a
`replace` directive). It is idempotent when the tags already exist and refuses to
act on a half-tagged set. Note the Go module version is its OWN line (`v0.1.0`
first) — it is not the repo's `vX.Y.Z` release version, which only selects the
commit the tags land on.

**Why the explicit dispatch** — same reason as npm and C++ above, and this lane
learned it the expensive way. The job originally lived in `release-tag.yml`
(since deleted, #551) behind
`on: push: branches:[main]` + `if: contains(head_commit.message, 'chore(release)')`.
semantic-release commits `chore(release): X.Y.Z [skip ci]`, and GitHub's skip-ci
recursion protection suppresses the **entire workflow run** on such a push — not
merely the job's `if:`. No run row is created at all, so the dead channel read as
"nothing red" while five releases (v1.61.1 … v1.64.0) shipped and
`gh api repos/Ball-Lang/ball/git/matching-refs/tags/go%2F` still returned `[]`.
`tools/release/check_release_dispatch_wiring.sh` (ci.yml's `Proto Checks` job) now
pins the dispatch contract for all three channels so this cannot recur.

**Status: no `go/` tags exist yet.** As of v1.64.0 the public proxy has nothing
to serve, so `go install github.com/ball-lang/ball/go/cli/cmd/ball@latest` does
**not** resolve — the Go modules remain clone-and-build in practice. The dispatch
wiring above only covers releases from here on; the already-shipped ones need a
one-time maintainer backfill:

```sh
gh workflow run tag-go-modules.yml --ref main   # creates the six go/<module>/v0.1.0 tags
```

`tools/go-module-proxy/smoke.sh` (gating in ci.yml's `go` job) proves `go install
github.com/ball-lang/ball/go/cli/cmd/ball@vX.Y.Z` works against a synthesized
proxy — that is what the tags will make real, not evidence that they exist.

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

### vcpkg consumes this lane; it is not a lane of its own

`tools/vcpkg-port/ports/ball-lang/` pins exactly ONE tag: `version-semver`
drives both `vcpkg_from_github`'s `REF "v${VERSION}"` and the sidecar asset's
`releases/download/v${VERSION}/...` URL, and each download carries the SHA512
of *that tag's* artifact. So refreshing the port to a newer release is a
deliberate PR **here** — bump `version-semver`, recompute both SHA512s,
re-prove `vcpkg install` against the real release — followed by a separate,
maintainer-only PR to a `microsoft/vcpkg` fork. Cutting a release never moves
the port, and the port never lands unpinned:
`tools/vcpkg-port/test/test_selfhost_asset_wiring.sh` (always-run in `Proto
Checks`) fails if either hash is the `SHA512 0` placeholder or if the version
the portfile names disagrees with the manifest. The port was first installed
from a real release at `v1.64.0`; see `tools/vcpkg-port/README.md`.

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
- **`pubdev-release.yml` failed part-way through the nine packages:** the ones
  that already released are done (tag pushed, publish dispatched); nothing is
  half-applied, because each package's commit+tag+dispatch is its own
  semantic-release run. Re-dispatch the workflow — `gh workflow run
  pubdev-release.yml --ref main`; packages with no new qualifying commits
  compute "no release" and are skipped.
- **`verify-published` red but `publish` green:** the upload happened and the
  package is not usable, or is usable and stale. Either a sibling constraint no
  published version satisfies / a dependency whose own publish failed (the
  resolution step), or a constraint that resolves an *older* sibling than the
  release tag's tree declares (the `check_published_siblings.py` step — the
  sweep did not run, or the package released ahead of its dependency). Check
  `sync_pubspec_deps.mjs` in that package's prepare log and the `PACKAGES` order
  in `pubdev-release.yml`. Fix forward and cut a new patch — pub.dev versions are
  immutable.
- **`verify-published` red for several packages at once, all failing to resolve
  one sibling that is still on its OLD version:** a package the sweep re-pinned
  was never released, so pub.dev serves its old pubspec (issue #566 —
  `ball_resolver 0.3.0+3` requiring `ball_base ^0.3.0+3` while ball_base is live
  at `0.4.0`). The repo is fine and every static guard is green; the split is
  registry-side only. Confirm with
  `node tools/release/lockstep_plan.mjs --fetch-published --out=/tmp/pubdev.json`
  and read the versions, then rehearse the repair with
  `gh workflow run pubdev-release.yml --ref main -f dry_run=true` — the packages
  it reports as releasing with no releasable commits are the ones the lockstep
  planner is repairing. Fix forward by dispatching the workflow for real; never
  revert, pub.dev versions are immutable. If the dry run reports *nothing*, the
  lockstep wiring itself regressed — check
  `bash tools/release/check_pubdev_release_wiring.sh`.
- **`Verify the workspace still resolves after the release` red:** one or more
  member pubspecs were left pinned to a version the workspace no longer
  contains, so `dart pub get` fails on main. The output names each offender.
  Fix forward with a commit that runs `node tools/release/sync_pubspec_deps.mjs`
  — do not revert the release commits, the tags and publishes are already out.
- **`pubdev-freshness.yml` red:** pub.dev is behind `main`. Check
  `gh run list --workflow=pubdev-release.yml` for a failed or never-dispatched
  run. This is the alarm issue #551 did not have.
- **Rehearsing without publishing:** `gh workflow run pubdev-release.yml --ref
  main -f dry_run=true` computes every package's next version and creates no
  tags, commits, releases or publishes. A dry run checks out **the ref it was
  dispatched for** (a real run always checks out `main`) and passes
  `--branches <that ref>` to semantic-release, so a change to the release lane
  can be rehearsed on its own branch before it is merged —
  `gh workflow run pubdev-release.yml --ref <branch> -f dry_run=true`. #566
  shipped unrehearsed because this step pinned `main` unconditionally and the
  only way to exercise a change was to merge it.

## The guards, and what each one can and cannot see

A release channel can fail in three distinct ways, and this repo has now been
bitten by all three. Each guard covers exactly one; none of them substitutes for
another.

| Guard | Runs | Catches | Blind to |
|---|---|---|---|
| `tools/release/check_release_dispatch_wiring.sh` | every PR (`Proto Checks`) | a channel wired so its trigger can **never fire** — `push: branches:[main]` + a `chore(release)` message match, which `[skip ci]` suppresses entirely. `tag-go-modules` shipped zero tags across five releases that way (#361) | whether the dispatch ever *ran*, and whether the registry is current |
| `tools/release/check_pubdev_release_wiring.sh` | every PR (`Proto Checks`) | the pub.dev lane's **shape**: a publishable package with no config (or vice versa), a config whose tag/paths/stamp/dispatch disagree, two workflows driving one package, the Melos versioning lane coming back, `ball_cli`'s `version.g.dart` regen going missing, `verify-published` disappearing, the lockstep wiring (#566) going missing, and a dry run losing the ability to rehearse the branch it was dispatched for | whether a release was actually cut — it is entirely static |
| `.github/workflows/pubdev-freshness.yml` | weekly + dispatch | the registry **falling behind main**: a version on pub.dev that does not match `main`, or a package whose code has moved for more than 30 days while pub.dev has not. This is the alarm #551 lacked — the stalled lane was reachable AND correctly shaped, and stayed green for two months | a lane that broke in the last few days (it is deliberately generous) |
| `tools/release/check_pubspec_workspace_consistency.mjs` | every PR (`Proto Checks`) + after the release loop | the invariants `melos version` used to hold for free: a workspace member (including the private `dart/self_host`, which has no release config) pinned to a sibling version the workspace no longer contains — `dart pub get` fails for the whole repo — and a `PACKAGES` loop that is not a deps-first order of the runtime dependency graph, which publishes tarballs pinned to sibling versions that only bump later in the same run | anything registry-side; it never leaves the working tree |
| `tools/release/lockstep_plan.mjs` | every PR (`--self-test`, `Proto Checks`) + the release run itself | the **published** graph splitting: a package the sibling sweep re-pinned in the repo but never published, so pub.dev keeps serving its old pubspec and an external `dart pub get` cannot solve the graph (#566). It is the only guard that models pub.dev BEFORE the upload | anything about a package whose constraint shape it does not model (`any`, an explicit range) — those never force a release |
| `verify-published` (in `release-publish.yml`) | every publish | an upload that is not **usable**: the version never appears on the index, an external consumer cannot resolve it (a sibling range no published version satisfies), or the published `ball` reports the wrong version. Plus, via `check_published_siblings.py`, an upload that resolves *cleanly* and is still wrong: a Ball sibling resolved older than the release tag's tree declares | anything about packages this run did not publish |

The 30-day staleness bound is a judgement call, not a release cadence: it says
"if this package's code has been moving for over a month and pub.dev has not,
someone should look". Tune it with `MAX_STALE_DAYS` (env, or the workflow's
dispatch input).

---

# Release v2 — per-package semantic-release (Dart slice LIVE; the rest gated)

Everything above is the **current, live** release flow. This section documents
the **v2** model: a per-package matrix of plain `semantic-release` configs with
**independent per-package versions**, fully automated.

**Status.** The **nine Dart / pub.dev configs cut over in #551** and are live in
`.github/workflows/pubdev-release.yml` (see the pub.dev lane above) — the Melos
rolling-PR flow, `release-prepare.yml`, `release-tag.yml` and the root
`pubspec.yaml`'s `melos: command: version:` block are **deleted**. The remaining
slice — npm (`ts-*`), crates.io (`rust-crates`) and the C++/meta `repo` line —
is still in `release-v2.yml`, still **gated OFF**; those lanes are not broken
and were deliberately left out of the pub.dev fix to keep its blast radius to
the lane that was.

## Why

The live flow ran **two** release mechanisms side by side: semantic-release
(npm, lockstep `vX.Y.Z`) and Melos (pub.dev, a rolling `chore/release` PR that a
human squash-merged). They both wrote `CHANGELOG.md`, which made the Melos PR go
perpetually conflicting after every semantic-release commit (issue #194), and the
human merge was the one manual step in an otherwise-automated pipeline — the step
that then stopped happening for two months (issue #551). v2 unifies **every**
publishable package (npm + pub.dev + crates.io + the C++ binary) onto one
mechanism — `semantic-release` — with no manual step. pub.dev is done; the rest
remains.

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
  The Dart configs' `prepareCmd` additionally runs
  `tools/release/sync_pubspec_deps.mjs --workspace-root=.`, which re-pins the
  caret ranges on **workspace siblings** in *every* member pubspec (committed via
  the `dart/*/pubspec.yaml` asset glob) — the one thing `melos version` did that
  a per-package model has no view of, and which has to be workspace-wide because
  pub resolves a workspace as a unit. `ball_cli` also regenerates
  `dart/cli/lib/src/version.g.dart` (issue #363) and commits it.
- npm packages keep `@semantic-release/npm` (`npmPublish: false` — bump the
  `package.json` only; the actual publish stays in `publish-npm.yml`), exactly as
  the live `.releaserc.json` does today.

`.github/workflows/pubdev-release.yml` (Dart, live) and
`.github/workflows/release-v2.yml` (the rest, gated) each run `semantic-release`
**once per package, SEQUENTIALLY** (each package's `@semantic-release/git`
pushes a `chore(release): … [skip ci]` commit to main; concurrent pushes race
into non-fast-forward rejections). Recursion protection is preserved: the tag
semantic-release pushes is created with `GITHUB_TOKEN`, so the publish backends'
`push: tags:` triggers do **not** fire — each config's `publishCmd` therefore
**explicitly dispatches** its backend with `gh workflow run --ref <tag>`, the
same pattern `release.yml` already uses for npm, C++ and Go.

### The 15 packages + version continuity

| Config | tagFormat | Ecosystem | Continuity |
|---|---|---|---|
| `ball_base`,`ball_engine`,`ball_compiler`,`ball_cli`,`ball_encoder`,`ball_resolver`,`ball_protobuf`,`ball_protobuf_gen`,`ball_rpc` | `<pkg>-v${version}` | pub.dev — **LIVE** (#551) | existing `<pkg>-v0.3.*` tags are the anchors → **no seeding**. pub.dev Automated-publishing pattern `<pkg>-v{{version}}` keeps working unchanged. `+N` build metadata is dropped going forward (`0.3.0+6` → `0.4.0`; not a reset). |
| `ts-engine`,`ts-cli`,`ts-compiler`,`ts-encoder` | `@ball-lang/<pkg>-v${version}` | npm | new per-package format — **must seed** at the current published version (see prerequisites), else the first run defaults to `1.0.0` (a regression below the live line). |
| `rust-crates` | `rust-crates/v${version}` | crates.io | **lockstep** — one config for the whole Rust workspace (per the locked maintainer decision; de-lockstep is a later follow-up). The anchor tag `rust-crates/v0.1.0` **already exists** on origin (from the #403 rename / #366 crates.io work), so **no seeding is needed** — the config continues from `0.1.0`. The `/` deliberately dodges the pub.dev `*-v[0-9]…` tag filter. |
| `repo` | `v${version}` | GitHub Release (C++ binary) | continues the existing `vX.Y.Z` line (`v1.42.0` → next); path-scoped to `cpp/**`, drives `release-cpp.yml`. **No seeding.** |

Private packages have **no** config and are correctly excluded:
`ball_self_host_tests` (`publish_to: none`), `@ball-lang/shared` (npm 404,
workspace-internal), and the `publish = false` Rust tool crates.

## Gating

This applies to the **still-gated** slice only (`ts-*`, `rust-crates`, `repo`).
`release-v2.yml` is `workflow_dispatch`-only (no `push:` trigger — it cannot fire
on a merge). A **dry-run** is always allowed; a **real** release additionally
requires the repo variable `RELEASE_V2 == 'true'`. With `RELEASE_V2` unset, a
non-dry-run dispatch is skipped and the live flow stays authoritative. It creates
no tags/commits/releases in dry-run and never modifies `release.yml` or the root
`.releaserc.json`.

The nine Dart configs are **not** in `release-v2.yml` any more — they are live in
`pubdev-release.yml`, which is their single owner.
`tools/release/check_pubdev_release_wiring.sh` fails if any other workflow starts
driving them too, because two drivers for one package cut duplicate tags and
double-bump the same pubspec.

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

## Human prerequisites for the REMAINING (npm / crates / repo) slice

1. **Seed the npm per-package git tags** at the **current** published npm
   version, then push:
   `@ball-lang/{engine,cli,compiler,encoder}-v<current npm version>` — or accept
   the `1.0.0` first release. **Dart, Rust, and the `repo` line need none** —
   their anchor tags (`<pkg>-v0.3.*`, `rust-crates/v0.1.0`, `v1.42.0`) already
   exist.
2. **pub.dev Automated-publishing**: done for all nine packages (issue #152,
   closed) — repo `Ball-Lang/ball`, tag pattern `<pkg>-v{{version}}`, which is
   exactly each config's `tagFormat`. Nothing pub.dev-side changed at the #551
   cutover. If a package's admin page ever shows this **disabled**, its next
   publish fails with "publishing from github is not enabled"; re-enable it and
   re-dispatch `gh workflow run release-publish.yml --ref <pkg>-v<version>`.
3. **crates.io** (issue #366): done. The `ball-lang-*` crates were bootstrapped at
   0.1.0 with `CARGO_REGISTRY_TOKEN`; Trusted Publishing is now configured for all
   five and the token fallback has been removed (OIDC is the only auth path), so
   the `CARGO_REGISTRY_TOKEN` secret can be deleted.
4. **Confirm the release bot may push** `chore(release): … [skip ci]` commits +
   tags to `main` with `GITHUB_TOKEN` (the live npm semantic-release already
   does, and since #551 so does the Dart lane). **`RELEASE_PAT` is now
   removable** — its only consumer was `release-prepare.yml`'s
   `create-pull-request` step, deleted with that workflow.

## Cutover checklist for the remaining slice (a later, separate PR)

The Dart slice is done; items below are what is left for npm / crates.io / the
C++ `repo` line.

1. Do the prerequisites above (seed the npm tags).
2. Split `publish-npm.yml` to accept a `package` input and publish one package
   per dispatch (the ts configs already pass `-f package=<name>`; **the current
   `publish-npm.yml` has no such input yet** — this split is a cutover task, and
   the `publishCmd` never runs before cutover so it is not a live break).
3. ~~`ball_cli` version.g.dart regeneration~~ — **done in #551**:
   `ball_cli.releaserc.json`'s `prepareCmd` runs `dart run tool/gen_version.dart`
   after the pubspec bump, `dart/cli/lib/src/version.g.dart` is in its
   `@semantic-release/git` assets, and `pubdev-release.yml` sets up a Dart SDK.
   `check_pubdev_release_wiring.sh` pins all three.
4. Set `RELEASE_V2=true`, rename `release-v2.yml` → `release.yml`, and in the
   same PR delete the root `.releaserc.json`. (`release-prepare.yml`,
   `release-tag.yml` and the `pubspec.yaml` `melos: command: version:` block are
   already gone — #551. `PACKAGES_CHANGELOG.md` is kept as the frozen history of
   the Melos lane; the live Dart changelogs are the per-package
   `dart/*/CHANGELOG.md` files semantic-release writes. Melos stays as a dev
   task-runner.)
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
