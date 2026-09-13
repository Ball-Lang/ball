package compiler_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTypeErrorMessageContract compiles the conformance fixture that pins what
// a CAUGHT TypeError reads as (issue #641) and RUNS it, diffing the committed
// golden byte-for-byte.
//
// `302_cast_patterns` proves a failed cast pattern THROWS; both of its catch
// bodies print a hardcoded literal, so nothing pinned the caught VALUE. On this
// target the compiler emitted `ballrt.NewMessage("TypeError", {message: …})`
// and `ops.go`'s `dartErrorToString` had no `TypeError` arm at all, so
// `to_string(e)` printed the bare type tag "TypeError" where Dart prints
// `type 'String' is not a subtype of type 'int' in type cast`.
//
// Same reason `state_error_contract_test.go` exists: no CI leg compiles a
// conformance fixture to Go (go/engine/conformance runs the self-hosted ENGINE,
// and roundtrip.go re-encodes and runs on DART), so without it the compiler's
// own route stays unexercised by the corpus.
func TestTypeErrorMessageContract(t *testing.T) {
	fixture := filepath.Join("..", "..", "tests", "conformance", "467_caught_type_error_to_string.ball.json")
	golden := filepath.Join("..", "..", "tests", "conformance", "467_caught_type_error_to_string.expected_output.txt")

	prog := load(t, fixture)
	src := compileFmt(t, prog)
	// The cast assert must reach the SUBJECT, not just the target type name:
	// Dart's message names the value's runtime type first.
	if !strings.Contains(src, "ballrt.CastAssert(") {
		t.Errorf("emitted Go missing ballrt.CastAssert(\n---\n%s", src)
	}

	// Read the golden as BYTES and normalize only CRLF: a text-mode read would
	// collapse a semantic lone \r and silently corrupt the comparison.
	wantBytes, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	want := strings.ReplaceAll(string(wantBytes), "\r\n", "\n")

	if got := goRun(t, src); got != want {
		t.Errorf("caught-TypeError observable:\n got %q\nwant %q", got, want)
	}
}
