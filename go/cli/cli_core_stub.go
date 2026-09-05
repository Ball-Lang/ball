//go:build !clicore

package cli

import (
	ballrt "github.com/ball-lang/ball/go/runtime"
)

// The default build carries no compiled CLI core: go/cli/compiled/compiled_cli.go
// is a gitignored build artifact absent from a fresh checkout, so every verb
// backed by it degrades HONESTLY — exit 1 with an actionable regenerate hint,
// never a silent success and never a broken build. This is the same contract
// `run` has without `-tags selfhost` (go/engine's run_stub.go), and the Go
// analog of rust/cli's `#[cfg(not(feature = "cli_core"))]` arms and csharp/cli's
// `-p:CliCore=false` stubs.

// cliCoreBuiltIn reports whether this binary carries the compiled CLI core. Used
// by the usage text and by the tests to assert the right half of the contract.
const cliCoreBuiltIn = false

// cliCorePendingHint is the message every cli-core verb reports in a default
// build. It names the exact two commands that fix it.
const cliCorePendingHint = "`ball %s` needs the self-hosted CLI core, which is not built into this " +
	"binary: go/cli/compiled/compiled_cli.go is a generated, gitignored artifact.\n" +
	"Regenerate it and rebuild with the clicore build tag:\n" +
	"    cd dart && dart run compiler/tool/gen_cli_json.dart\n" +
	"    cd go/cli && go run ./cmd/regen && go build -tags clicore ./cmd/ball"

func cliCoreInfo(_ ballrt.Value) (string, *cliError) {
	return "", runtimeErr(cliCorePendingHint, "info")
}

func cliCoreTree(_ ballrt.Value) (string, *cliError) {
	return "", runtimeErr(cliCorePendingHint, "tree")
}

func cliCoreValidate(_ ballrt.Value) (report string, ok bool, cerr *cliError) {
	return "", false, runtimeErr(cliCorePendingHint, "validate")
}

func cliCoreVersionLine(_ string) (string, *cliError) {
	return "", runtimeErr(cliCorePendingHint, "version")
}
