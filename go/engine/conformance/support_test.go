package conformance

import (
	"strings"
	"testing"
)

// The Go legs' error detail must survive the trip to a CI log.
//
// `errorDetail` is what every leg puts in `Result.Detail`, and the only place a
// CI reader ever sees WHY a fixture failed: `roundtrip_test.go`/
// `conformance_test.go` print one `FAILING [name] status detail` line per
// non-passing fixture and nothing else. The Go compiler's and encoder's own
// errors are MULTI-LINE by construction — a header plus one bullet per
// unsupported construct:
//
//	go→ball: 6 unsupported construct(s):
//	  - top-level var declaration is not supported (only functions and imports are encoded)
//	  - unsupported qualified call ballrt.RunEntry
//
// The predecessor of this function kept only the text before the first '\n',
// which dropped every bullet — i.e. the entire diagnosis — with no ellipsis and
// no hint that anything had been cut. The three sibling harnesses do not do
// that: Python joins the lines with " / " (python/engine/conformance/
// roundtrip.py) and C#/Rust truncate at 200 characters with a trailing "…"
// (csharp/engine/conformance/Fixtures.cs, rust/engine/tests/
// roundtrip_conformance.rs). Investigating issue #642 cost a local reproduction
// purely because the Go row's log was structurally less diagnosable than its
// three siblings.
func TestErrorDetailJoinsEveryLineOfAMultiLineError(t *testing.T) {
	in := "go→ball: 2 unsupported construct(s):\n" +
		"  - top-level var declaration is not supported\n" +
		"  - unsupported qualified call ballrt.RunEntry"

	got := errorDetail(in)

	if strings.Contains(got, "\n") {
		t.Fatalf("errorDetail must be one line (a FAILING line is one log line), got %q", got)
	}
	for _, want := range []string{
		"2 unsupported construct(s)",
		"top-level var declaration is not supported",
		"unsupported qualified call ballrt.RunEntry",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("errorDetail dropped %q from a multi-line error; got %q", want, got)
		}
	}
	if !strings.Contains(got, " / ") {
		t.Fatalf("errorDetail must join lines with %q (the separator python/engine/conformance/roundtrip.py uses), got %q", " / ", got)
	}
}

// A single-line error is passed through untouched: no separator, no ellipsis.
func TestErrorDetailLeavesASingleLineAlone(t *testing.T) {
	const in = "unsupported base function std_collections.list_foreach"
	if got := errorDetail(in); got != in {
		t.Fatalf("errorDetail rewrote a single-line error: got %q, want %q", got, in)
	}
}

// A pathological error (a 53-construct list) must not flood the log either: it
// is truncated at the same 200-character budget C# and Rust use, and the cut is
// VISIBLE — a trailing "…" — so a reader can never mistake a truncated detail
// for a complete one. That is the whole difference between this and dropping
// lines silently.
func TestErrorDetailTruncatesVisiblyAtTheSharedBudget(t *testing.T) {
	in := "header:\n" + strings.Repeat("  - a very long unsupported construct message\n", 20)

	got := errorDetail(in)

	if len([]rune(got)) > detailBudget+1 {
		t.Fatalf("errorDetail returned %d runes, want at most %d + the ellipsis", len([]rune(got)), detailBudget)
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("a truncated detail must end in an ellipsis so the cut is visible, got %q", got)
	}
	if !strings.HasPrefix(got, "header: / ") {
		t.Fatalf("truncation must keep the HEAD of the message (the header names the error), got %q", got)
	}
}

// Blank lines and trailing whitespace carry no information and would otherwise
// spend the budget: a "  \n" line must not become an empty " / " segment.
func TestErrorDetailDropsBlankSegments(t *testing.T) {
	got := errorDetail("first\n\n   \nsecond\n")
	if got != "first / second" {
		t.Fatalf("errorDetail(%q) = %q, want %q", "first\n\n   \nsecond\n", got, "first / second")
	}
}
