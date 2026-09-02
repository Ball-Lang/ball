package conformance

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// TestRoundTrip drives the whole tests/conformance corpus through
// compile (go/compiler) -> re-encode (go/encoder) -> run on the DART reference
// engine -> golden diff, and prints the CI-parseable Results line.
//
// It needs no build tag: this leg never touches the generated, gitignored
// compiled engine. It DOES need the Dart CLI on PATH (ground truth), so it skips
// itself when `dart` is unavailable rather than reporting a fake zero — a skip is
// visibly not a measurement, whereas "0 passed" would be indistinguishable from
// the honest baseline.
//
// This is a MEASUREMENT, not a gate: a near-zero result is the expected, honest
// answer (see roundtrip.go's doc comment), so the test never fails on the failure
// count. What it does assert is harness health — the sweep must have run at least
// one fixture. Run it with `go test -v` so the Results line reaches stdout (`go
// test` caches and discards a passing test's output otherwise).
func TestRoundTrip(t *testing.T) {
	only := os.Getenv("BALL_FIXTURE")
	summary, err := RunRoundTrip(only)
	if err != nil {
		// No Dart on PATH is an environment gap, not a measurement — skip loudly.
		if os.Getenv("BALL_DART") == "" && isDartMissing(err) {
			t.Skipf("round-trip leg needs the Dart reference engine on PATH: %v", err)
		}
		t.Fatalf("round-trip sweep failed: %v", err)
	}

	for _, r := range summary.Results {
		if r.Status != "pass" {
			fmt.Printf("FAILING [%s] %s %s\n", r.Name, r.Status, r.Detail)
		}
	}

	fmt.Printf("Results: %d passed, %d failed, %d total (%d skipped carve-outs)\n",
		summary.Passed, summary.Failed, summary.Total, summary.Skipped)

	// Positive floor only — an exit code plus a failure count cannot tell "all
	// passed" from "nothing ran". The failure count itself is reported, never
	// gated on: raising it is encoder/compiler work, not this harness's job.
	if summary.Total < 1 {
		t.Fatalf("the round-trip leg measured nothing (total=%d)", summary.Total)
	}
}

func isDartMissing(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "not on PATH") || strings.Contains(msg, "executable file not found")
}
