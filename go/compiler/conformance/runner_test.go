package conformance_test

import (
	"os/exec"
	"testing"

	"github.com/ball-lang/ball/go/compiler/conformance"
)

// TestSingleFixtureSweep is the harness's own smoke test: it drives one known-good
// fixture end to end (Ball → Go → `go build` → run → golden diff) and asserts a
// POSITIVE pass count. Without this floor, a harness that discovered zero fixtures
// (a bad path, a renamed corpus) would happily print "0 passed, 0 failed" and read
// as green. The whole-corpus sweep is `go run ./cmd/ballgoconf`, deliberately not a
// test: it shells out to the Go toolchain once per fixture and would make the
// default `go test ./compiler/...` slow.
func TestSingleFixtureSweep(t *testing.T) {
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go toolchain not on PATH")
	}
	s, err := conformance.RunAll("101_simple_class")
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if s.Total != 1 {
		t.Fatalf("expected 1 fixture, got total=%d", s.Total)
	}
	if s.Passed != 1 {
		t.Fatalf("101_simple_class did not pass: %+v", s.Results)
	}
}

// TestUnknownFixtureIsAnError proves the positive floor: an empty sweep is an
// error, never a green zero.
func TestUnknownFixtureIsAnError(t *testing.T) {
	if _, err := conformance.RunAll("no_such_fixture_xyz"); err == nil {
		t.Fatal("expected an error for an unknown fixture, got nil")
	}
}
