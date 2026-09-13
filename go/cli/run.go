package cli

import (
	"flag"
	"io"
)

// cmdRun implements `ball run <program.ball.json>`: load the program and execute
// it via the self-hosted Go engine, writing each captured stdout line to w.
//
// The compiled engine (go/engine/compiled/compiled_engine.go) is a TRACKED
// artifact since #586, so `run` works in EVERY build — including the binary a
// `go install github.com/ball-lang/ball/go/cli/cmd/ball@vX.Y.Z` produces, which
// can pass no build tags. It used to be gated behind `-tags selfhost` and
// degraded to an exit-1 regenerate hint without it.
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
		return runtimeErr("run failed: %v", err)
	}
	for _, line := range lines {
		if werr := printLine(w, line); werr != nil {
			return werr
		}
	}
	return nil
}
