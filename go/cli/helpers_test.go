package cli

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// runCLI invokes Run in-process with the given args, capturing stdout and stderr
// and returning them alongside the exit code. This exercises the whole dispatch
// without spawning a subprocess.
func runCLI(args ...string) (stdout, stderr string, code int) {
	var out, errBuf bytes.Buffer
	code = Run(args, &out, &errBuf)
	return out.String(), errBuf.String(), code
}

// repoRoot walks up from the test's working directory (go/cli) to the repo root,
// identified by proto/ball/v1/ball.proto — the same anchor the engine's regen
// tool uses. Fails the test if the marker is not found.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "proto", "ball", "v1", "ball.proto")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("repo root (proto/ball/v1/ball.proto) not found above %s", dir)
		}
		dir = parent
	}
}

// fixture resolves a path relative to the repo root, failing the test if it does
// not exist.
func fixture(t *testing.T, rel ...string) string {
	t.Helper()
	path := filepath.Join(append([]string{repoRoot(t)}, rel...)...)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("fixture %s missing: %v", path, err)
	}
	return path
}

// goRunSource writes goSrc into a throwaway module that replaces the Ball
// runtime with the local go/runtime (a sibling of go/cli, zero external deps, so
// no network or go.sum), then `go run`s it and returns stdout. Mirrors
// go/compiler/compiler_test.go's goRun — the real-toolchain proof that `ball
// compile`'s output actually builds and runs.
func goRunSource(t *testing.T, goSrc string) string {
	t.Helper()
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go toolchain not on PATH")
	}
	runtimeDir, err := filepath.Abs(filepath.Join("..", "runtime"))
	if err != nil {
		t.Fatalf("resolve runtime dir: %v", err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte(goSrc), 0o644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}
	gomod := "module ballclirun\n\ngo 1.23\n\n" +
		"require github.com/ball-lang/ball/go/runtime v0.0.0\n\n" +
		"replace github.com/ball-lang/ball/go/runtime => " + runtimeDir + "\n"
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

// writeProgramJSON marshals prog to a temp .ball.json (via the CLI's own
// programToJSON, so tests share the exact serialization the `encode` verb emits)
// and returns its path.
func writeProgramJSON(t *testing.T, prog *ballv1.Program) string {
	t.Helper()
	data, cerr := programToJSON(prog)
	if cerr != nil {
		t.Fatalf("programToJSON: %v", cerr)
	}
	path := filepath.Join(t.TempDir(), "program.ball.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write program json: %v", err)
	}
	return path
}
