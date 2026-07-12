package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEncodeGoSourceToJSON(t *testing.T) {
	src := fixture(t, "go", "encoder", "testdata", "hello_world.go")
	stdout, stderr, code := runCLI("encode", src)
	if code != 0 {
		t.Fatalf("exit = %d, want 0 (stderr=%q)", code, stderr)
	}
	for _, want := range []string{
		`"@type": "type.googleapis.com/ball.v1.Program"`,
		"ball.v1.Program",
		`"print"`,       // the std.print base function the encoder emits
		"Hello, World!", // the string literal preserved from the source
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("encoded JSON missing %q:\n%s", want, stdout)
		}
	}
}

func TestEncodeUnknownFormatIsUsageError(t *testing.T) {
	src := fixture(t, "go", "encoder", "testdata", "hello_world.go")
	_, stderr, code := runCLI("encode", src, "-format", "yaml")
	if code != 2 {
		t.Errorf("exit = %d, want 2 (stderr=%q)", code, stderr)
	}
	if !strings.Contains(stderr, "unknown -format") {
		t.Errorf("stderr = %q, want unknown-format message", stderr)
	}
}

// encode --format binary must produce the Any-wrapped canonical form that
// check/compile read back — proving the two directions agree.
func TestEncodeBinaryRoundTripsThroughCheck(t *testing.T) {
	src := fixture(t, "go", "encoder", "testdata", "hello_world.go")
	bin := filepath.Join(t.TempDir(), "hw.ball.bin")
	if _, stderr, code := runCLI("encode", src, "-format", "binary", "-o", bin); code != 0 {
		t.Fatalf("encode -format binary exit = %d (stderr=%q)", code, stderr)
	}
	if _, err := os.Stat(bin); err != nil {
		t.Fatalf("binary output not written: %v", err)
	}
	stdout, stderr, code := runCLI("check", bin)
	if code != 0 {
		t.Fatalf("check on encoded .bin exit = %d (stderr=%q)", code, stderr)
	}
	if !strings.Contains(stdout, "Valid:") {
		t.Errorf("check summary missing 'Valid:':\n%s", stdout)
	}
}

// The full pipeline: Go source → Ball (encode) → Go (compile) → build+run must
// reproduce the original program's output.
func TestEncodeThenCompileRoundTrip(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping go-build round trip in -short mode")
	}
	src := fixture(t, "go", "encoder", "testdata", "hello_world.go")
	jsonOut := filepath.Join(t.TempDir(), "hw.ball.json")
	if _, stderr, code := runCLI("encode", src, "-o", jsonOut); code != 0 {
		t.Fatalf("encode exit = %d (stderr=%q)", code, stderr)
	}
	compiled, stderr, code := runCLI("compile", jsonOut)
	if code != 0 {
		t.Fatalf("compile exit = %d (stderr=%q)", code, stderr)
	}
	out := goRunSource(t, compiled)
	if !strings.Contains(out, "Hello, World!") {
		t.Errorf("round-trip output = %q, want 'Hello, World!'", out)
	}
}
