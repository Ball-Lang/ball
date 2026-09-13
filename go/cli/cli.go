// Package cli is the `ball` command-line interface for the Go toolchain (epic
// #426 Phase 5): the four core verbs run / compile / encode / check over
// go/engine, go/compiler, and go/encoder. cmd/ball is the thin binary entry
// point; this package holds the dispatch and each verb's implementation so the
// whole CLI is exercisable in-process by the tests (via Run) without spawning a
// subprocess.
//
// The verb surface mirrors the Rust (rust/cli) and C# (csharp/cli) CLIs': the
// core four plus the self-hosted cli-core verbs info / validate / tree / version
// (issue #570), whose report text is computed by dart/shared/lib/cli_core.dart
// compiled through the Ball → Go compiler, so every `ball` prints byte-identical
// reports.
//
// Every verb works in every build. The two generated artifacts the CLI needs —
// go/engine/compiled/compiled_engine.go (for `run`) and
// go/cli/compiled/compiled_cli.go (for the cli-core verbs) — are TRACKED since
// #586 and carry no build constraint, because `go install` accepts no `-tags`
// and the module a proxy serves is the repository at the tag. See
// go/cli/AGENTS.md.
package cli

import (
	"fmt"
	"io"
)

// Run parses args (the process arguments after the program name), dispatches to
// the named subcommand, and returns the process exit code. Diagnostics go to
// stderr; a command's own output (compiled source, encoded program, run output,
// check summary) goes to stdout. It never panics out to the caller: an
// unexpected panic in a compiler/encoder path is recovered and reported as exit
// 2, so the binary fails loud with a message instead of a Go stack trace.
func Run(args []string, stdout, stderr io.Writer) (code int) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(stderr, "ball: internal error: %v\n", r)
			code = 2
		}
	}()

	if len(args) == 0 {
		writeUsage(stderr)
		return 2
	}

	cmd, rest := args[0], args[1:]
	switch cmd {
	case "-h", "--help", "help":
		writeUsage(stdout)
		return 0
	case "run":
		return finish(cmdRun(rest, stdout), stderr)
	case "compile":
		return finish(cmdCompile(rest, stdout), stderr)
	case "encode":
		return finish(cmdEncode(rest, stdout), stderr)
	case "check":
		return finish(cmdCheck(rest, stdout), stderr)
	case "info":
		return finish(cmdInfo(rest, stdout), stderr)
	case "validate":
		return finish(cmdValidate(rest, stdout), stderr)
	case "tree":
		return finish(cmdTree(rest, stdout), stderr)
	case "version":
		return finish(cmdVersion(rest, stdout), stderr)
	default:
		fmt.Fprintf(stderr, "ball: unknown command %q\n\n", cmd)
		writeUsage(stderr)
		return 2
	}
}

// finish maps a subcommand result onto an exit code, printing a non-empty
// failure message to stderr (prefixed "ball: "). A nil error is exit 0.
func finish(err *cliError, stderr io.Writer) int {
	if err == nil {
		return 0
	}
	if err.msg != "" {
		fmt.Fprintf(stderr, "ball: %s\n", err.msg)
	}
	return err.exitCode()
}

func writeUsage(w io.Writer) {
	fmt.Fprint(w, `ball — the Ball language CLI (Go toolchain)

Usage:
  ball <command> [arguments]

Commands:
  run      <program.ball.json>   Execute a Ball program via the self-hosted engine
  compile  <program.ball.json>   Compile a Ball program to Go source        [-o out.go]
  encode   <source.go>           Encode a Go source file into a Ball program [-lib] [-o out] [-format json|binary]
                                 (-lib: no func main() required; the result is non-runnable)
  check    <program.ball.json>   Parse and validate a Ball program without running it [-compile]
  info     <program.ball.json>   Print a program's structure (modules, functions, types)
  validate <program.ball.json>   Validate a program and print the portable report
  tree     <program.ball.json>   Print a program's module/import tree
  version                        Print the CLI version

Programs are read as proto3 JSON (.ball.json / .json) or binary protobuf (.bin / .pb),
sniffed by extension.

Exit codes: 0 success · 1 runtime error · 2 invalid program / usage · 3 I/O error.
`)
}
