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

// The round-trip is the encoder's proof of correctness (the CLAUDE.md bar): for
// each authored Go source we (1) run it natively, then (2) encode Go → Ball,
// compile the Ball back to Go with the Phase-2 compiler, run that, and assert
// the compiled-Ball output equals both the native Go output and a fixed golden.
// This is Go → Ball → (compile + run) ≡ native Go, end to end — a behavioral
// assertion, not "it produced a Program".

func TestRoundTrip(t *testing.T) {
	requireGo(t)
	cases := []struct {
		name string
		file string
		want string
	}{
		{"hello_world", "hello_world.go", "Hello, World!\n"},
		{"arithmetic", "arithmetic.go", "18\n"},
		{"control_flow", "control_flow.go", "6\n"},
		{"list_loop", "list_loop.go", "10\n20\n30\n60\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			src := readSource(t, tc.file)

			// (1) Native Go — establishes the reference behavior and confirms
			// the golden matches an actual Go run.
			native := goRun(t, src, false)
			if native != tc.want {
				t.Fatalf("native Go output %q != golden %q", native, tc.want)
			}

			// (2) Go → Ball.
			prog, err := encoder.Encode(src)
			if err != nil {
				t.Fatalf("encode: %v", err)
			}

			// Ball → Go (Phase-2 compiler) → run.
			goSrc, err := compiler.Compile(prog)
			if err != nil {
				t.Fatalf("compile encoded Ball: %v\n---\n%s", err, goSrc)
			}
			if formatted, ferr := compiler.Format(goSrc); ferr == nil {
				goSrc = formatted
			}
			roundTripped := goRun(t, goSrc, true)

			if roundTripped != native {
				t.Errorf("round-trip mismatch:\n native: %q\n ball:   %q\n--- compiled Go ---\n%s",
					native, roundTripped, goSrc)
			}
		})
	}
}

// requireGo skips the suite when the Go toolchain isn't on PATH (matching the
// compiler's own end-to-end tests).
func requireGo(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go toolchain not on PATH")
	}
}

func readSource(t *testing.T, file string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", file))
	if err != nil {
		t.Fatalf("read %s: %v", file, err)
	}
	return string(data)
}

// goRun writes goSrc into a throwaway module and `go run`s it, returning stdout.
// When needsRuntime is set (compiled Ball output), the module replaces the Ball
// Go runtime with the local go/runtime (a sibling, dependency-free, so this
// needs no network); native Go sources need only the standard library.
func goRun(t *testing.T, goSrc string, needsRuntime bool) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte(goSrc), 0o644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}
	gomod := "module ballgorun\n\ngo 1.23\n"
	if needsRuntime {
		abs, err := filepath.Abs(filepath.Join("..", "runtime"))
		if err != nil {
			t.Fatalf("resolve runtime dir: %v", err)
		}
		gomod += "\nrequire github.com/ball-lang/ball/go/runtime v0.0.0\n\n" +
			"replace github.com/ball-lang/ball/go/runtime => " + abs + "\n"
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte(gomod), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}

	cmd := exec.Command("go", "run", ".")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GOWORK=off", "GOFLAGS=")
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("go run failed: %v\nstderr:\n%s\nsource:\n%s", err, stderr.String(), goSrc)
	}
	return stdout.String()
}
