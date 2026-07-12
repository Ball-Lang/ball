package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/types/known/structpb"
)

func TestCheckValidProgram(t *testing.T) {
	prog := fixture(t, "examples", "hello_world", "hello_world.ball.json")
	stdout, stderr, code := runCLI("check", prog)
	if code != 0 {
		t.Fatalf("exit = %d, want 0 (stderr=%q)", code, stderr)
	}
	if !strings.Contains(stdout, `Valid: "hello_world"`) {
		t.Errorf("summary = %q, want it to name the program", stdout)
	}
	if !strings.Contains(stdout, "module(s)") {
		t.Errorf("summary missing module/function counts: %q", stdout)
	}
}

func TestCheckRejectsInvalidProgram(t *testing.T) {
	// A well-formed JSON ball.v1.Program that is structurally invalid: it names
	// no entry point and has an unnamed module.
	bad := `{
      "@type": "type.googleapis.com/ball.v1.Program",
      "name": "broken",
      "version": "1.0.0",
      "modules": [ { } ]
    }`
	path := filepath.Join(t.TempDir(), "broken.ball.json")
	if err := os.WriteFile(path, []byte(bad), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	_, stderr, code := runCLI("check", path)
	if code != 2 {
		t.Fatalf("exit = %d, want 2 (stderr=%q)", code, stderr)
	}
	for _, want := range []string{"invalid program", "missing entry_module", "missing entry_function"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr missing %q:\n%s", want, stderr)
		}
	}
}

func TestCheckCompileFlagCatchesUncompilable(t *testing.T) {
	// A structurally-sound program whose entry function calls an unsupported base
	// function: a body is present so the structural checks pass, but the compiler
	// fails loud on the unknown base call, which the -compile dry run surfaces.
	prog := &ballv1.Program{
		Name:          "uncompilable",
		Version:       "1.0.0",
		EntryModule:   "main",
		EntryFunction: "main",
		Modules: []*ballv1.Module{
			{
				Name: "std",
				Functions: []*ballv1.FunctionDefinition{{
					Name:   "definitely_not_a_base_fn",
					IsBase: true,
				}},
			},
			{
				Name: "main",
				Functions: []*ballv1.FunctionDefinition{{
					Name: "main",
					Body: &ballv1.Expression{
						Expr: &ballv1.Expression_Call{
							Call: &ballv1.FunctionCall{
								Module:   "std",
								Function: "definitely_not_a_base_fn",
							},
						},
					},
				}},
			},
		},
	}
	path := writeProgramJSON(t, prog)

	// Without -compile the structural checks pass (a body is present).
	if _, stderr, code := runCLI("check", path); code != 0 {
		t.Fatalf("check without -compile: exit = %d, want 0 (stderr=%q)", code, stderr)
	}
	// With -compile the dry run surfaces the problem as an invalid program.
	_, stderr, code := runCLI("check", "-compile", path)
	if code != 2 {
		t.Fatalf("check -compile: exit = %d, want 2 (stderr=%q)", code, stderr)
	}
	if !strings.Contains(stderr, "does not compile to Go") {
		t.Errorf("stderr = %q, want 'does not compile to Go'", stderr)
	}
}

func TestValidateStructureUnit(t *testing.T) {
	wellFormed := func() *ballv1.Program {
		return &ballv1.Program{
			Name:          "t",
			Version:       "1.0.0",
			EntryModule:   "main",
			EntryFunction: "main",
			Modules: []*ballv1.Module{{
				Name: "main",
				Functions: []*ballv1.FunctionDefinition{{
					Name:     "main",
					Metadata: &structpb.Struct{},
				}},
			}},
		}
	}

	if got := validateStructure(wellFormed()); len(got) != 0 {
		t.Errorf("well-formed program has findings: %v", got)
	}

	missingEntry := wellFormed()
	missingEntry.EntryModule = ""
	if !hasFinding(validateStructure(missingEntry), "missing entry_module") {
		t.Error("missing entry_module not reported")
	}

	badEntryFn := wellFormed()
	badEntryFn.EntryFunction = "ghost"
	if !hasFinding(validateStructure(badEntryFn), "entry function") {
		t.Error("unresolved entry function not reported")
	}

	dupModules := wellFormed()
	dupModules.Modules = append(dupModules.Modules, dupModules.Modules[0])
	if !hasFinding(validateStructure(dupModules), "duplicate module name") {
		t.Error("duplicate module name not reported")
	}

	bodiless := wellFormed()
	bodiless.Modules[0].Functions[0].Metadata = nil
	if !hasFinding(validateStructure(bodiless), "non-base function with no body or metadata") {
		t.Error("bodiless non-base function not reported")
	}
}

func hasFinding(findings []string, substr string) bool {
	for _, f := range findings {
		if strings.Contains(f, substr) {
			return true
		}
	}
	return false
}
