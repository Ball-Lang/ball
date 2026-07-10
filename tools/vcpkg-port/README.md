# vcpkg port staging (issue #368)

This directory is a **staging area**, not a live submission. It holds a draft
`ports/ball-lang/{vcpkg.json,portfile.cmake}` in the exact shape
[microsoft/vcpkg](https://github.com/microsoft/vcpkg) expects for a new port,
so a maintainer can carry it into a fork and open a PR there. **Nothing here
is wired into this repo's own build** (not the root `buf.gen.yaml`, not any
CMake/CI file) — it is inert until copied out.

The Releases leg of issue #368 (`.github/workflows/release-cpp.yml`) does
**not** depend on this directory or on vcpkg landing upstream.

## Why staged, not submitted

Submitting to `microsoft/vcpkg` is entirely out-of-repo: it requires a fork,
a signed Microsoft CLA, and external human review — none of which an agent
or CI job can do on this repo's behalf. This directory prepares everything
that *can* be prepared in advance.

## What was verified, and where (2026-07-10)

Every mechanism below was checked against the live docs, not memory:

- New-port tutorial (fork → branch → copy port → `vcpkg x-add-version` →
  PR): <https://learn.microsoft.com/en-us/vcpkg/get_started/get-started-adding-to-registry>
- Packaging tutorial (`vcpkg.json` / `portfile.cmake` shape, `vcpkg_from_github`,
  `vcpkg_install_copyright`, SHA512 discovery flow):
  <https://learn.microsoft.com/en-us/vcpkg/get_started/get-started-packaging>
- Maintainer guide (port maturity bar, naming-ambiguity rule, versioning /
  `port-version` / `x-add-version` conventions, `vcpkg format-manifest`,
  draft-PR expectation): <https://learn.microsoft.com/en-us/vcpkg/contributing/maintainer-guide>
- PR review checklist (`c000001`–`c000013`):
  <https://learn.microsoft.com/en-us/vcpkg/contributing/pr-review-checklist>
- `vcpkg.json` field reference: <https://learn.microsoft.com/en-us/vcpkg/reference/vcpkg-json>
- `vcpkg_cmake_build` / `vcpkg_copy_tools` helper references (used to confirm
  the tool-only, no-`install()`-needed pattern):
  <https://learn.microsoft.com/en-us/vcpkg/maintainers/functions/vcpkg_cmake_build>,
  <https://learn.microsoft.com/en-us/vcpkg/maintainers/functions/vcpkg_copy_tools>
