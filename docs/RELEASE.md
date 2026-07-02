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
