package compiler_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// std_collections.list_foreach had NO case in the Go compiler's base-call table,
// so every program that iterates a collection with it was REFUSED outright:
//
//	ball→go: 1 unsupported construct(s):
//	  - unsupported base function std_collections.list_foreach
//
// Safe (fail-loud, never silent bad code) but a real gap: the Dart compiler has
// emitted `<list>.forEach(<callback>)` for it since day one
// (dart/compiler/lib/compiler.dart), every self-hosted engine executes it, and
// three fixtures in the corpus use it — 116_map_iteration, 119_nested_maps and
// 121_map_from_entries. Those three could not be compiled to Go at all, which is
// why they showed up as `compile-error ball→go` (not `encode-error`) in the
// go-roundtrip measurement leg while investigating issue #642.
//
// No CI leg compiles a conformance fixture to Go — go/engine/conformance runs the
// self-hosted ENGINE, and roundtrip.go re-encodes and runs on DART — so this
// test is what holds the compiler's route to these fixtures. It is the sibling
// of TestListFindNoMatchContract (issue #597), which closed the same shape of
// gap for list_find.
func TestListForeachCompilesAndRuns(t *testing.T) {
	for _, fixture := range []string{
		"116_map_iteration",
		"119_nested_maps",
		"121_map_from_entries",
	} {
		t.Run(fixture, func(t *testing.T) {
			base := filepath.Join("..", "..", "tests", "conformance", fixture)
			prog := load(t, base+".ball.json")
			src := compileFmt(t, prog)

			if !strings.Contains(src, "ballrt.ListForEach(") {
				t.Errorf("emitted Go missing ballrt.ListForEach(\n---\n%s", src)
			}

			// Read the golden as BYTES and normalize only CRLF: a text-mode read
			// would collapse a semantic lone \r and silently corrupt the
			// comparison (both directions — see .claude/rules/python.md's
			// golden-bytes note, which applies to every harness).
			wantBytes, err := os.ReadFile(base + ".expected_output.txt")
			if err != nil {
				t.Fatalf("read golden: %v", err)
			}
			want := strings.ReplaceAll(string(wantBytes), "\r\n", "\n")

			if got := goRun(t, src); got != want {
				t.Errorf("%s:\n got %q\nwant %q", fixture, got, want)
			}
		})
	}
}
