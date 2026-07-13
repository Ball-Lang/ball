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
3. `ball_cli` only: `dart/cli/lib/version.g.dart` is generated from
   `dart/cli/pubspec.yaml` (issue #363) and is guarded by a CI `gen_version.dart
   --check`. A `ball_cli` version bump must regenerate it, or that guard fails on
   the next push. At cutover, add Dart SDK setup (+ `dart pub get`) to the release
   job and extend `ball_cli.releaserc.json`'s `prepareCmd` with
   `dart run tool/gen_version.dart`, adding `dart/cli/lib/version.g.dart` to its
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
