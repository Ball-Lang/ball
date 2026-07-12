package cli

import (
	"strings"
	"testing"
)

func TestHelpExitsZero(t *testing.T) {
	for _, arg := range []string{"-h", "--help", "help"} {
		stdout, _, code := runCLI(arg)
		if code != 0 {
			t.Errorf("%s: exit = %d, want 0", arg, code)
		}
		if !strings.Contains(stdout, "ball <command>") {
			t.Errorf("%s: usage not printed to stdout: %q", arg, stdout)
		}
	}
}

func TestNoArgsIsUsageError(t *testing.T) {
	stdout, stderr, code := runCLI()
	if code != 2 {
		t.Errorf("exit = %d, want 2", code)
	}
	if stdout != "" {
		t.Errorf("no-arg run wrote to stdout: %q", stdout)
	}
	if !strings.Contains(stderr, "Usage:") {
		t.Errorf("usage not printed to stderr: %q", stderr)
	}
}

func TestUnknownCommandIsUsageError(t *testing.T) {
	_, stderr, code := runCLI("frobnicate")
	if code != 2 {
		t.Errorf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr, `unknown command "frobnicate"`) {
		t.Errorf("stderr = %q, want unknown-command message", stderr)
	}
}

func TestMissingFileIsIOError(t *testing.T) {
	// Each program-consuming verb maps a missing input to exit 3.
	for _, verb := range []string{"run", "compile", "check"} {
		_, stderr, code := runCLI(verb, "definitely_not_a_real_path.ball.json")
		if code != 3 {
			t.Errorf("%s missing file: exit = %d, want 3 (stderr=%q)", verb, code, stderr)
		}
		if !strings.Contains(stderr, "could not read") {
			t.Errorf("%s missing file: stderr = %q, want 'could not read'", verb, stderr)
		}
	}
	// encode reads a Go source path — same I/O contract.
	_, stderr, code := runCLI("encode", "definitely_not_a_real_path.go")
	if code != 3 {
		t.Errorf("encode missing file: exit = %d, want 3 (stderr=%q)", code, stderr)
	}
}

func TestBadFlagIsUsageError(t *testing.T) {
	_, stderr, code := runCLI("compile", "--nope", "x.ball.json")
	if code != 2 {
		t.Errorf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr, "not defined") {
		t.Errorf("stderr = %q, want flag-not-defined message", stderr)
	}
}
