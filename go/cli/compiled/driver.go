//go:build clicore

package compiled

import (
	ballrt "github.com/ball-lang/ball/go/runtime"
)

// The exported surface over the generated report functions. The Ball → Go
// compiler emits each cli_core top-level function under its Ball name
// (`sanitize(f.GetName())` — see go/compiler's compileFunction), so
// `infoReport`/`validateOk`/`validateReport`/`treeReport`/`versionLine` are
// unexported identifiers in this package. These thin wrappers give package
// `cli` an exported, string-typed API, the same way go/engine's driver.go wraps
// the compiled engine's `BallEngine__new`/`run`.
//
// Every function takes the program's canonical proto3-JSON BallValue view (the
// one go/engine's loader builds and the compiled engine itself reads) and
// returns the report text with NO trailing newline — the caller adds it, so the
// bytes match the Dart CLI's `stdout.writeln(cli_core.xReport(program))`.

// InfoReport is `ball info`'s report — cli_core.infoReport.
func InfoReport(view ballrt.Value) string { return ballrt.ToStr(infoReport(view)) }

// TreeReport is `ball tree`'s report — cli_core.treeReport.
func TreeReport(view ballrt.Value) string { return ballrt.ToStr(treeReport(view)) }

// ValidateReport is `ball validate`'s report — cli_core.validateReport. It is
// the text for BOTH outcomes (valid and invalid); pair it with [ValidateOk] to
// pick the stream and the exit code.
func ValidateReport(view ballrt.Value) string { return ballrt.ToStr(validateReport(view)) }

// ValidateOk reports whether the program is structurally valid —
// cli_core.validateOk.
func ValidateOk(view ballrt.Value) bool {
	ok, _ := validateOk(view).(bool)
	return ok
}

// VersionLine is `ball version`'s single line — cli_core.versionLine, i.e.
// "ball " + version. Unlike the other verbs it takes the version string, not a
// program.
func VersionLine(version string) string {
	return ballrt.ToStr(versionLine(ballrt.Value(version)))
}
