//go:build selfhost

package conformance

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// hangingProgram is a minimal Ball program that never terminates: `while (true)
// {}`. Control flow dispatches by name (module "std", function "while"), so no
// std module declaration is needed; the loop keeps re-entering the compiled
// engine's per-expression evaluator, which is exactly where the cooperative
// execution-timeout guard lives.
const hangingProgram = `{
  "entryModule": "main",
  "entryFunction": "main",
  "modules": [
    {
      "name": "main",
      "functions": [
        {
          "name": "main",
          "body": {
            "call": {
              "module": "std",
              "function": "while",
              "input": {
                "messageCreation": {
                  "fields": [
                    {"name": "condition", "value": {"literal": {"boolValue": true}}},
                    {"name": "body", "value": {"literal": {"boolValue": true}}}
                  ]
                }
              }
            }
          }
        }
      ]
    }
  ]
}`

// TestRunawayFixtureIsBoundedAndReportedTimeout proves the issue-#436 hardening:
// a deliberately non-terminating fixture is stopped by the compiled engine's
// cooperative execution-timeout guard, reported as a fixture-level "timeout",
// bounded well under the hard-deadline backstop, and — crucially — leaves no
// goroutine spinning behind it.
func TestRunawayFixtureIsBoundedAndReportedTimeout(t *testing.T) {
	// A small cooperative budget keeps the test fast. runOne feeds this to the
	// engine as its self-abort point; the select backstop is budget +
	// hardDeadlineGrace (~10s), so anything finishing well under that proves the
	// cooperative guard — not the backstop — stopped the runaway.
	t.Setenv("BALL_TIMEOUT_MS", "200")

	path := filepath.Join(t.TempDir(), "hang.ball.json")
	if err := os.WriteFile(path, []byte(hangingProgram), 0o644); err != nil {
		t.Fatalf("write hanging fixture: %v", err)
	}

	before := runtime.NumGoroutine()

	start := time.Now()
	res := runOne("hang", path, "")
	elapsed := time.Since(start)

	if res.Status != "timeout" {
		t.Fatalf("runaway fixture: got status %q (detail %q), want %q",
			res.Status, res.Detail, "timeout")
	}

	// Must be bounded by the cooperative budget, not the far-longer select
	// backstop — otherwise the goroutine spun until the hard deadline (a leak).
	if elapsed >= hardDeadlineGrace {
		t.Fatalf("runaway fixture took %v; the cooperative timeout did not stop "+
			"it (it fell through to the ~%v backstop, i.e. leaked)",
			elapsed, hardDeadlineGrace)
	}

	// The engine's self-abort must have terminated the worker goroutine. Poll a
	// little to let it fully unwind; a leaked goroutine keeps the count above
	// baseline indefinitely.
	deadline := time.Now().Add(3 * time.Second)
	for {
		runtime.Gosched()
		if runtime.NumGoroutine() <= before {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("goroutine leak: %d goroutines still running (baseline %d) "+
				"after the runaway fixture was reported as a timeout",
				runtime.NumGoroutine(), before)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