- Real precedent port for a CLI-tool-only package (the exact same shape as
  `ball`: `VCPKG_BUILD_TYPE release` + `vcpkg_cmake_install()` +
  `vcpkg_copy_tools`), fetched from the live registry:
  [`ports/vcpkg-tool-ninja/portfile.cmake`](https://github.com/microsoft/vcpkg/blob/master/ports/vcpkg-tool-ninja/portfile.cmake)
  — this port's `portfile.cmake` is modeled directly on it.
- `microsoft/vcpkg`'s old `docs/maintainers/` and `docs/users/` tree is now a
  set of one-line redirect stubs — the real docs live in the
  `MicrosoftDocs/vcpkg-docs` repo, published at learn.microsoft.com/vcpkg.
  Verified by walking `docs/` via the GitHub Contents API rather than
  assuming the old in-repo doc paths still work.

## Why the port is buildable at all: the companion `install()` rule

`cpp/CMakeLists.txt` had **no `install()` rules anywhere** before this issue
— every existing build/test workflow only ever runs `cmake --build`, never
`cmake --install`. A vcpkg port needs one (`vcpkg_cmake_install()` calls
`cmake --build <dir> --target install`), so this PR adds a minimal,
target-scoped rule to `cpp/cli/CMakeLists.txt`:

```cmake
install(TARGETS ball RUNTIME DESTINATION bin)
```

This is inert for every existing build path (nothing runs `--target install`
today) and is also what lets `release-cpp.yml` and this port both use
standard CMake install semantics instead of reaching into the build tree by
hand.

## Known limitation: this port ships the compile/encode/version-only `ball`

Ball's self-hosted verbs (`run`, `info`, `validate`, `tree`) are compiled
from a Ball program (`dart/self_host/`) through the C++ compiler itself, as a
**pre-build code-generation step that needs Dart** (see
`cpp/cli/CMakeLists.txt`'s `EXISTS` gates on `dart/self_host/lib/{cli_rt.h,
engine_rt.cpp}`, and `CLAUDE.md`'s "Build & Test" section). vcpkg's
sandboxed builds have no Dart toolchain and no network access beyond the
declared source download, so a vcpkg-built `ball` cannot run that
pre-generation step — those verbs compile as the same fail-loud stubs the
"build-isolated main cpp CI job" already produces (see PR #374's "Build
gating" section). `compile`/`encode`/`version` are always real.

The GitHub Releases binaries (`.github/workflows/release-cpp.yml`) run the
full Dart + self-host pipeline first, so those binaries have every verb.
Closing this gap for vcpkg (e.g. committing the two generated files, or a
Dart-free pre-generation path) is a possible follow-up, not filed as an
issue yet — flag it to the user/maintainer before pursuing it, since
committing generated `dart/self_host/lib/*` artifacts would cut against this
repo's "never hand-edit/commit generated files" convention.

## Open question a human must resolve before submitting: the port name

The maintainer guide's naming-ambiguity rule flags single common words —
its own worked example is `ip` (short, common, no unique association) — and
`ball` fits the same pattern exactly. The guide's prescribed fix is an
`<github owner>-<repository name>` prefix (e.g. `google-cloud-cpp`), which
here is literally `Ball-Lang/ball` → `ball-lang-ball`. That stutters, so
these staged files instead use **`ball-lang`** (treating the org name itself
as the unambiguous identifier, since the language and the org share one
identity — closer to how `boost-asio` doesn't repeat `boost-boost`). The
guide explicitly recommends opening a discussion issue against
`microsoft/vcpkg` before investing effort specifically for naming calls like
this ("we can also help our contributors with this, so feel free to ask for
naming suggestions if you are unsure") — do that before assuming `ball-lang`
is final.

## Submission flow (maintainer-only — cannot be done from this repo/CI)

1. **Resolve the port name** (see above) — optionally via a pre-submission
   discussion issue on `microsoft/vcpkg`, as their maintainer guide
   recommends for any new port before investing effort.
2. **Sign the Microsoft CLA** at <https://cla.microsoft.com> (one-time,
   per-GitHub-account; required before any PR can be merged).
3. **Bump the version.** `vcpkg.json` here pins `version-semver: "1.26.0"`
   (the latest tag at the time this was staged) purely as a placeholder —
   set it to whatever `vX.Y.Z` tag is actually being submitted.
4. Fork `microsoft/vcpkg`, add it as a remote, branch, and copy
   `ports/ball-lang/` from this directory into `<fork>/ports/ball-lang/`.
5. **Fill in the real `SHA512`.** From inside a vcpkg checkout:
   `vcpkg install ball-lang --overlay-ports=<path to this dir>/ports` — the
   failed download prints the actual hash to paste over the `0` placeholder
   in `portfile.cmake`.
6. `vcpkg format-manifest --all` (canonicalizes `vcpkg.json` formatting —
   required by the maintainer guide).
7. `vcpkg x-add-version ball-lang` from the vcpkg checkout root — this
   writes/updates `versions/b-/ball-lang.json` and `versions/baseline.json`,
   which only exist inside the actual `microsoft/vcpkg` tree and cannot be
   produced from this repo.
8. Test locally on every triplet the port claims to support before opening
   the PR (at minimum `x64-linux`, `arm64-osx`, `x64-osx`, `x64-windows`) —
   `vcpkg install ball-lang --overlay-ports=... --triplet <triplet>`.
9. Open a **draft PR** against `microsoft/vcpkg` (their explicit
   convention for new ports), fill out the PR template's "New Port
   Checklist," and mark it ready once CI is green.
10. Respond to human review — the vcpkg team's PR review checklist
    (`c000001`–`c000013`, linked above) is what they'll check against.
11. Once merged, no further action is needed on the Ball side — `vcpkg
    install ball-lang` (or whatever name was settled on in step 1) starts
    working for every vcpkg user. Nothing in this repo needs to change.

None of steps 1–10 can be performed by CI or by an agent working in this
repo: they require a `microsoft/vcpkg`-side fork, an individual's CLA
signature, and human review from the vcpkg team. This directory's job ends
at "the port files are ready to be carried over."
