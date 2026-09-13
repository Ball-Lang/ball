package compiler_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestStringSinkContract compiles the conformance fixture that pins the
// declared text sink (issue #630) and RUNS it, diffing the committed golden
// byte-for-byte.
//
// Before #630 the Go compiler had no sink at all: `grep -r __buffer__ go/`
// found nothing, so a Ball program using a `StringBuffer` — which every
// self-hosted engine runs fine, because an engine's own sink is compiled
// engine_std.dart rather than the compiler's base-call table — was REFUSED by
// this compiler. No CI leg compiles a conformance fixture to Go, so without
// this test the compiler's sink route would be entirely unexercised.
//
// The load-bearing assertion is the RUN, not the `strings.Contains`: the
// fixture appends to the sink inside a callee, so a by-value backing (Go's own
// `strings.Builder` documents "Do not copy a non-zero Builder") loses that
// append and nothing else — a silent wrong answer.
func TestStringSinkContract(t *testing.T) {
	fixture := filepath.Join("..", "..", "tests", "conformance", "465_string_sink.ball.json")
	golden := filepath.Join("..", "..", "tests", "conformance", "465_string_sink.expected_output.txt")

	prog := load(t, fixture)
	src := compileFmt(t, prog)
	if !strings.Contains(src, "ballrt.SinkWrite(") {
		t.Errorf("emitted Go missing ballrt.SinkWrite(\n---\n%s", src)
	}
	if !strings.Contains(src, "ballrt.SinkCreate(") {
		t.Errorf("emitted Go missing ballrt.SinkCreate(\n---\n%s", src)
	}
	if !strings.Contains(src, "ballrt.SinkToString(") {
		t.Errorf("emitted Go missing ballrt.SinkToString(\n---\n%s", src)
	}

	// Read the golden as BYTES and normalize only CRLF: a text-mode read would
	// collapse a semantic lone \r and silently corrupt the comparison.
	wantBytes, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	want := strings.ReplaceAll(string(wantBytes), "\r\n", "\n")

	if got := goRun(t, src); got != want {
		t.Errorf("string sink contract:\n got %q\nwant %q", got, want)
	}
}
