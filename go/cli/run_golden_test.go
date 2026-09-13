package cli

import (
	"os"
	"strings"
	"testing"
)

// `run` executes programs for real via the self-hosted engine in EVERY build
// (go/engine/compiled/compiled_engine.go is tracked since #586). These cases
// drive whole conformance fixtures through the built CLI and compare stdout to
// the fixtures' committed goldens — the CLI-level analog of go/engine's
// conformance sweep, and the in-repo half of the assertion
// tools/go-module-proxy/smoke.sh makes against a `go install`-ed binary.
func TestRunSelfHostMatchesGolden(t *testing.T) {
	cases := []struct{ name, golden string }{
		{"265_enc_hello", "265_enc_hello.expected_output.txt"},
		{"31_arithmetic_basic", "31_arithmetic_basic.expected_output.txt"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			prog := fixture(t, "tests", "conformance", tc.name+".ball.json")
			goldenPath := fixture(t, "tests", "conformance", tc.golden)
			goldenBytes, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden: %v", err)
			}

			stdout, stderr, code := runCLI("run", prog)
			if code != 0 {
				t.Fatalf("run exit = %d, want 0 (stderr=%q)", code, stderr)
			}
			if got, want := normalize(stdout), normalize(string(goldenBytes)); got != want {
				t.Errorf("output mismatch\n got: %q\nwant: %q", got, want)
			}
		})
	}
}

// normalize matches go/engine's conformance runner: strip CR and trailing
// newlines so a CRLF golden compares equal to the CLI's LF stdout.
func normalize(s string) string {
	return strings.TrimRight(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
}
