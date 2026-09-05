package cli

import (
	"flag"
	"io"
)

// cmdInfo implements `ball info <program.ball.json>` (issue #570): print the
// program's structure — name/version, entry point, and a per-module breakdown.
//
// The report text is NOT written here: it comes from the self-hosted CLI core
// (dart/shared/lib/cli_core.dart's infoReport, compiled through the Ball → Go
// compiler into go/cli/compiled), so it is byte-identical to what
// `dart run dart/cli/bin/ball.dart info` prints — proven by
// cli_core_parity_test.go's golden comparison. The Go sibling of
// rust/cli/src/commands/info.rs.
//
// Gating: in a default build (no `clicore` tag) cliCoreInfo returns the honest
// exit-1 "regenerate + rebuild" error. The program is still LOADED first, so a
// missing file (exit 3) or a malformed program (exit 2) reports its own, more
// specific failure — the same ordering rust/cli's `info` uses.
func cmdInfo(args []string, w io.Writer) *cliError {
	const usage = "ball info <program.ball.json>"
	view, cerr := loadCliCoreView("info", usage, flag.NewFlagSet("info", flag.ContinueOnError), args)
	if cerr != nil {
		return cerr
	}
	report, cerr := cliCoreInfo(view)
	if cerr != nil {
		return cerr
	}
	return printLine(w, report)
}
