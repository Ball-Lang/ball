//go:build !selfhost

package cli

import (
	"strings"
	"testing"
)

// In the default build (no `selfhost` tag) the self-hosted engine driver is not
// compiled in, so `run` on any valid program must fail honestly with the
// rebuild-with-selfhost message (exit 1) — never a silent success, never a
// broken build. The selfhost-gated run_selfhost_test.go proves the real
// execution path.
func TestRunWithoutSelfHostFailsHonestly(t *testing.T) {
	prog := fixture(t, "examples", "hello_world", "hello_world.ball.json")
	stdout, stderr, code := runCLI("run", prog)
	if code != 1 {
		t.Fatalf("exit = %d, want 1 (stderr=%q)", code, stderr)
	}
	if stdout != "" {
		t.Errorf("run wrote to stdout in the default build: %q", stdout)
	}
	if !strings.Contains(stderr, "selfhost") {
		t.Errorf("stderr = %q, want a 'rebuild with -tags selfhost' message", stderr)
	}
}
