package cli

import (
	"errors"
	"flag"
	"io"

	engine "github.com/ball-lang/ball/go/engine"
)

// cmdRun implements `ball run <program.ball.json>`: load the program and execute
// it via the self-hosted Go engine, writing each captured stdout line to w.
//
// Self-host gating: engine.Run() only drives the compiled engine when this
// binary is built with `-tags selfhost` (go/engine's run_selfhost.go). In a
// plain build engine.Run() returns ErrSelfHostPending, which surfaces here as a
// runtime error (exit 1) carrying the "regenerate compiled_engine.go … build
// with -tags selfhost" message — never a silent success and never a broken
// build. This is the Go analog of the Rust CLI's `self_host`-gated `run`.
func cmdRun(args []string, w io.Writer) *cliError {
	const usage = "ball run <program.ball.json>"
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	positionals, cerr := parseCommand(fs, "run", usage, args)
	if cerr != nil {
		return cerr
	}
	if len(positionals) != 1 {
		return parseErr("run: expected exactly one program path (usage: %s)", usage)
	}

	eng, cerr := loadEngine(positionals[0])
	if cerr != nil {
		return cerr
	}

	lines, err := eng.Run()
	if err != nil {
		if errors.Is(err, engine.ErrSelfHostPending) {
			return runtimeErr("%v", err)
		}
		return runtimeErr("run failed: %v", err)
	}
	for _, line := range lines {
		if werr := printLine(w, line); werr != nil {
			return werr
		}
	}
	return nil
}
