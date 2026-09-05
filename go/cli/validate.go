package cli

import (
	"flag"
	"io"
)

// cmdValidate implements `ball validate <program.ball.json>` (issue #570):
// structural validation, reported in the self-hosted CLI core's own words
// (cli_core.validateOk + cli_core.validateReport), byte-identical to the Dart
// CLI's `validate`.
//
// Exit-code note (the same adaptation rust/cli/src/commands/validate.rs makes):
// the Dart CLI exits 1 on an invalid program — its generic "command failed"
// code, since Dart's runner has no exit-code contract of its own. go/cli's
// contract (error.go) reserves 1 for a RUNTIME failure and 2 for an
// invalid/unparseable program, and a failed `validate` is squarely the latter,
// so this returns parseErr (exit 2). The report TEXT still matches Dart exactly;
// only the numeric code is adapted to the pre-existing Go contract, exactly as
// `check` already does for structurally similar findings.
//
// `validate` is distinct from `check`: `check` is go/cli's own Go-target
// battery (with an opt-in dry-run compile), `validate` is the PORTABLE report
// every cli-core CLI shares.
func cmdValidate(args []string, w io.Writer) *cliError {
	const usage = "ball validate <program.ball.json>"
	view, cerr := loadCliCoreView("validate", usage, flag.NewFlagSet("validate", flag.ContinueOnError), args)
	if cerr != nil {
		return cerr
	}
	report, ok, cerr := cliCoreValidate(view)
	if cerr != nil {
		return cerr
	}
	if !ok {
		return parseErr("%s", report)
	}
	return printLine(w, report)
}
