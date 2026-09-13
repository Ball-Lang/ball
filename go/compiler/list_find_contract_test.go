package compiler_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestListFindNoMatchContract compiles the conformance fixture that pins
// std_collections.list_find's no-match contract (issue #597) and RUNS it,
// diffing the committed golden byte-for-byte.
//
// Before #597 the Go compiler had no `list_find` case at all, so this program
// was REFUSED ("unsupported base function std_collections.list_find") — safe,
// but it meant the Go target could not run a program every self-hosted engine
// (this one included) executes fine, because an engine's own list_find is
// compiled engine_std.dart, not the compiler's base-call table.
//
// No CI leg compiles a conformance fixture to Go (go/engine/conformance runs the
// self-hosted ENGINE; go/engine/conformance/roundtrip.go re-encodes and runs on
// DART), so without this test the compiler's route would be entirely
// unexercised by the corpus.
func TestListFindNoMatchContract(t *testing.T) {
	fixture := filepath.Join("..", "..", "tests", "conformance", "463_list_find_no_match.ball.json")
	golden := filepath.Join("..", "..", "tests", "conformance", "463_list_find_no_match.expected_output.txt")

	prog := load(t, fixture)
	src := compileFmt(t, prog)
	if !strings.Contains(src, "ballrt.ListFind(") {
		t.Errorf("emitted Go missing ballrt.ListFind(\n---\n%s", src)
	}

	// Read the golden as BYTES and normalize only CRLF: a text-mode read would
	// collapse a semantic lone \r and silently corrupt the comparison.
	wantBytes, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	want := strings.ReplaceAll(string(wantBytes), "\r\n", "\n")

	if got := goRun(t, src); got != want {
		t.Errorf("list_find no-match contract:\n got %q\nwant %q", got, want)
	}
}
