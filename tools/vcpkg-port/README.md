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

Both `SHA512` placeholders — the source tarball's and the sidecar's — can only
be filled in once a real tagged release actually carries the asset; see the
submission flow below.

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
