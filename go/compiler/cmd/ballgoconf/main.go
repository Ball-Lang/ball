// Command ballgoconf is the Ball → Go *compiler* conformance sweep: it compiles
// every tests/conformance fixture with go/compiler, builds and runs the emitted
// Go, and byte-compares stdout to the golden. It prints the CI-parseable line
//
//	Results: N passed, M failed, T total (K skipped carve-outs)
//
// on stdout, pass or fail, and exits 1 if any fixture failed.
//
// Usage:
//
//	go run ./cmd/ballgoconf            # whole corpus
//	go run ./cmd/ballgoconf 042_fizz   # one fixture, with a full expected/actual dump
//
// Env: BALL_TIMEOUT_MS (per-fixture execution budget, default 120000),
// BALL_BUILD_TIMEOUT_MS (per-fixture `go build` budget, default 180000).
//
// This is a command rather than a `go test` so the default `go test ./compiler/...`
// stays fast: the sweep shells out to the Go toolchain 320 times.
package main

import (
	"fmt"
	"os"

	"github.com/ball-lang/ball/go/compiler/conformance"
)

func main() {
	only := ""
	if len(os.Args) > 1 {
		only = os.Args[1]
		// The runner's single-fixture dump is keyed off BALL_FIXTURE (same knob the
		// engine leg uses), so honour a positional name by setting it.
		os.Setenv("BALL_FIXTURE", only)
	} else if env := os.Getenv("BALL_FIXTURE"); env != "" {
		only = env
	}

	summary, err := conformance.RunAll(only)
	if err != nil {
		fmt.Fprintln(os.Stderr, "sweep failed:", err)
		os.Exit(2)
	}

	for _, r := range summary.Results {
		if r.Status != "pass" {
			fmt.Printf("FAILING [%s] %s %s\n", r.Name, r.Status, r.Detail)
		}
	}

	fmt.Printf("Results: %d passed, %d failed, %d total (%d skipped carve-outs)\n",
		summary.Passed, summary.Failed, summary.Total, summary.Skipped)

	if summary.Failed > 0 {
		os.Exit(1)
	}
}
