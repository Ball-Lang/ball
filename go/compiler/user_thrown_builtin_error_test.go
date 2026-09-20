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
// TWO mechanisms have to line up for this to read like Dart, and the corpus
// exercised neither on the literal-throw path:
//
//   - The KEY. `ops.go`'s `dartErrorToString` reads the `message` field, while
//     the encoder keys a built-in error's ctor argument `arg0` (it carries no
//     `TypeDefinition`, so `constructorParamNames` has nothing to resolve
//     against) and the compiler emits it verbatim. Go closes that in
//     `ballrt.Throw` — `normalizeThrown` aliases `arg0` to `message` at throw
//     time (issue #615) — NOT in the compiler, so the assertion below is that
//     the compiled throw actually goes through that alias point.
//   - The TABLE. Even with the right key, `ArgumentError` had no entry, so
//     `ToStr` fell through to the type tag and the program printed
//     `untyped argument: main:ArgumentError` where Dart prints
//     `Invalid argument(s): nope`.
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

	// A literal throw must reach `ballrt.Throw`, the single place the positional
	// ctor argument becomes `.message`. Emitting a raw panic, or constructing the
	// value without throwing it through that path, would leave the field keyed
	// `arg0`: the rendering table would miss and `e.message` would read null.
	if !strings.Contains(src, "ballrt.Throw(") {
		t.Errorf("emitted Go missing ballrt.Throw(\n---\n%s", src)
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
