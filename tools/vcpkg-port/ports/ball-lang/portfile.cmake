# ball-lang: the unified `ball` CLI (issue #367/#368) for the Ball
# programming language — compile / encode / run subcommands, plus the
# self-hosted info/validate/tree/version verbs.
#
# This is a pure CLI application: no headers or libraries are installed, so
# (like ports/vcpkg-tool-ninja, which packages the `ninja` build tool the
# same way) we only need a release build.
set(VCPKG_BUILD_TYPE release)

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO Ball-Lang/ball
    REF "v${VERSION}"
    SHA512 0 # PLACEHOLDER. `vcpkg install ball-lang --overlay-ports=<this dir's
             # parent>` against the real tag fails with "the expected SHA512
             # was all zeros, please change the expected SHA512 to: <hash>" —
             # paste that hash here before submitting (see ../README.md).
    HEAD_REF main
)

# This configures the FULL cpp/ CMake project (shared + compiler + encoder +
# cli + test) — there is no standalone `cpp/cli/CMakeLists.txt` entry point
# today, matching how a human would build the repo locally (see the root
# CLAUDE.md "Build & Test" section). Only the `ball` target and its link
# dependencies are ever BUILT or INSTALLED though, via the target-scoped
# `install(TARGETS ball ...)` rule in cpp/cli/CMakeLists.txt (issue #368) —
# vcpkg_cmake_install()'s generated `install` target does not pull in
# cpp/test/'s targets, which register no install() rules of their own.
#
# BALL_BUILD_PROTOBUF_RT / BALL_BUILD_UPSTREAM_CONFORMANCE both default OFF
# upstream; passed explicitly so a future default flip in the Ball repo can't
# silently start FetchContent'ing Google protobuf/abseil inside a vcpkg build.
vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DBALL_BUILD_PROTOBUF_RT=OFF
        -DBALL_BUILD_UPSTREAM_CONFORMANCE=OFF
)
vcpkg_cmake_install()
vcpkg_copy_tools(
    TOOL_NAMES ball
    DESTINATION "${CURRENT_PACKAGES_DIR}/tools/${PORT}"
    AUTO_CLEAN
)

# ── Known limitation: verb coverage in a from-source vcpkg build ──
# `ball compile` / `ball encode` / `ball version` are always real (they only
# need the C++ compiler+encoder libraries built here). `ball run` and the
# self-hosted `info`/`validate`/`tree` verbs are the SELF-HOSTED half of the
# CLI (issue #367): they need Dart + `ball_cpp_compile --library` to
# pre-generate dart/self_host/lib/{engine_rt.cpp,cli_rt.h} BEFORE this CMake
# project is configured (see cpp/cli/CMakeLists.txt's EXISTS gates, and
# .github/workflows/release-cpp.yml, which runs that Dart pipeline before
# building `ball`). vcpkg's sandboxed, network-isolated, Dart-free build
# cannot do that, so those files are absent and the affected verbs compile as
# fail-loud stubs — exactly the "build-isolated main cpp CI job" behavior
# described in PR #374, not a defect specific to this port. The GitHub
# Releases binaries (built by release-cpp.yml) are the fully-verbed build;
# this vcpkg port is compile/encode/version-only until a Dart-free way to
# pre-generate those two generated files ships (tracked as a possible
# follow-up to #368, not yet filed).

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
