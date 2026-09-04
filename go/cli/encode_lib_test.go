package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A library-shaped Go file: no `func main()`, the shape every real Go library
// file has and the one `ball encode` rejected outright before issue #537.
const libFixtureSource = `package demo

func double(n int) int {
	return n * 2
}

func triple(n int) int {
	return n * 3
}
`

func writeLibFixture(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "lib.go")
	if err := os.WriteFile(path, []byte(libFixtureSource), 0o644); err != nil {
		t.Fatalf("write lib fixture: %v", err)
	}
	return path
}

// `ball encode -lib` accepts an entry-point-less file; the SAME file without
// -lib still exits 2 with the missing-entry-point message. Mirrors the Rust
// CLI's encode_lib_flag_allows_missing_main / missing_fn_main_exits_2 pair.
func TestEncodeLibFlagAllowsMissingMain(t *testing.T) {
	src := writeLibFixture(t)

	stdout, stderr, code := runCLI("encode", "-lib", src)
	if code != 0 {
		t.Fatalf("encode -lib exit = %d, want 0 (stderr=%q)", code, stderr)
	}
	if !strings.Contains(stdout, `"@type": "type.googleapis.com/ball.v1.Program"`) {
		t.Fatalf("encode -lib output is not an @type-enveloped Program:\n%s", stdout)
	}

	var parsed map[string]any
	if err := json.Unmarshal([]byte(stdout), &parsed); err != nil {
		t.Fatalf("encode -lib output is not valid JSON: %v\n%s", err, stdout)
	}
	// entryModule still names the module CompileLibrary emits; entryFunction is
	// deliberately empty (proto3 JSON omits an empty string entirely), so the
	// program is non-runnable by design — never a synthesized entry function.
	if got := parsed["entryModule"]; got != "main" {
		t.Errorf("entryModule = %v, want \"main\"", got)
	}
	if got, ok := parsed["entryFunction"]; ok && got != "" {
		t.Errorf("entryFunction = %v, want absent or empty (library mode is non-runnable)", got)
	}

	// The default path is unchanged: the same file WITHOUT -lib is still
	// rejected, so library mode is strictly opt-in.
	_, stderr, code = runCLI("encode", src)
	if code != 2 {
		t.Fatalf("encode (no -lib) exit = %d, want 2 (stderr=%q)", code, stderr)
	}
	if !strings.Contains(stderr, "a Ball Program requires a `func main()` entry point") {
		t.Errorf("stderr = %q, want the missing-entry-point message", stderr)
	}
}

// The documented boundary: a library-mode program has no entry function, so
// `ball check` must refuse it rather than any code path silently synthesising a
// fake entry point. Mirrors Rust's
// a_library_mode_program_is_rejected_by_check_as_non_runnable.
func TestLibraryModeProgramIsRejectedByCheckAsNonRunnable(t *testing.T) {
	src := writeLibFixture(t)
	out := filepath.Join(t.TempDir(), "lib.ball.json")

	if _, stderr, code := runCLI("encode", "-lib", src, "-o", out); code != 0 {
		t.Fatalf("encode -lib exit = %d, want 0 (stderr=%q)", code, stderr)
	}

	stdout, stderr, code := runCLI("check", out)
	if code != 2 {
		t.Fatalf("check on a library-mode program exit = %d, want 2 (stdout=%q)", code, stdout)
	}
	if !strings.Contains(stderr, "missing entry_function") {
		t.Errorf("stderr = %q, want \"missing entry_function\"", stderr)
	}
}
