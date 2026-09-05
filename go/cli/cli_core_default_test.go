//go:build !clicore

package cli

import (
	"strings"
	"testing"
)

// The default build's half of the cli-core contract (issue #570): the verbs
// EXIST — the dispatch accepts them and the usage lists them — but without the
// generated compiled/compiled_cli.go they degrade HONESTLY: exit 1, nothing on
// stdout, and a message naming the two commands that fix it. Never a silent
// success (which would ship wrong reports), never an "unknown command" (which
// would hide the verb from the cross-CLI verb-set parity gate), and never a
// build failure.
//
// This is the CLI-level analog of run_test.go's ErrSelfHostPending case, and the
// Go sibling of rust/cli/tests/cli_core_parity.rs's
// `default_build_reports_cli_core_pending_honestly_for_every_verb`.

var cliCoreVerbs = []string{"info", "validate", "tree", "version"}

func TestDefaultBuildReportsCliCorePendingHonestly(t *testing.T) {
	program := fixture(t, "tests", "conformance", "101_simple_class.ball.json")

	checked := 0
	for _, verb := range cliCoreVerbs {
		args := []string{verb}
		if verb != "version" { // `version` takes no program
			args = append(args, program)
		}
		stdout, stderr, code := runCLI(args...)
		if code != 1 {
			t.Errorf("%s exit = %d, want 1 (stderr=%q)", verb, code, stderr)
		}
		if stdout != "" {
			t.Errorf("%s must print nothing without the compiled CLI core, got %q", verb, stdout)
		}
		for _, want := range []string{"clicore", "go run ./cmd/regen", "gen_cli_json.dart"} {
			if !strings.Contains(stderr, want) {
				t.Errorf("%s: stderr %q does not name %q", verb, stderr, want)
			}
		}
		checked++
	}
	// Positive floor: a shrunken verb list must not read as a pass.
	if checked != len(cliCoreVerbs) || checked < 4 {
		t.Fatalf("checked %d verbs, want %d (>= 4)", checked, len(cliCoreVerbs))
	}
}

// A missing or malformed program still reports its OWN failure — the cli-core
// gap must not mask an I/O (3) or parse (2) error, since that ordering is what
// makes `ball info nonexistent.ball.json` diagnosable in a default build.
func TestDefaultBuildStillReportsLoadFailuresFirst(t *testing.T) {
	for _, verb := range []string{"info", "validate", "tree"} {
		if _, _, code := runCLI(verb, "definitely-not-here.ball.json"); code != 3 {
			t.Errorf("%s on a missing file exit = %d, want 3", verb, code)
		}
	}
}

// The verbs must be listed in `--help` even in a default build: the cross-CLI
// verb-set parity gate (tools/check_cli_verb_parity.py) scrapes `--help`, and a
// build-tag-dependent usage text would make that gate's answer depend on how the
// binary was built.
func TestUsageListsCliCoreVerbsInDefaultBuild(t *testing.T) {
	stdout, _, code := runCLI("--help")
	if code != 0 {
		t.Fatalf("--help exit = %d, want 0", code)
	}
	for _, verb := range cliCoreVerbs {
		if !strings.Contains(stdout, "\n  "+verb) {
			t.Errorf("usage does not list verb %q:\n%s", verb, stdout)
		}
	}
	if cliCoreBuiltIn {
		t.Fatal("cliCoreBuiltIn must be false in a default (!clicore) build")
	}
}
