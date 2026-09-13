package compiler_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestStateErrorMessageContract compiles the conformance fixture that pins what
// a CAUGHT StateError reads as (issue #616) and RUNS it, diffing the committed
// golden byte-for-byte.
//
// 463 proved the throw is typed; it prints a hardcoded literal from its catch
// bodies, so nothing pinned the caught VALUE. On this target the Go compiler's
// `try` binds the thrown value raw, so `to_string(e)` printed the bare type tag
// "StateError" for `list_find` — and `list_first` on an empty list threw an
// untyped `Thrown{Value: string}` that no typed clause could catch at all.
//
// Same reason this file exists as `list_find_contract_test.go` does: no CI leg
// compiles a conformance fixture to Go (go/engine/conformance runs the
// self-hosted ENGINE, and roundtrip.go re-encodes and runs on DART), so without
// it the compiler's route stays unexercised by the corpus.
func TestStateErrorMessageContract(t *testing.T) {
	fixture := filepath.Join("..", "..", "tests", "conformance", "465_state_error_message.ball.json")
	golden := filepath.Join("..", "..", "tests", "conformance", "465_state_error_message.expected_output.txt")

	prog := load(t, fixture)
	src := compileFmt(t, prog)
	for _, want := range []string{"ballrt.ListFind(", "ballrt.ListFirst("} {
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
		t.Errorf("caught-StateError observable:\n got %q\nwant %q", got, want)
	}
}
