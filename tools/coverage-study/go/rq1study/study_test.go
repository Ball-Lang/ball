// Self-test for the Go Tier A coverage-study harness (issue #493).
//
// A new measuring instrument must not inherit the blind spot it exists to
// close. The gap #493 documents is that every existing gate is scoped to the
// project's own single-file, entry-point-shaped conformance fixtures, so real
// library code — no `func main`, declarations split across files — was never
// looked at. The cheapest way for this harness to inherit that blind spot would
// be to SKIP such files and then report a flattering number over what is left.
//
// WHAT THIS DOES AND DOES NOT PROVE. These assertions validate the HARNESS.
// They are not regression tests for any encoder/compiler defect: the Tier A run
// itself is report-only (coverage-study.yml has no pull_request: trigger), so a
// Go-pipeline regression it measures would not redden this or any other PR.
//
// The Dart original (rq1_study_self_test.dart) can assert "a plain file is
// reported clean" because the Dart round trip is closed — the Dart compiler
// emits idiomatic Dart the Dart encoder reads back. The Go round trip is NOT
// closed today: go/compiler emits `ballrt.*` calls, `defer`, function literals
// and top-level `var` blocks, and go/encoder supports none of those, so stage 3
// fails on every file that reaches it. There is therefore no Go source this
// harness can honestly call clean, and asserting one would mean weakening the
// harness until something passed. TestPlainLibraryFileSurvivesTheFunnel asserts
// the funnel instead — the strongest statement true today — and it strengthens
// by itself the moment the round trip closes.
package rq1study

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"testing"
)

// mustWithEntry parses source and applies the harness's entry-point
// accommodation to it.
func mustWithEntry(t *testing.T, source string) string {
	t.Helper()
	file, err := parser.ParseFile(token.NewFileSet(), "source.go", source, parser.SkipObjectResolution)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return withEntry(file, source)
}

// helper.go — a plain helper library: no `func main`, nothing exotic. Exactly
// the shape every gate before #493 never looked at.
const helperSource = `package demo

func twice(value int) int {
	return value * 2
}
`

// consumer.go — calls into the sibling file, so it cannot be understood in
// isolation, and still has no entry point.
const consumerSource = `package demo

func doubled(value int) int {
	return twice(value)
}

func combine(a int, b int) int {
	return a + b
}
`

// A construct the encoder explicitly rejects ("method with receiver … is not
// supported"). The negative control: it must be REPORTED with its own taxonomy
// tag and must stop strictly earlier in the funnel than the plain file, so the
// harness cannot pass by painting every file with one reason.
const unsupportedSource = `package demo

type Box struct {
	size int
}

func (b Box) Area() int {
	return b.size
}
`

