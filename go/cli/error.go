package cli

import "fmt"

// cliError is a CLI-level failure carrying its own process exit code. Every
// subcommand returns *cliError (nil on success); Run prints it to stderr
// (prefixed "ball: ") and exits with exitCode. The exit-code contract mirrors
// the Rust CLI (rust/cli/src/error.rs) so the four Go verbs behave identically:
//
//	0  success (the absence of a *cliError — never represented here)
//	1  runtime error — a program ran but failed, or `run` in a build without
//	   the self-hosted engine (ErrSelfHostPending)
//	2  invalid/unparseable program — bad .ball.json/.ball.pb shape, Go source
//	   `encode` couldn't turn into a program, a loaded program was too malformed
//	   to compile, or `check` found the program invalid; also usage errors
//	3  file-not-found / other I/O error reading input or writing --output
type cliError struct {
	code int
	// msg is the human-readable failure, printed by Run prefixed "ball: ". An
	// empty msg suppresses that print (used for a failure already reported to
	// stderr), leaving only the exit code.
	msg string
}

func (e *cliError) Error() string { return e.msg }

func (e *cliError) exitCode() int { return e.code }

// ioErr — exit 3: an input file could not be read, or an output could not be
// written.
func ioErr(format string, args ...any) *cliError {
	return &cliError{code: 3, msg: fmt.Sprintf(format, args...)}
}

// parseErr — exit 2: the input was not a valid ball.v1.Program / encodable Go
// source, a loaded program was too malformed to compile, or `check` found it
// invalid.
func parseErr(format string, args ...any) *cliError {
	return &cliError{code: 2, msg: fmt.Sprintf(format, args...)}
}

// runtimeErr — exit 1: a program executed but failed, or `run` cannot run
// because the self-hosted engine is not built in (ErrSelfHostPending).
func runtimeErr(format string, args ...any) *cliError {
	return &cliError{code: 1, msg: fmt.Sprintf(format, args...)}
}
