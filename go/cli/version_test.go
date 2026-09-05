package cli

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// The drift guard for `ball version` (issue #570): moduleVersion must equal the
// version go/cli's own go.mod requires its intra-repo siblings at, which IS the
// published Go module version — tools/go-module-proxy/build_local_proxy.py
// derives `--print-version` from those same require lines, and
// .github/workflows/tag-go-modules.yml tags `go/<module>/v<that>`.
//
// Without this, a version bump that edits go.mod but not version.go would ship a
// `ball version` that lies about which release the binary is, and nothing would
// notice.
func TestModuleVersionMatchesGoMod(t *testing.T) {
	data, err := os.ReadFile("go.mod")
	if err != nil {
		t.Fatalf("read go.mod: %v", err)
	}
	re := regexp.MustCompile(`github\.com/ball-lang/ball/go/[a-z]+ v([0-9]+\.[0-9]+\.[0-9]+)`)
	matches := re.FindAllStringSubmatch(string(data), -1)
	// Positive floor: no require lines means the regex (or the module layout)
	// changed and this guard silently stopped guarding.
	if len(matches) < 1 {
		t.Fatalf("go.mod names no intra-repo ball module requirements; the drift guard is broken")
	}
	for _, m := range matches {
		if m[1] != moduleVersion {
			t.Errorf("go.mod requires %s but version.go's moduleVersion is %q — bump both together",
				m[0], moduleVersion)
		}
	}
}

// toolchainVersion must always yield a usable version string: never empty, never
// Go's "(devel)" placeholder, never a leading "v" (the Rust/Dart/C# CLIs all
// print the unprefixed form).
func TestToolchainVersionIsUsable(t *testing.T) {
	got := toolchainVersion()
	if got == "" {
		t.Fatal("toolchainVersion() is empty")
	}
	if strings.HasPrefix(got, "v") {
		t.Errorf("toolchainVersion() = %q, want no leading %q", got, "v")
	}
	if strings.Contains(got, "devel") {
		t.Errorf("toolchainVersion() = %q, want a real version", got)
	}
}

// `ball version` takes no program argument (unlike info/validate/tree) — a
// stray positional is a usage error, in every build.
func TestVersionRejectsPositionalArguments(t *testing.T) {
	_, stderr, code := runCLI("version", "some-program.ball.json")
	if code != 2 {
		t.Errorf("version with an argument exit = %d, want 2 (stderr=%q)", code, stderr)
	}
}