func writePackage(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for name, source := range map[string]string{
		"helper.go":   helperSource,
		"consumer.go": consumerSource,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(source), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return dir
}

// 1 — the whole point of #493: entry-point-less files are SCORED, never
// silently skipped, and the scored denominator is >= 1 (a run that scores
// nothing proves nothing).
func TestEntryPointLessFilesAreScored(t *testing.T) {
	results, err := StudyDirectory("synthetic", writePackage(t))
	if err != nil {
		t.Fatalf("StudyDirectory: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected 2 file results, got %d: %+v", len(results), results)
	}
	scored := 0
	for _, r := range results {
		if !r.Scored {
			t.Errorf("%s was silently skipped (reason %q) — the blind spot #493 exists to close",
				r.File, r.Reason)
			continue
		}
		scored++
	}
	if scored < 1 {
		t.Fatal("the scored denominator is 0 — a run that scores nothing proves nothing")
	}
}

// 2 — the funnel is real: a plain library file gets PAST encode and
// compile-back. If the harness were failing everything at stage 1 and calling
// that a measurement, this would be 0.
func TestPlainLibraryFileSurvivesTheFunnel(t *testing.T) {
	result := StudyFile("synthetic", "helper.go", helperSource)
	stage, err := StageReached(result.Reason)
	if err != nil {
		t.Fatalf("StageReached(%q): %v", result.Reason, err)
	}
	if stage < 2 {
		t.Fatalf("a plain library file only reached stage %d (reason %q); "+
			"expected it to encode and compile back", stage, result.Reason)
	}
}

// 3 — every verdict carries a taxonomy tag the funnel knows. An unknown tag
// makes StageReached fail, so a new failure mode cannot be silently
// mis-attributed into the funnel.
func TestEveryVerdictCarriesAKnownTaxonomyTag(t *testing.T) {
	results, err := StudyDirectory("synthetic", writePackage(t))
	if err != nil {
		t.Fatalf("StudyDirectory: %v", err)
	}
	results = append(results, StudyFile("synthetic", "unsupported.go", unsupportedSource))
	for _, r := range results {
		if _, err := StageReached(r.Reason); err != nil {
			t.Errorf("%s: %v", r.File, err)
		}
	}
}

// 4 — the negative control: a construct the encoder rejects is scored, not
// clean, tagged encode-error, and stops STRICTLY EARLIER than the plain file.
// "Same reason for everything" is the failure mode this catches.
func TestTheHarnessDiscriminatesBetweenFailureModes(t *testing.T) {
	unsupported := StudyFile("synthetic", "unsupported.go", unsupportedSource)
	if !unsupported.Scored || unsupported.Clean {
		t.Fatalf("expected a scored, not-clean verdict, got scored=%v clean=%v reason=%q",
			unsupported.Scored, unsupported.Clean, unsupported.Reason)
	}
	if got := unsupported.Reason; len(got) < len("encode-error:") || got[:len("encode-error:")] != "encode-error:" {
		t.Fatalf("expected an encode-error taxonomy tag, got %q", got)
	}
	badStage, err := StageReached(unsupported.Reason)
	if err != nil {
		t.Fatal(err)
	}
	plainStage, err := StageReached(StudyFile("synthetic", "helper.go", helperSource).Reason)
	if err != nil {
		t.Fatal(err)
	}
	if badStage >= plainStage {
		t.Fatalf("the rejected file reached stage %d and the plain file stage %d — "+
			"the harness is not discriminating between failure modes", badStage, plainStage)
	}
}

// The declaration inventory is the harness's own eyes for stage 4. Prove it is
// a real go/ast walk: it must see methods and struct fields, and it must
// actually MISS a declaration that was removed, or stage 4 is a rubber stamp.
func TestDeclarationInventoryIsARealASTWalk(t *testing.T) {
	full, err := DeclarationInventory(`package demo

type Box struct {
	size int
}

const Limit = 3

func (b *Box) Area() int {
	return b.size
}

func free(value int) int {
	return value
}

func main() {}
`)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{
		"type Box":        true,
		"type Box.size":   true,
		"const Limit":     true,
		"method Box.Area": true,
		"func free":       true,
	}
	if len(full) != len(want) {
		t.Fatalf("inventory = %v, want %v", full, want)
	}
	for name := range want {
		if !full[name] {
			t.Errorf("inventory is missing %q", name)
		}
	}
	if full["func main"] {
		t.Error("`func main` must be excluded — library-mode compilation renames it " +
			"to ball_main and the harness may have synthesized it")
	}

	pruned, err := DeclarationInventory("package demo\n\ntype Box struct {\n\tsize int\n}\n")
	if err != nil {
		t.Fatal(err)
	}
	missing := lost(full, pruned)
	if len(missing) != 3 {
		t.Fatalf("expected the walker to notice 3 lost declarations, got %v", missing)
	}
}

// The synthesized entry point is appended only when the file has none, and it
// is never counted as a declaration — otherwise the harness would be measuring
// its own accommodation.
func TestSyntheticEntryPointIsAddedOnlyWhenMissing(t *testing.T) {
	withMain := "package demo\n\nfunc main() {}\n"
	if got := mustWithEntry(t, withMain); got != withMain {
		t.Fatalf("a file that already declares main must not be touched, got:\n%s", got)
	}
	got := mustWithEntry(t, helperSource)
	if got == helperSource {
		t.Fatal("an entry-point-less file must get a synthesized `func main()` for encoding")
	}
	inv, err := DeclarationInventory(got)
	if err != nil {
		t.Fatal(err)
	}
	if inv["func main"] {
		t.Fatal("the synthesized entry point leaked into the declaration inventory")
	}
}
