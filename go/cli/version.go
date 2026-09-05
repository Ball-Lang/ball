package cli

import (
	"flag"
	"io"
	"runtime/debug"
	"strings"
)

// moduleVersion is the fallback version `ball version` reports when the binary
// carries no module version stamp — i.e. every `go build` from a checkout, where
// runtime/debug reports "(devel)".
//
// VERSION POLICY (issue #366, as adopted by rust/cli/src/commands/version.rs):
// each CLI reports its OWN registry's package version, not a shared toolchain
// string. Go's registry is the module proxy, so the version here is the one the
// `go/<module>/vX.Y.Z` tags publish — which is single-sourced in this repo from
// the intra-repo `require` lines in every go/*/go.mod (see
// tools/go-module-proxy/build_local_proxy.py's --print-version and
// .github/workflows/tag-go-modules.yml).
//
// TestModuleVersionMatchesGoMod (version_test.go) is the drift guard: it parses
// go/cli/go.mod's own require block and fails if this constant and the published
// module version disagree, so a version bump cannot land here half-applied.
const moduleVersion = "0.1.0"

// toolchainVersion is the version string handed to cli_core.versionLine.
//
// A binary produced by `go install github.com/ball-lang/ball/go/cli/cmd/ball@vX.Y.Z`
// carries the resolved module version in its build info; a `go build` from a
// checkout carries "(devel)" (or nothing), and falls back to [moduleVersion].
// The leading "v" is trimmed so `ball version` reads "ball 0.1.0", matching the
// Rust/Dart/C# CLIs' unprefixed form.
func toolchainVersion() string {
	if bi, ok := debug.ReadBuildInfo(); ok {
		if v := bi.Main.Version; v != "" && v != "(devel)" {
			return strings.TrimPrefix(v, "v")
		}
	}
	return moduleVersion
}

// cmdVersion implements `ball version` (issue #570): print `ball <version>`.
//
// The line comes from the self-hosted CLI core (cli_core.versionLine), so — like
// every other cli-core verb — the FORMAT is the portable one every `ball` shares
// rather than a Go re-write. Unlike info/validate/tree it takes no program, so
// it accepts no positional arguments.
func cmdVersion(args []string, w io.Writer) *cliError {
	const usage = "ball version"
	positionals, cerr := parseCommand(flag.NewFlagSet("version", flag.ContinueOnError), "version", usage, args)
	if cerr != nil {
		return cerr
	}
	if len(positionals) != 0 {
		return parseErr("version: takes no arguments (usage: %s)", usage)
	}
	line, cerr := cliCoreVersionLine(toolchainVersion())
	if cerr != nil {
		return cerr
	}
	return printLine(w, line)
}
