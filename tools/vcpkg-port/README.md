# vcpkg port staging (issue #368)

This directory is a **staging area**, not a live submission. It holds a draft
`ports/ball-lang/{vcpkg.json,portfile.cmake}` in the exact shape
[microsoft/vcpkg](https://github.com/microsoft/vcpkg) expects for a new port,
so a maintainer can carry it into a fork and open a PR there. The port files
themselves stay inert — they are not wired into the root `buf.gen.yaml` or any
CMake file, and CI never modifies them.

The Releases leg of issue #368 (`.github/workflows/release-cpp.yml`) does
**not** depend on this directory or on vcpkg landing upstream.

## CI smoke: does the recipe actually build? (`vcpkg` job in `ci.yml`)

The port carried `SHA512 0 # PLACEHOLDER` from the day it was written — vcpkg's
own tell that no tool, human or automated, had ever resolved or built it. So
`.github/workflows/ci.yml`'s **`vcpkg port smoke (x64-linux)`** job now proves
the recipe builds against the current `cpp/` tree, before an external vcpkg
maintainer becomes the first person to try it:

1. bootstrap `microsoft/vcpkg` pinned to a fixed release tag *and* its commit
   sha (a moved tag fails the job — a tag alone is not a pin);
2. pre-generate the self-host sidecar (`dart/self_host/lib/{cli_rt.h,
   engine_rt.cpp}`) with a real Dart toolchain, tar it, and **delete it from the
   checkout** — see "Self-hosted verbs" below for why the deletion is the whole
   point;
3. `python3 tools/vcpkg-port/make_ci_overlay.py <dir> <checkout> <sidecar.tar.gz>`
   **generates** the CI overlay from the real port, replacing exactly its two
   network fetches — `vcpkg_from_github(...)` with `set(SOURCE_PATH "<checkout>")`
   and `vcpkg_download_distfile(...)` with
   `set(BALL_SELFHOST_ARCHIVE "<sidecar.tar.gz>")`. Every other line,
   `vcpkg_check_features` / the extraction / `vcpkg_cmake_configure` /
   `vcpkg_cmake_install` / `vcpkg_copy_tools` / `vcpkg_install_copyright`
   included, stays byte-identical to the submission file, so a hand-maintained
   duplicate cannot rot out of sync with what is actually submitted (the job
   prints the `diff`, asserts it is exactly two hunks, and asserts the overlay
   is hermetic — no `vcpkg_from_*` / `vcpkg_download_distfile` call survives);
4. `vcpkg install ball-lang --overlay-ports=<dir> --triplet x64-linux`;
5. assert `installed/x64-linux/tools/ball-lang/ball` exists, `ball version`
   prints something, and — since issues #368/#361 — that `ball run` matches
   `tests/conformance/100_complex_control_flow.expected_output.txt` and
   `ball info` matches the Dart-native `cli_core` parity golden.

Step 5's `run`/`info` assertions are the load-bearing ones. `ball version` is
compiled in unconditionally (`BALL_CLI_VERSION`), so it passes identically in a
fully-verbed build and a fully-stubbed one and can never notice the verb loss
this port used to guarantee.

This is **new infrastructure, not a regression gate** — there is no prior
working state to have regressed. What it does catch from now on is a rename of
the `ball` target, a removed `install(TARGETS ball ...)` rule, a dropped
`BALL_BUILD_*` option, a `vcpkg_copy_tools TOOL_NAMES` mismatch, or a broken
self-host sidecar download/unpack.

It earned its keep on its very first run: the staged portfile configured the
bare `${SOURCE_PATH}` (the repository root, which has no `CMakeLists.txt` — the
documented build is `cmake -S cpp -B cpp/build`), so the port failed with
*"The source directory ... does not appear to contain CMakeLists.txt"*. Fixed to
`${SOURCE_PATH}/cpp`. That is a defect an external vcpkg maintainer would have
hit on the first build of the submitted port.

Residual gap: x64-linux only, matching the existing Linux-only
`BALL_BUILD_PROTOBUF_RT` precedent. OS-specific portfile problems (an MSVC
linker-flag interaction under vcpkg's applied `CMAKE_CXX_FLAGS`, say) would
still surface for the first time during upstream review.

Run it locally (Linux/WSL; it is a full `cpp/` CMake build inside vcpkg's
sandbox) with:

```bash
# Compile/encode/version only — no sidecar needed, so the third argument can
# point anywhere; the `[core]` install never reads it.
python3 tools/vcpkg-port/make_ci_overlay.py /tmp/overlay "$PWD" /tmp/none.tar.gz
vcpkg install 'ball-lang[core]' --overlay-ports=/tmp/overlay --triplet x64-linux

# Every verb — needs the sidecar, i.e. Dart + a bootstrap ball_cpp_compile:
cmake -S cpp -B cpp/ci-build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/ci-build --target ball_cpp_compile
dart run dart/compiler/tool/compile_engine_cpp.dart --monolithic
(cd dart && dart run compiler/tool/gen_cli_json.dart && dart run compiler/tool/gen_cli_cpp.dart)
tar -C dart/self_host/lib -czf /tmp/selfhost.tar.gz cli_rt.h engine_rt.cpp
python3 tools/vcpkg-port/make_ci_overlay.py /tmp/overlay "$PWD" /tmp/selfhost.tar.gz
vcpkg install ball-lang --overlay-ports=/tmp/overlay --triplet x64-linux
```

Since `v1.64.0` the **submission port itself** installs — no generator, no
overlay rewriting, the real tag and the real hashes (this is what "Proven
against a REAL release" below ran). Neither Dart nor a bootstrap compiler is
needed: the sidecar comes from the release.

```bash
# On a memory-capped box, cap the concurrency first: the monolithic
# engine_rt.cpp translation unit plus nproc-wide parallelism OOM-kills cc1plus
# (4 GB WSL, nproc 20 -> the whole distro fell over until VCPKG_MAX_CONCURRENCY=2).
export VCPKG_MAX_CONCURRENCY=2
vcpkg install ball-lang --overlay-ports=tools/vcpkg-port/ports --triplet x64-linux
"$VCPKG_ROOT/installed/x64-linux/tools/ball-lang/ball"   run tests/conformance/100_complex_control_flow.ball.json
# `vcpkg remove ball-lang` between feature sets: with ball-lang already
# installed, `vcpkg install 'ball-lang[core]'` is a 15 ms no-op, not a build.
```

## Proven against a REAL release: `v1.64.0` (2026-09-05)

The CI smoke above is deliberately hermetic: `make_ci_overlay.py` replaces the
port's **two network fetches** with local paths so the job can run on a commit
no tag exists for yet. That is the right shape for a per-PR gate — and it is
also precisely why the two things it swaps out had never been exercised by
anything, human or automated: the `vcpkg_from_github` `REF`/`SHA512` pair, and
the `vcpkg_download_distfile` of the release asset. Both `SHA512`s stayed `0`,
and `version-semver` stayed at the `1.26.0` it was staged with in July.

So the submission port — unmodified, no overlay — has now been installed from
the real `v1.64.0` release (published 2026-09-03) on `x64-linux`, against a
`microsoft/vcpkg` checkout pinned to the same `2026.07.29` tag and
`9e593bb18ea69cc5095e012465dcd675a822ed0d` commit `ci.yml` pins.

**RED** — the port exactly as it was staged. Note the second defect it exposes:
`version-semver` is not decoration, it is what `REF "v${VERSION}"` resolves, so
the stale `1.26.0` placeholder had the port fetching a two-month-old release
(61 releases back from `v1.64.0`) rather than the one being submitted:

```text
Installing 4/4 ball-lang[core,selfhost]:x64-linux@1.26.0...
Downloading https://github.com/Ball-Lang/ball/archive/v1.26.0.tar.gz -> Ball-Lang-ball-v1.26.0.tar.gz
Successfully downloaded Ball-Lang-ball-v1.26.0.tar.gz
error: failing download because the expected SHA512 was all zeros, please change the expected SHA512 to: e9755cfdbce6adb2aac2ab10e3b92e4d6cd81490c542684c43e572624548089c8bb47b15a57d5dcaa24080c2654e39f085dcf9903ace0eeb16c1f0cdda7840d2
CMake Error at scripts/cmake/vcpkg_download_distfile.cmake:134 (message):
  Download failed, halting portfile.
Call Stack (most recent call first):
  scripts/cmake/vcpkg_from_github.cmake:120 (z_vcpkg_download_distfile)
  .../tools/vcpkg-port/ports/ball-lang/portfile.cmake:22 (vcpkg_from_github)
  scripts/ports.cmake:209 (include)

error: building ball-lang:x64-linux failed with: BUILD_FAILED
```

Filling only the *source* hash just moves the failure one call down — the
sidecar's own placeholder is a second, independent RED (reproduced against a
scratch copy of the port, so nothing in the tree was left half-filled):

```text
Downloading https://github.com/Ball-Lang/ball/releases/download/v1.64.0/ball-selfhost-cpp-src-v1.64.0.tar.gz -> ball-selfhost-cpp-src-v1-00000000.64.0.tar.gz
error: failing download because the expected SHA512 was all zeros, please change the expected SHA512 to: ee24364ebe55545b65384960e04ae5ebb7593133a4c6d65ba6fdccfc0c80e3ddee0ac776d00e7891cf499f26353fb670497e7e2e533fc17b56c188730c523f96
  .../ports/ball-lang/portfile.cmake:73 (vcpkg_download_distfile)
error: building ball-lang:x64-linux failed with: BUILD_FAILED
```

**The hashes**, obtained the way the packaging tutorial prescribes (install
once with `SHA512 0`, read the value out of the failure) and then
cross-checked independently — vcpkg's message alone is a single source:

| artifact | `SHA512` | independent cross-check |
| --- | --- | --- |
| `archive/v1.64.0.tar.gz` | `0622de99…a63fca28` | `sha512sum` of vcpkg's own `downloads/` copy **and** of a separate `curl` of the same URL — all three agree |
| `ball-selfhost-cpp-src-v1.64.0.tar.gz` | `ee24364e…730c523f96` | the release's own `.sha256` sidecar and the combined `SHA256SUMS.txt` both verify (`sha256sum -c` → `OK`), and the archive unpacks to exactly `cli_rt.h` + `engine_rt.cpp` — the two names `NO_REMOVE_ONE_LEVEL` and `cpp/cli/CMakeLists.txt`'s `EXISTS` gates depend on |

Lowercase hex, as the maintainer guide requires for the `SHA512` parameter.

**GREEN** — both feature sets the port defines, same command, same overlay:

```text
$ vcpkg install 'ball-lang[core]' --overlay-ports=tools/vcpkg-port/ports --triplet x64-linux
-- Using cached Ball-Lang-ball-v1.64.0.tar.gz
-- ball-lang: self-hosted verbs stubbed (feature 'selfhost' not selected) — compile/encode/version only
-- Installing: .../ball-lang_x64-linux/share/ball-lang/copyright
-- Performing post-build validation
All requested installations completed successfully in: 14 min
$ installed/x64-linux/tools/ball-lang/ball version
ball 0.3.0+6
$ installed/x64-linux/tools/ball-lang/ball run tests/conformance/100_complex_control_flow.ball.json
ball run: unavailable — this `ball` was built without the self-hosted engine (engine_rt).
                                                     # exit 2 — the DOCUMENTED [core] outcome:
                                                     # no sidecar download attempted, no hard failure

$ vcpkg install ball-lang --overlay-ports=tools/vcpkg-port/ports --triplet x64-linux
-- Using cached Ball-Lang-ball-v1.64.0.tar.gz
Downloading https://github.com/Ball-Lang/ball/releases/download/v1.64.0/ball-selfhost-cpp-src-v1.64.0.tar.gz -> ball-selfhost-cpp-src-v1.64.0.tar.gz
Successfully downloaded ball-selfhost-cpp-src-v1.64.0.tar.gz
-- ball-lang: self-hosted verbs ENABLED (run/info/validate/tree)
-- Performing post-build validation
All requested installations completed successfully in: 13 min
$ installed/x64-linux/tools/ball-lang/ball version
ball 0.3.0+6
$ installed/x64-linux/tools/ball-lang/ball run tests/conformance/100_complex_control_flow.ball.json
62
15
                                                     # byte-identical (modulo trailing whitespace) to
                                                     # tests/conformance/100_complex_control_flow.expected_output.txt
$ installed/x64-linux/tools/ball-lang/ball info tests/conformance/100_complex_control_flow.ball.json
Program: encoded v1.0.0
Entry:   main.main
Modules: 2

  std (base)
    typeDefs:  3
    functions: 13
    desc:      Universal standard library base module
  main
    functions: 1

# installed binary: 2,942,041 bytes for [core] vs 8,034,153 bytes for the default
# set — the sidecar really is being compiled in, not merely downloaded.
```

Also caught while here: `vcpkg format-manifest` — which the maintainer guide
*requires* ("We require that the manifest file be formatted") — had never been
run on this manifest. It rewrites `vcpkg.json`, dropping the redundant
`"port-version": 0`, because `0` is the default and the canonical spelling is
to omit it. The port version is unchanged; it is simply now canonical.

**Regression guard.** The placeholders cannot come back silently:
`test/test_selfhost_asset_wiring.sh` (already always-run in `ci.yml`'s `Proto
Checks` job) now also asserts that the portfile declares exactly two `SHA512`
arguments, that each is a real 128-hex digest rather than `0`, and that every
literal `vX.Y.Z` written in `portfile.cmake` equals `vcpkg.json`'s
`version-semver` — so bumping the version without recomputing both hashes is a
red build here, not a broken port discovered by a vcpkg maintainer.

What this does **not** prove: any triplet other than `x64-linux` (submission
step 8 still stands in full), and nothing about the `microsoft/vcpkg`-side
`versions/` database — `x-add-version` only works inside a vcpkg checkout and
is deliberately *not* run here (step 7).

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

## Self-hosted verbs: how a Dart-free vcpkg build gets `run`/`info`/`validate`/`tree`

Ball's self-hosted verbs (`run`, `info`, `validate`, `tree`) are compiled from
a Ball program (`dart/self_host/`) through the C++ compiler itself, as a
**pre-build code-generation step that needs Dart** (see
`cpp/cli/CMakeLists.txt`'s `EXISTS` gates on `dart/self_host/lib/{cli_rt.h,
engine_rt.cpp}`, and `CLAUDE.md`'s "Build & Test" section). vcpkg's sandboxed
builds have no Dart toolchain and no network access beyond declared downloads,
so this port used to ship a permanently stubbed `ball` — `compile`/`encode`/
`version` real, everything else a fail-loud stub.

That gap is closed (issues #368/#361) without committing a single generated
file, i.e. without touching `CLAUDE.md`'s "never hand-edit/commit generated
files" invariant:

1. `.github/workflows/release-cpp.yml` already ran the whole Dart + self-host
   pipeline before building the Releases binaries. It now also tars the two
   generated sources — flat, no wrapping directory — and uploads them as
   **`ball-selfhost-cpp-src-vX.Y.Z.tar.gz`**, from the `linux-x64` leg only
   (Ball's compiler emits them from Ball source, so they are
   platform-independent, and one uploader means the matrix legs —
   `linux-x64`, `macos-arm64`, `macos-x64` — cannot race `--clobber` on one
   filename; `tools/test/test_release_cpp_targets.sh` asserts there is
   exactly one such uploader and that it names a leg the matrix builds).
2. `portfile.cmake` declares a **`selfhost` feature, on by default**. When
   selected it `vcpkg_download_distfile`s that asset from
   `https://github.com/Ball-Lang/ball/releases/download/v${VERSION}/...` —
   the same `v${VERSION}` its `vcpkg_from_github` REF uses — extracts it, and
   copies `cli_rt.h` + `engine_rt.cpp` into
   `${SOURCE_PATH}/dart/self_host/lib/` before `vcpkg_cmake_configure`. The
   existing `EXISTS` gates then produce a fully-verbed `ball`.
3. `vcpkg install ball-lang[core]` drops the feature and yields exactly the
   old compile/encode/version-only build — no download attempted, no failure.
   That opt-out is *how* the sidecar is optional: `vcpkg_download_distfile` has
   no non-fatal mode ([reference][distfile-ref]), so a feature is the only
   mechanism vcpkg offers for "this build does not need it". A sidecar that is
   selected but broken still fails loudly, per `CLAUDE.md`'s fail-loud rule —
   silently handing a user a verbless `ball` is the outcome being prevented,
   not the fallback.

[distfile-ref]: https://learn.microsoft.com/en-us/vcpkg/maintainers/functions/vcpkg_download_distfile

Two things about this are load-bearing enough to be pinned by
`tools/vcpkg-port/test/test_selfhost_asset_wiring.sh` (an always-run,
sub-second unit test in `ci.yml`'s `Proto Checks` job), because every failure
mode here is a *silent* verb loss with a green log:

* the asset name is spelled in `release-cpp.yml` and in `portfile.cmake`, which
  never meet at runtime — a rename on one side 404s the sidecar for **every**
  future release, not just the next one;
* `ci.yml`'s vcpkg job pre-generates the sidecar *inside the very checkout
  vcpkg builds from*, so it must delete those files before `vcpkg install` or
  the `EXISTS` gates fire off the leftovers and the smoke proves nothing about
  the port.

Both `SHA512` placeholders — the source tarball's and the sidecar's — needed a
real tagged release carrying the asset before they could be filled in. That
release exists: they now hold the `v1.64.0` hashes, proven by an overlay
install against the real release (see "Proven against a REAL release" above),
and a CI gate keeps them from regressing to `SHA512 0`.

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
3. ~~**Bump the version.**~~ **DONE (in this repo).** `vcpkg.json` pins
   `version-semver: "1.64.0"`, the tag both `SHA512`s were computed from.
   Submitting a *different* tag means redoing step 5 for it — the version and
   the two hashes are one unit, and CI fails if they disagree.
4. Fork `microsoft/vcpkg`, add it as a remote, branch, and copy
   `ports/ball-lang/` from this directory into `<fork>/ports/ball-lang/`.
5. ~~**Fill in the real `SHA512`.**~~ **DONE (in this repo)** for `v1.64.0`,
   both of them, verbatim evidence above. The recipe if a later tag is
   submitted instead: `vcpkg install ball-lang --overlay-ports=<path to this
   dir>/ports --triplet x64-linux` with `SHA512 0`, and paste the hash the
   failed download prints. Do it for the sidecar too — filling only the source
   hash just moves the failure down one call.
6. ~~`vcpkg format-manifest --all`~~ **DONE (in this repo)** — `vcpkg
   format-manifest tools/vcpkg-port/ports/ball-lang/vcpkg.json` is now a
   no-op. Re-run it after any manifest edit; the maintainer guide requires it.
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

Steps 3, 5 and 6 are done, in this repo, and gated. The rest cannot be
performed by CI or by an agent working here: they require a
`microsoft/vcpkg`-side fork, an individual's CLA signature, and human review
from the vcpkg team. This directory's job ends at "the port files are ready to
be carried over" — and, as of `v1.64.0`, at "and they have actually been built
from a real release."

Two things worth deciding *before* opening that PR, beyond the port name:

* **Portfile comment density.** The maintainer guide asks that portfiles be
  "short, simple, and as declarative as possible." This one is heavily
  commented because it doubles as the in-repo record of *why* each line is
  shaped the way it is. Consider condensing it for the upstream copy — the
  rationale is preserved here, in this README.
* **The project-maturity bar.** The guide accepts a project whose "release is
  at least six months old" *or* which "demonstrates at least six months of
  active public development." Ball's first GitHub Release is 2026-04-17, so
  the release-age clause is not met until ~2026-10-17; the development-history
  clause (repository public since 2023-05-15, 150+ releases) is what the
  submission would rest on today.
