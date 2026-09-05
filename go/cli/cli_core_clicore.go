//go:build clicore

package cli

import (
	compiled "github.com/ball-lang/ball/go/cli/compiled"
	ballrt "github.com/ball-lang/ball/go/runtime"
)

// Under the `clicore` build tag the verbs delegate to the compiled CLI core —
// dart/shared/lib/cli_core.dart's report functions, compiled through the
// Ball → Go compiler by `go run ./cmd/regen` (issue #570). The reports are
// therefore the SAME computation the Dart CLI performs, not a Go re-write, which
// is what makes the golden-parity gate (cli_core_parity_test.go) meaningful.

// cliCoreBuiltIn reports whether this binary carries the compiled CLI core.
const cliCoreBuiltIn = true

func cliCoreInfo(view ballrt.Value) (string, *cliError) {
	return compiled.InfoReport(view), nil
}

func cliCoreTree(view ballrt.Value) (string, *cliError) {
	return compiled.TreeReport(view), nil
}

func cliCoreValidate(view ballrt.Value) (report string, ok bool, cerr *cliError) {
	return compiled.ValidateReport(view), compiled.ValidateOk(view), nil
}

func cliCoreVersionLine(version string) (string, *cliError) {
	return compiled.VersionLine(version), nil
}
