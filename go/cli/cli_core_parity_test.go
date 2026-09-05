//go:build clicore

package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	compiled "github.com/ball-lang/ball/go/cli/compiled"
)

// The `ball info`/`validate`/`tree`/`version` golden-parity gate (issue #570) —
// the Go sibling of dart/cli/test/cli_core_parity_test.dart,
// rust/cli/tests/cli_core_parity.rs and ts/cli/test/cli_core_parity.test.ts.
//
// The Dart parity test can compare Dart-native cli_core against the SAME
// process's Ball-engine-run cli.ball.json output. Go has no such live
// comparison at `go test` time: cli_core is AOT-compiled into
// compiled/compiled_cli.go by `go run ./cmd/regen`, and shelling out to a Dart
// toolchain on every `go test` would make this suite toolchain-dependent for no
// benefit. So this gate compares the CLI's own stdout against the golden files
// generated once from the Dart CLI and checked into tests/cli_core_goldens/
// (see that directory's README.md for regeneration) — proving the compiled Go
// report functions produce byte-identical text to the reference implementation.
//
// Runs only under `-tags clicore`; the default build's half of the contract
// (honest exit-1 degradation) is cli_core_default_test.go.

// goldenFixtures is the same varied slice every other target's parity gate uses.
var goldenFixtures = []string{
	"100_complex_control_flow",
	"101_simple_class",
	"111_cascade_operator",
	"116_map_iteration",
	"118_set_operations",
}

// goldenVerbs are the program-taking cli-core verbs. `version` takes no program
// and is checked separately below, exactly as the Rust and Dart gates do.
var goldenVerbs = []string{"info", "validate", "tree"}

func TestCliCoreVerbsMatchDartGoldens(t *testing.T) {
	root := repoRoot(t)
	compared := 0
	for _, fx := range goldenFixtures {
		program := fixture(t, "tests", "conformance", fx+".ball.json")
		for _, verb := range goldenVerbs {
			t.Run(fx+"/"+verb, func(t *testing.T) {
				goldenPath := filepath.Join(root, "tests", "cli_core_goldens", fx+"."+verb+".txt")
				goldenBytes, err := os.ReadFile(goldenPath)
				if err != nil {
					t.Fatalf("read golden %s: %v", goldenPath, err)
				}
				// A vacuous golden would make this assertion prove nothing.
				if len(goldenBytes) == 0 {
					t.Fatalf("golden %s is empty", goldenPath)
				}

				stdout, stderr, code := runCLI(verb, program)
				if code != 0 {
					t.Fatalf("%s exit = %d, want 0 (stderr=%q)", verb, code, stderr)
				}
				if stdout != string(goldenBytes) {
					t.Errorf("%s diverged from the Dart CLI on %s\n got: %q\nwant: %q",
						verb, fx, stdout, string(goldenBytes))
				}
			})
			compared++
		}
	}
	// Positive floor: an empty fixture list, a renamed golden directory, or a
	// silently-skipped loop must never read as a pass (see the project's "test
	// gates need a positive floor" rule).
	if want := len(goldenFixtures) * len(goldenVerbs); compared != want {
		t.Fatalf("compared %d golden reports, want %d", compared, want)
	}
	if compared < 1 {
		t.Fatal("the parity gate compared nothing")
	}
}

// The compiled versionLine is the whole of `ball version`'s logic ("ball " +
// version), so it is asserted directly against the compiled function for
// several representative version strings rather than through a golden file —
// mirroring rust/cli/src/commands/version.rs's unit test and the Dart parity
// test's versionReport case.
func TestCompiledVersionLineMatchesDartFormat(t *testing.T) {
	checked := 0
	for _, v := range []string{"0.1.0", "1.0.0", "0.3.0+6"} {
		if got, want := compiled.VersionLine(v), "ball "+v; got != want {
			t.Errorf("VersionLine(%q) = %q, want %q", v, got, want)
		}
		checked++
	}
	if checked < 1 {
		t.Fatal("no version strings checked")
	}
}

// `ball version` end-to-end: the CLI prints the compiled line for the version it
// resolves, and that version is the module's own (never empty, never "(devel)").
func TestVersionVerbPrintsBallPrefixedModuleVersion(t *testing.T) {
	stdout, stderr, code := runCLI("version")
	if code != 0 {
		t.Fatalf("version exit = %d, want 0 (stderr=%q)", code, stderr)
	}
	want := "ball " + toolchainVersion() + "\n"
	if stdout != want {
		t.Errorf("version stdout = %q, want %q", stdout, want)
	}
	if toolchainVersion() == "" || strings.Contains(toolchainVersion(), "devel") {
		t.Errorf("toolchainVersion() = %q, want a real version", toolchainVersion())
	}
}

// `ball validate` on a structurally invalid program prints cli_core's own
// `Invalid: N error(s) found` report — to stderr, with exit 2 (go/cli's
// invalid-program code; see validate.go's doc comment for why it is not Dart's
// generic 1).
func TestValidateReportsInvalidProgramAndExits2(t *testing.T) {
	path := filepath.Join(t.TempDir(), "invalid.ball.json")
	body := `{"@type":"type.googleapis.com/ball.v1.Program","name":"bad","version":"1.0.0",` +
		`"entryModule":"","entryFunction":"","modules":[]}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write invalid program: %v", err)
	}

	stdout, stderr, code := runCLI("validate", path)
	if code != 2 {
		t.Fatalf("validate exit = %d, want 2 (stderr=%q)", code, stderr)
	}
	if stdout != "" {
		t.Errorf("validate must print nothing to stdout on failure, got %q", stdout)
	}
	for _, want := range []string{"Invalid: 2 error(s) found", "Missing entry_module", "Missing entry_function"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr %q does not contain %q", stderr, want)
		}
	}
}

// Loading happens before the report: a missing file is still an I/O error (3)
// and a malformed program a parse error (2), not a cli-core message.
func TestCliCoreVerbsReportLoadFailuresFirst(t *testing.T) {
	bad := filepath.Join(t.TempDir(), "not-json.ball.json")
	if err := os.WriteFile(bad, []byte("{not json"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	missing := filepath.Join(t.TempDir(), "absent.ball.json")

	checked := 0
	for _, verb := range goldenVerbs {
		if _, _, code := runCLI(verb, missing); code != 3 {
			t.Errorf("%s on a missing file exit = %d, want 3", verb, code)
		}
		if _, _, code := runCLI(verb, bad); code != 2 {
			t.Errorf("%s on a malformed program exit = %d, want 2", verb, code)
		}
		checked += 2
	}
	if checked != len(goldenVerbs)*2 {
		t.Fatalf("checked %d cases, want %d", checked, len(goldenVerbs)*2)
	}
}

// The usage text must list every verb the dispatch accepts — the local half of
// the cross-CLI verb-set parity gate (tools/check_cli_verb_parity.py), which
// scrapes exactly this text.
func TestUsageListsEveryCliCoreVerb(t *testing.T) {
	stdout, _, code := runCLI("--help")
	if code != 0 {
		t.Fatalf("--help exit = %d, want 0", code)
	}
	for _, verb := range []string{"run", "compile", "encode", "check", "info", "validate", "tree", "version"} {
		if !strings.Contains(stdout, fmt.Sprintf("\n  %s ", verb)) &&
			!strings.Contains(stdout, fmt.Sprintf("\n  %s\n", verb)) &&
			!strings.Contains(stdout, fmt.Sprintf("\n  %-8s ", verb)) {
			t.Errorf("usage does not list verb %q:\n%s", verb, stdout)
		}
	}
}
