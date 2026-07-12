//go:build selfhost

package conformance

import (
	"fmt"
	"os"
	"testing"
)

// TestConformance drives the whole tests/conformance corpus through the compiled
// self-hosted engine and prints the CI-parseable Results line. Requires
// `-tags selfhost` (needs the generated compiled_engine.go). Set BALL_FIXTURE to
// run a single fixture with a full pass/fail dump.
func TestConformance(t *testing.T) {
	only := os.Getenv("BALL_FIXTURE")
	summary, err := RunAll(only)
	if err != nil {
		t.Fatalf("conformance sweep failed: %v", err)
	}

	for _, r := range summary.Results {
		if r.Status != "pass" {
			fmt.Printf("FAILING [%s] %s %s\n", r.Name, r.Status, r.Detail)
		}
	}

	fmt.Printf("Results: %d passed, %d failed, %d total (%d skipped carve-outs)\n",
		summary.Passed, summary.Failed, summary.Total, summary.Skipped)

	if summary.Failed > 0 {
		t.Fatalf("%d/%d conformance fixtures failed", summary.Failed, summary.Total)
	}
}
