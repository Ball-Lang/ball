package cli

import (
	"flag"
	"io"

	compiled "github.com/ball-lang/ball/go/cli/compiled"
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
// The program is LOADED before the report is built, so a missing file (exit 3)
// or a malformed program (exit 2) reports its own, more specific failure — the
// same ordering rust/cli's `info` uses.
func cmdInfo(args []string, w io.Writer) *cliError {
	const usage = "ball info <program.ball.json>"
	view, cerr := loadCliCoreView("info", usage, flag.NewFlagSet("info", flag.ContinueOnError), args)
	if cerr != nil {
		return cerr
	}
	return printLine(w, compiled.InfoReport(view))
}
