package compiler_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTypedCatchClauseDispatch compiles the conformance fixture that pins typed
// `on <Type> catch` clause SELECTION (issue #615) and RUNS it, diffing the
// committed golden byte-for-byte.
//
// Before #615 compileTry emitted the FIRST catch clause as an unconditional
// catch-all and dropped every later one, so `throw StateError(...)` ran an
// `on ArgumentError catch` body — silently wrong output, never an error. No CI
// leg gates a PR on compiling a conformance fixture to Go (the `go-compiler`
// row in conformance-matrix.yml is a ratchet on a workflow with no
// `pull_request:` trigger), so without this test the fix would be unobserved
// PR-time.
func TestTypedCatchClauseDispatch(t *testing.T) {
	fixture := filepath.Join("..", "..", "tests", "conformance", "464_typed_catch_clause_dispatch.ball.json")
	golden := filepath.Join("..", "..", "tests", "conformance", "464_typed_catch_clause_dispatch.expected_output.txt")

	prog := load(t, fixture)
	src := compileFmt(t, prog)

	// The dispatch must be a real per-clause guard, not a single catch-all.
	for _, want := range []string{
		`ballrt.CatchMatches(__ex, "ArgumentError")`,
		`ballrt.CatchMatches(__ex, "StateError")`,
		`ballrt.CatchMatches(__ex, "FormatException")`,
		"ballrt.Rethrow()",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("emitted Go missing %s\n---\n%s", want, src)
		}
	}

	// Read the golden as BYTES and normalize only CRLF: a text-mode read would
	// collapse a semantic lone \r and silently corrupt the comparison.
	wantBytes, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	want := strings.ReplaceAll(string(wantBytes), "\r\n", "\n")

	if got := goRun(t, src); got != want {
		t.Errorf("typed catch clause dispatch:\n got %q\nwant %q", got, want)
	}
}

// TestNestedTryCatchTypesCompiles is the second half of the same contract: the
// pre-existing fixture 146 has a nested try whose inner clause list must select
// by type AND `rethrow` out to an outer clause list. It was silently wrong on
// this target from the day the Go compiler came online (it printed
// "FormatException - null" for every level) and nothing PR-gated noticed.
func TestNestedTryCatchTypesCompiles(t *testing.T) {
	fixture := filepath.Join("..", "..", "tests", "conformance", "146_nested_try_catch_types.ball.json")
	golden := filepath.Join("..", "..", "tests", "conformance", "146_nested_try_catch_types.expected_output.txt")

	prog := load(t, fixture)
	src := compileFmt(t, prog)

	wantBytes, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	want := strings.ReplaceAll(string(wantBytes), "\r\n", "\n")

	if got := goRun(t, src); got != want {
		t.Errorf("nested try/catch types:\n got %q\nwant %q", got, want)
	}
}
