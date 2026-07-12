package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCompileHelloWorldToStdout(t *testing.T) {
	prog := fixture(t, "examples", "hello_world", "hello_world.ball.json")
	stdout, stderr, code := runCLI("compile", prog)
	if code != 0 {
		t.Fatalf("exit = %d, want 0 (stderr=%q)", code, stderr)
	}
	if !strings.Contains(stdout, "package main") {
		t.Errorf("emitted Go missing 'package main':\n%s", stdout)
	}
	if !strings.Contains(stdout, "ballrt") {
		t.Errorf("emitted Go missing the ballrt runtime import:\n%s", stdout)
	}
	if !strings.Contains(stdout, "func main()") {
		t.Errorf("emitted Go missing func main():\n%s", stdout)
	}
}

func TestCompileWritesOutputFile(t *testing.T) {
	prog := fixture(t, "examples", "hello_world", "hello_world.ball.json")
	out := filepath.Join(t.TempDir(), "hello.go")
	stdout, stderr, code := runCLI("compile", prog, "-o", out)
	if code != 0 {
		t.Fatalf("exit = %d, want 0 (stderr=%q)", code, stderr)
	}
	if stdout != "" {
		t.Errorf("compile -o wrote to stdout: %q", stdout)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("output file not written: %v", err)
	}
	if !strings.Contains(string(data), "package main") {
		t.Errorf("output file missing 'package main':\n%s", data)
	}
}

// The compiled Go must actually build with the real toolchain — a compile that
// emits syntactically valid but uncompilable Go would be a silent half-success.
func TestCompiledHelloWorldBuildsAndRuns(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping go-build round trip in -short mode")
	}
	prog := fixture(t, "examples", "hello_world", "hello_world.ball.json")
	stdout, stderr, code := runCLI("compile", prog)
	if code != 0 {
		t.Fatalf("compile exit = %d (stderr=%q)", code, stderr)
	}
	out := goRunSource(t, stdout)
	if !strings.Contains(out, "Hello, World!") {
		t.Errorf("compiled program output = %q, want it to contain 'Hello, World!'", out)
	}
}
