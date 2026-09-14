package compiler_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestUserThrownBuiltinErrorContract compiles the conformance fixture that pins
// what a USER-THROWN built-in Dart error reads as (issue #658) and RUNS it,
// diffing the committed golden byte-for-byte.
//
// The defect this closes is the one a correct rendering table cannot save you
// from. `ops.go`'s `dartErrorToString` reads the `message` field — but a literal
// `throw StateError('boom')` arrives as a `messageCreation` whose ctor argument
// the encoder keys `arg0` (a built-in Dart error carries no `TypeDefinition`, so
// `constructorParamNames` has nothing to resolve against), and the compiler
// emitted `ballrt.NewMessage("main:StateError", {arg0: "boom"})`. The table
// MISSED, `ToStr` fell through to the type tag, and the program printed
// `untyped state: main:StateError` where Dart prints `Bad state: boom`.
//
// Same reason `type_error_contract_test.go` and `state_error_contract_test.go`
// exist: no CI leg compiles a conformance fixture to Go (go/engine/conformance
// runs the self-hosted ENGINE, and roundtrip.go re-encodes and runs on DART), so
// without this the compiler's own route stays unexercised by the corpus.
func TestUserThrownBuiltinErrorContract(t *testing.T) {
	fixture := filepath.Join("..", "..", "tests", "conformance", "473_caught_user_thrown_builtin_error.ball.json")
	golden := filepath.Join("..", "..", "tests", "conformance", "473_caught_user_thrown_builtin_error.expected_output.txt")

	prog := load(t, fixture)
	src := compileFmt(t, prog)

	// The ctor argument has to land under `message` — the key the rendering
	// table reads AND the key a `e.message` field access compiles to. Asserting
	// the emitted source, not just the run, names the defect directly: a run
	// diff alone would say "wrong string" without saying which half is wrong.
	if strings.Contains(src, `__m.Set("arg0"`) {
		t.Errorf("a built-in Dart error kept its arg0 key:\n---\n%s", src)
	}

	// Read the golden as BYTES and normalize only CRLF: a text-mode read would
	// collapse a semantic lone \r and silently corrupt the comparison.
	wantBytes, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	want := strings.ReplaceAll(string(wantBytes), "\r\n", "\n")

	if got := goRun(t, src); got != want {
		t.Errorf("caught user-thrown built-in error observable:\n got %q\nwant %q", got, want)
	}
}
