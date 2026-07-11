package compiler_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ball-lang/ball/go/compiler"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// load reads and decodes a .ball.json fixture, failing the test on error.
func load(t *testing.T, path string) *ballv1.Program {
	t.Helper()
	prog, err := compiler.LoadProgramFile(path)
	if err != nil {
		t.Fatalf("load %s: %v", path, err)
	}
	return prog
}

// compileFmt compiles a program to formatted Go, failing on a compile or format
// error (a format error means the emitted Go is not valid — a compiler bug).
func compileFmt(t *testing.T, prog *ballv1.Program) string {
	t.Helper()
	src, err := compiler.Compile(prog)
	if err != nil {
		t.Fatalf("compile: %v\n---\n%s", err, src)
	}
	out, ferr := compiler.Format(src)
	if ferr != nil {
		t.Fatalf("%v\n--- raw source ---\n%s", ferr, src)
	}
	return out
}

// runtimeDir resolves the absolute path of the go/runtime module (a sibling of
// go/compiler), for the temp module's replace directive.
func runtimeDir(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs(filepath.Join("..", "runtime"))
	if err != nil {
		t.Fatalf("resolve runtime dir: %v", err)
	}
	return abs
}

// goRun writes goSrc into a throwaway module that replaces the Ball runtime with
// the local go/runtime, then `go run`s it and returns stdout. Because
// go/runtime has zero external dependencies (and is wired via a local replace),
// this needs no network and no go.sum.
func goRun(t *testing.T, goSrc string) string {
	t.Helper()
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go toolchain not on PATH")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte(goSrc), 0o644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}
	gomod := "module ballgorun\n\ngo 1.23\n\n" +
		"require github.com/ball-lang/ball/go/runtime v0.0.0\n\n" +
		"replace github.com/ball-lang/ball/go/runtime => " + runtimeDir(t) + "\n"
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte(gomod), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}

	cmd := exec.Command("go", "run", ".")
	cmd.Dir = dir
	// Disable any enclosing workspace so the temp module resolves standalone.
	cmd.Env = append(os.Environ(), "GOWORK=off", "GOFLAGS=")
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("go run failed: %v\nstderr:\n%s\nsource:\n%s", err, stderr.String(), goSrc)
	}
	return stdout.String()
}

// ── Unit-level emission checks ───────────────────────────────────────────────

func TestHelloWorldEmitsPrint(t *testing.T) {
	prog := load(t, filepath.Join("..", "..", "examples", "hello_world", "hello_world.ball.json"))
	src := compileFmt(t, prog)
	for _, want := range []string{"package main", "ballrt.Print(", `"Hello, World!"`, "func main()"} {
		if !strings.Contains(src, want) {
			t.Errorf("emitted Go missing %q\n---\n%s", want, src)
		}
	}
}

func TestFibonacciEmitsRecursionAndControlFlow(t *testing.T) {
	prog := load(t, filepath.Join("..", "..", "examples", "fibonacci", "fibonacci.ball.json"))
	src := compileFmt(t, prog)
	for _, want := range []string{
		"func fibonacci(input ballrt.Value)", // user function
		"ballrt.Return(",                     // std.return → flow signal
		"ballrt.Lte(",                        // comparison
		"ballrt.Add(",                        // arithmetic
		"if ballrt.Truthy(",                  // lazy native if
	} {
		if !strings.Contains(src, want) {
			t.Errorf("emitted Go missing %q\n---\n%s", want, src)
		}
	}
}

// ── End-to-end: compile + go run + assert stdout ─────────────────────────────

func TestEndToEnd(t *testing.T) {
	cases := []struct {
		name string
		path string
		want string
	}{
		{"hello_world", filepath.Join("..", "..", "examples", "hello_world", "hello_world.ball.json"), "Hello, World!\n"},
		{"fibonacci", filepath.Join("..", "..", "examples", "fibonacci", "fibonacci.ball.json"), "55\n"},
		{"while_sum", filepath.Join("testdata", "while_sum.ball.json"), "15\n"},
		{"for_in_list", filepath.Join("testdata", "for_in_list.ball.json"), "10\n20\n30\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			prog := load(t, tc.path)
			src := compileFmt(t, prog)
			got := goRun(t, src)
			if got != tc.want {
				t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
			}
		})
	}
}

func TestUnsupportedBaseFunctionFailsLoud(t *testing.T) {
	// A program that calls a base function the compiler does not implement must
	// produce a compile error (issue #55 fail-loud doctrine), not silent bad Go.
	prog := &ballv1.Program{
		Name:          "bad",
		Version:       "1.0.0",
		EntryModule:   "main",
		EntryFunction: "main",
		Modules: []*ballv1.Module{
			{
				Name: "std",
				Functions: []*ballv1.FunctionDefinition{
					{Name: "quantum_entangle", IsBase: true},
				},
			},
			{
				Name: "main",
				Functions: []*ballv1.FunctionDefinition{
					{
						Name: "main",
						Body: &ballv1.Expression{Expr: &ballv1.Expression_Call{Call: &ballv1.FunctionCall{
							Module:   "std",
							Function: "quantum_entangle",
						}}},
					},
				},
			},
		},
	}
	if _, err := compiler.Compile(prog); err == nil {
		t.Fatal("expected a fail-loud compile error for an unsupported base function, got nil")
	}
}
