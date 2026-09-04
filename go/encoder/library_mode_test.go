// Library-mode encoding (issue #537): Go source with **no `func main()`** — the
// shape every real Go library file has — encoded through
// [encoder.EncodeLibrary] and then compiled back into a real Go **library
// package** via `go/compiler`'s CompileLibrary.
//
// # Why this is a round-trip proof, not a shape assertion
//
// roundtrip_test.go proves the `func main` path by compiling the encoded
// Program and *running* it. A library has nothing to run — its whole contract
// is "this is a valid package other code can call into" — so the equivalent
// proof here is that `go build` accepts the compiled output as a library
// package (the same throwaway-module harness roundtrip_test.go uses, minus the
// execution step). A Program whose functions encoded to a broken tree would
// fail to build, exactly as it would there.
//
// # The deliberate boundary
//
// A library-mode Program carries `entry_module = "main"` (so CompileLibrary can
// find the module whose functions it emits at package scope) but an **empty
// `entry_function`**. That makes it structurally legal
// (`Program.entry_function` is an unconstrained proto3 string) and deliberately
// **not runnable**: `ball check` reports "missing entry_function" and `ball
// run` has nothing to call. That is the documented contract, mirroring the Rust
// encoder's `encode_library` and the C# encoder's `EncodeLibrary` exactly —
// never paper over it by synthesising a fake entry function.
package encoder_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ball-lang/ball/go/compiler"
	"github.com/ball-lang/ball/go/encoder"
)

// A library-shaped Go file: no `func main()`, several top-level functions, and
// enough surface (arithmetic, control flow, a same-file user call, string
// returns) that the `std` base-function accumulation has real work to do.
const librarySource = `package demo

func double(n int) int {
	return n * 2
}

func sumEvens(limit int) int {
	total := 0
	for i := 1; i <= limit; i++ {
		if i%2 == 0 {
			total += double(i)
		}
	}
	return total
}

func describe(n int) string {
	if n > 0 {
		return "positive"
	}
	return "non-positive"
}
`

// goBuildLibrary writes goSrc into a throwaway module that replaces the Ball
// runtime with the local go/runtime (a sibling of go/encoder, zero external
// deps, so no network or go.sum) and `go build`s it as a LIBRARY package. The
// `selfhost` build tag is required because CompileLibrary stamps a
// `//go:build selfhost` constraint onto every library it emits.
func goBuildLibrary(t *testing.T, goSrc string) {
	t.Helper()
	requireGo(t)
	abs, err := filepath.Abs(filepath.Join("..", "runtime"))
	if err != nil {
		t.Fatalf("resolve runtime dir: %v", err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "lib.go"), []byte(goSrc), 0o644); err != nil {
		t.Fatalf("write lib.go: %v", err)
	}
	gomod := "module ballencoderlib\n\ngo 1.23\n\n" +
		"require github.com/ball-lang/ball/go/runtime v0.0.0\n\n" +
		"replace github.com/ball-lang/ball/go/runtime => " + abs + "\n"
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte(gomod), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}

	cmd := exec.Command("go", "build", "-tags", "selfhost", ".")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GOWORK=off", "GOFLAGS=")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("go build (library) failed: %v\nstderr:\n%s\nsource:\n%s", err, stderr.String(), goSrc)
	}
}

func TestEncodeLibraryEncodesWithoutMainAndCompilesAsAGoLibrary(t *testing.T) {
	prog, err := encoder.EncodeLibrary(librarySource)
	if err != nil {
		t.Fatalf("EncodeLibrary returned an error: %v", err)
	}
	if prog == nil {
		t.Fatal("EncodeLibrary returned a nil Program")
	}

	// ── The deliberate non-runnable boundary ────────────────────────────────
	if got := prog.GetEntryFunction(); got != "" {
		t.Errorf("entry_function = %q, want \"\" (library mode is non-runnable by design; "+
			"never synthesize a fake entry function)", got)
	}
	if got := prog.GetEntryModule(); got != "main" {
		t.Errorf("entry_module = %q, want \"main\" (the module CompileLibrary emits)", got)
	}

	// ── Every top-level function is encoded, and none is synthesized ────────
	mainModule := findModule(prog, "main")
	if mainModule == nil {
		t.Fatal("library mode must still emit the `main` module")
	}
	var names []string
	for _, f := range mainModule.GetFunctions() {
		names = append(names, f.GetName())
		if f.GetBody() == nil {
			t.Errorf("encoded library function %q carries no body", f.GetName())
		}
	}
	want := []string{"double", "sumEvens", "describe"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("encoded functions = %v, want %v (no synthesized entry function)", names, want)
	}

	// ── Std accumulation ran, exactly as Encode's does ──────────────────────
	stdModule := findModule(prog, "std")
	if stdModule == nil {
		t.Fatal("library mode must attach the `std` base module")
	}
	if len(stdModule.GetFunctions()) == 0 {
		t.Error("`std` must declare the base functions the library actually calls")
	}
	for _, f := range stdModule.GetFunctions() {
		if !f.GetIsBase() {
			t.Errorf("std.%s must be declared as a base function", f.GetName())
		}
	}

	// ── The real round trip: it builds as a Go library package ──────────────
	compiled, cerr := compiler.CompileLibrary(prog, "ballstudy")
	if cerr != nil {
		t.Fatalf("CompileLibrary: %v", cerr)
	}
	if strings.Contains(compiled, "func main()") {
		t.Fatalf("CompileLibrary must not emit an entry point:\n%s", compiled)
	}
	goBuildLibrary(t, compiled)
}

// The default contract is unchanged — library mode is strictly opt-in.
func TestDefaultEncodeStillRequiresFuncMain(t *testing.T) {
	_, err := encoder.Encode(librarySource)
	if err == nil {
		t.Fatal("Encode must still reject an entry-point-less file")
	}
	if !strings.Contains(err.Error(), "a Ball Program requires a `func main()` entry point") {
		t.Errorf("Encode error = %q, want the missing-entry-point message", err)
	}
}
