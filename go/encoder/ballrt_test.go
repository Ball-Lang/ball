package encoder_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ball-lang/ball/go/compiler"
	"github.com/ball-lang/ball/go/encoder"
)

// The encoder must be able to read back what `go/compiler` EMITS, not only
// idiomatic hand-written Go (issue #642). Before this, the compiler's own
// output tripped three refusals at once — the unconditional `ballOneof_*`
// top-level vars, the `ballrt.RunEntry` entry wrapper, and every `ballrt.*`
// base-call helper — so not one of the conformance fixtures could survive
// Ball → Go → Ball, and the `go-roundtrip` matrix row measured a flat 0 while
// reporting the harness healthy.
//
// The whole-corpus proof is that row (`go/engine/conformance/roundtrip.go`,
// floored and ratcheted in conformance-matrix.yml). This is the fast, in-module
// guard on the SHAPE, so a regression is a failing `go test ./encoder/...`
// rather than a matrix row nobody ran.

// compileFixture compiles a conformance fixture to Go source.
func compileFixture(t *testing.T, name string) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(root, "tests", "conformance", name+".ball.json")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("fixture %s not found: %v", name, err)
	}
	prog, err := compiler.LoadProgramFile(path)
	if err != nil {
		t.Fatalf("load %s: %v", name, err)
	}
	src, err := compiler.Compile(prog)
	if err != nil {
		t.Fatalf("compile %s: %v", name, err)
	}
	return src
}

// TestCompilerOutputHasNoDeadOneofTables pins the compiler half: a program that
// never references a oneof discriminator must emit none of their tables. They
// used to be emitted unconditionally — five dead top-level `var` blocks in every
// program, including a hello-world.
func TestCompilerOutputHasNoDeadOneofTables(t *testing.T) {
	src := compileFixture(t, "265_enc_hello")
	if strings.Contains(src, "ballOneof_") {
		t.Fatalf("compiled hello-world still emits an unreferenced oneof table:\n%s", src)
	}
}

// TestEncodeCompilerOutput is the encoder half: the compiler's own emission for
// a hello-world re-encodes cleanly, and the result is a runnable Program whose
// entry function carries the real body rather than a call to the wrapper.
func TestEncodeCompilerOutput(t *testing.T) {
	src := compileFixture(t, "265_enc_hello")

	prog, err := encoder.Encode(src)
	if err != nil {
		t.Fatalf("re-encoding the compiler's own output failed: %v\n--- source ---\n%s", err, src)
	}
	if prog.GetEntryFunction() != "main" {
		t.Fatalf("entry function = %q, want \"main\"", prog.GetEntryFunction())
	}

	var std *string
	for _, m := range prog.GetModules() {
		for _, f := range m.GetFunctions() {
			if m.GetName() == "std" && f.GetName() == "print" {
				name := f.GetName()
				std = &name
			}
		}
	}
	if std == nil {
		t.Fatalf("re-encoded program declares no std.print — ballrt.Print was not recognised:\n%v", prog)
	}

	// The `ballrt.RunEntry(func() ballrt.Value { … })` wrapper must be gone: an
	// encoded `main` that still CALLS it would be structurally valid and
	// silently unrunnable on any reference engine.
	for _, m := range prog.GetModules() {
		for _, f := range m.GetFunctions() {
			if f.GetName() == "main" && strings.Contains(f.String(), "RunEntry") {
				t.Fatalf("encoded main still references the entry wrapper: %s", f.String())
			}
		}
	}
}

// TestUnknownRuntimeHelperFailsLoud pins the fail-loud boundary (issue #55): a
// `ballrt.*` helper with no universal std inverse must be an error, never a
// silently dropped or guessed-at call.
func TestUnknownRuntimeHelperFailsLoud(t *testing.T) {
	const src = `package main

import ballrt "github.com/ball-lang/ball/go/runtime"

func main() {
	ballrt.RunEntry(func() ballrt.Value {
		return ballrt.SomeHelperThatDoesNotExist(1)
	})
}
`
	if _, err := encoder.Encode(src); err == nil {
		t.Fatal("expected an error for an unmapped ballrt helper, got none")
	} else if !strings.Contains(err.Error(), "unsupported runtime helper") {
		t.Fatalf("expected an 'unsupported runtime helper' error, got: %v", err)
	}
}

// TestRuntimeHelperArityIsChecked pins the other half of the same boundary: a
// mapped helper called with the wrong number of arguments must fail rather than
// encode a base call with missing input fields.
func TestRuntimeHelperArityIsChecked(t *testing.T) {
	const src = `package main

import ballrt "github.com/ball-lang/ball/go/runtime"

func main() {
	ballrt.RunEntry(func() ballrt.Value {
		return ballrt.Add(1)
	})
}
`
	if _, err := encoder.Encode(src); err == nil {
		t.Fatal("expected an arity error for ballrt.Add with one argument, got none")
	} else if !strings.Contains(err.Error(), "expects 2 argument(s)") {
		t.Fatalf("expected an arity error, got: %v", err)
	}
}
