// Package rq1study is the Go port of Tier A of the third-party coverage study
// (issue #493) — the sibling of tools/coverage-study/rq1_study.dart.
//
// # What it measures
//
// For every .go file of a pinned third-party module, does
//
//	Go source -> go/encoder -> go/compiler.CompileLibrary -> Go source -> go/encoder
//
// come back with the same declarations and the same semantic Ball IR? A file is
// clean only when it encodes, compiles back, re-encodes, keeps every declaration
// it started with, and reaches a SECOND-GENERATION FIXPOINT (compiling the
// re-encoded program again produces the same Go and the same metadata-stripped
// IR). Cleanliness is deliberately strict — the first baselines are expected to
// be low, and measuring that honestly is the point.
//
// # Why the funnel exists
//
// The clean percentage alone cannot tell "the encoder rejected the file
// outright" from "everything worked but generation three drifted". On a
// pipeline that is not round-trip-closed the entire signal lives in that
// difference, so the report prints how many scored files survived each stage.
//
// # The two load-bearing settings
//
//  1. LIBRARY-MODE COMPILE, never Compile(). Real library files have no entry
//     point; compiler.Compile requires one. compiler.CompileLibrary does not.
//  2. A SYNTHESIZED ENTRY POINT FOR ENCODING ONLY. Unlike the Dart, Rust and C#
//     encoders, go/encoder has no library mode: Encode fails loud with "a Ball
//     Program requires a `func main()` entry point" on every entry-point-less
//     file, which is every real library file. Rather than score all of them as
//     one blanket encode-error — a measurement of the missing library mode, not
//     of the encoder's construct coverage — the harness appends an EMPTY
//     `func main() {}` before encoding when the file has none. That carries no
//     semantics and is excluded from the declaration inventory on both sides
//     (so is a real `func main`, which library-mode compilation deliberately
//     renames to `ball_main`). This accommodation is the Go analog of the Dart
//     harness's per-module compileModule setting, and it is disclosed in
//     tests/conformance/COVERAGE_STUDY.md — a Go encoder library mode would
//     remove the need for it.
//
// The declaration inventory is walked with go/parser + go/ast DIRECTLY, never
// through go/encoder's own walk, so a bug in the encoder's bookkeeping cannot
// hide a lost declaration from the harness.
package rq1study

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ball-lang/ball/go/compiler"
	"github.com/ball-lang/ball/go/encoder"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/encoding/protojson"
)

// studyPackage is the package name library-mode compilation emits. Arbitrary —
// nothing links the output, it is only parsed and re-encoded.
const studyPackage = "ballstudy"

// FileResult is one file's verdict. Mirrors rq1_study.dart's FileResult.
type FileResult struct {
	Package string `json:"package"`
	File    string `json:"file"`
	// Scored is false for files with nothing to compile (a directives-only
	// file, a generated stub). Not counted in the Tier A denominator — a file
	// with no declarations is not evidence either way.
	Scored bool `json:"scored"`
	// Clean means the file survived every scored stage.
	Clean bool `json:"clean"`
	// IRStable is INFORMATIONAL, not part of Clean: the metadata-stripped Ball
	// IR of the re-encoded output is identical to the first pass.
	IRStable bool `json:"irStable"`
	// Reason is a taxonomy tag plus detail, e.g. "encode-error: …".
	Reason string `json:"reason"`
}

// stageReached maps a taxonomy tag to the last stage a scored file survived.
// An unrecognised tag is a harness bug, not a datum — see StageReached.
var stageReached = map[string]int{
	"read-error":        0,
	"parse-error":       0,
	"encode-error":      0,
	"compile-error":     1,
	"reencode-error":    2,
	"declaration-drift": 3,
	"fixpoint-error":    4,
	"fixpoint-drift":    4,
	"clean":             5,
}

// stageLabels are the funnel rows, in order.
var stageLabels = []struct {
	Threshold int
	Label     string
}{
	{1, "1 encoded"},
	{2, "2 compiled back"},
	{3, "3 re-encoded"},
	{4, "4 declarations kept"},
	{5, "5 fixpoint (clean)"},
}

// StageReached returns the last stage a scored file survived, derived from its
// taxonomy tag. An unknown tag is an error rather than a default, so a new
// failure mode cannot be silently mis-attributed in the funnel.
func StageReached(reason string) (int, error) {
	tag, _, _ := strings.Cut(reason, ":")
	stage, ok := stageReached[tag]
	if !ok {
		return -1, fmt.Errorf("unknown taxonomy tag %q — the funnel would silently lie", tag)
	}
	return stage, nil
}

// StripMetadata recursively drops every "metadata" map. Metadata is cosmetic
// (Ball invariant #2), so two programs that differ only there are semantically
// identical — the project's own definition of semantic equality.
func StripMetadata(node any) any {
	switch v := node.(type) {
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, value := range v {
			if key == "metadata" {
				continue
			}
			out[key] = StripMetadata(value)
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, value := range v {
			out[i] = StripMetadata(value)
		}
		return out
	default:
		return node
	}
}

// canonicalIR renders a Program as metadata-stripped, key-sorted JSON.
// protojson deliberately injects unstable whitespace, so its output is round
// tripped through encoding/json (which sorts map keys) before comparison.
func canonicalIR(prog *ballv1.Program) (string, error) {
	raw, err := protojson.Marshal(prog)
	if err != nil {
		return "", err
	}
	var tree any
	if err := json.Unmarshal(raw, &tree); err != nil {
		return "", err
	}
	out, err := json.Marshal(StripMetadata(tree))
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// entryDecl is the empty entry point appended for encoding only — see the
// package doc's load-bearing setting 2.
const entryDecl = "\n\nfunc main() {}\n"

// withEntry returns source with an empty `func main()` appended when the file
// declares none, and reports whether it had to add one.
func withEntry(file *ast.File, source string) string {
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if ok && fn.Recv == nil && fn.Name.Name == "main" {
			return source
		}
	}
	return source + entryDecl
}

// DeclarationInventory is the declaration inventory of source: one entry per
// top-level declaration, struct fields and methods included, so a lost method
// is visible and mere reordering is not. Walked with go/parser + go/ast
// directly — independent of go/encoder's own walk.
//
// `func main` is excluded on purpose: library-mode compilation renames the
// entry function to ball_main, and the harness may itself have synthesized one.
func DeclarationInventory(source string) (map[string]bool, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "source.go", source, parser.SkipObjectResolution)
	if err != nil {
		return nil, err
	}
	return inventoryOf(file), nil
}

func inventoryOf(file *ast.File) map[string]bool {
	names := map[string]bool{}
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Recv == nil {
				if d.Name.Name == "main" {
					continue
				}
				names["func "+d.Name.Name] = true
				continue
			}
			names["method "+receiverName(d.Recv)+"."+d.Name.Name] = true
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				switch s := spec.(type) {
				case *ast.TypeSpec:
					names["type "+s.Name.Name] = true
					if st, ok := s.Type.(*ast.StructType); ok && st.Fields != nil {
						for _, field := range st.Fields.List {
							for _, fieldName := range field.Names {
								names["type "+s.Name.Name+"."+fieldName.Name] = true
							}
						}
					}
				case *ast.ValueSpec:
					kind := "var"
					if d.Tok == token.CONST {
						kind = "const"
					}
					for _, valueName := range s.Names {
						names[kind+" "+valueName.Name] = true
					}
				}
			}
		}
	}
	return names
}

func receiverName(recv *ast.FieldList) string {
	if recv == nil || len(recv.List) == 0 {
		return "<unknown>"
	}
	switch t := recv.List[0].Type.(type) {
	case *ast.StarExpr:
		if ident, ok := t.X.(*ast.Ident); ok {
			return ident.Name
		}
	case *ast.Ident:
		return t.Name
	}
	return "<unknown>"
}

func firstLine(err error) string {
	text := strings.ReplaceAll(err.Error(), "\r", "")
	if cut := strings.Index(text, "\n"); cut != -1 {
		text = text[:cut]
	}
	if len(text) > 160 {
		return text[:160] + "…"
	}
	return text
}

func lost(before, after map[string]bool) []string {
	var missing []string
	for name := range before {
		if !after[name] {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	return missing
}

// StudyFile runs Tier A over one file's source and returns its verdict.
func StudyFile(pkg, file, source string) FileResult {
	fset := token.NewFileSet()
	parsed, err := parser.ParseFile(fset, "source.go", source, parser.SkipObjectResolution)
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true,
			Reason: "parse-error: " + firstLine(err)}
	}
	before := inventoryOf(parsed)
	if len(before) == 0 {
		return FileResult{Package: pkg, File: file, Scored: false,
			Reason: "skipped: no top-level declarations to compile"}
	}

	// Stage 1 — encode (with the synthesized entry point, see the package doc).
	prog, err := encoder.Encode(withEntry(parsed, source))
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true,
			Reason: "encode-error: " + firstLine(err)}
	}
	firstIR, err := canonicalIR(prog)
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true,
			Reason: "encode-error: " + firstLine(err)}
	}

	// Stage 2 — compile back in LIBRARY mode.
	compiled, err := compiler.CompileLibrary(prog, studyPackage)
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true,
			Reason: "compile-error: " + firstLine(err)}
	}
	if strings.TrimSpace(compiled) == "" {
		return FileResult{Package: pkg, File: file, Scored: false,
			Reason: "skipped: the file compiles to nothing (no user module)"}
	}

	// Stage 3 — re-encode the compiled Go.
	compiledParsed, err := parser.ParseFile(token.NewFileSet(), "compiled.go", compiled, parser.SkipObjectResolution)
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true,
			Reason: "reencode-error: the compiler emitted Go that does not parse — " + firstLine(err)}
	}
	prog2, err := encoder.Encode(withEntry(compiledParsed, compiled))
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true,
			Reason: "reencode-error: " + firstLine(err)}
	}
	secondIR, err := canonicalIR(prog2)
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true,
			Reason: "reencode-error: " + firstLine(err)}
	}
	irStable := firstIR == secondIR

	// Stage 4 — declaration inventory preserved?
	after := inventoryOf(compiledParsed)
	if missing := lost(before, after); len(missing) > 0 {
		shown := missing
		if len(shown) > 3 {
			shown = shown[:3]
		}
		return FileResult{Package: pkg, File: file, Scored: true, IRStable: irStable,
			Reason: fmt.Sprintf("declaration-drift: lost %d declaration(s) — %s",
				len(missing), strings.Join(shown, ", "))}
	}

	// Stage 5 — SECOND-GENERATION FIXPOINT. Generation 1 vs. 2 is not a usable
	// signal (the compiler faithfully lowers Ball's single `input` parameter
	// back to a named local, so almost nothing is stable across the first pass).
	// From generation 2 on that lowering is already applied, so a pipeline that
	// neither loses nor invents meaning must reach a fixpoint.
	compiled2, err := compiler.CompileLibrary(prog2, studyPackage)
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true, IRStable: irStable,
			Reason: "fixpoint-error: generation 2 failed to compile — " + firstLine(err)}
	}
	compiled2Parsed, err := parser.ParseFile(token.NewFileSet(), "compiled2.go", compiled2, parser.SkipObjectResolution)
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true, IRStable: irStable,
			Reason: "fixpoint-error: generation 2 does not parse — " + firstLine(err)}
	}
	prog3, err := encoder.Encode(withEntry(compiled2Parsed, compiled2))
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true, IRStable: irStable,
			Reason: "fixpoint-error: generation 2 failed to re-encode — " + firstLine(err)}
	}
	thirdIR, err := canonicalIR(prog3)
	if err != nil {
		return FileResult{Package: pkg, File: file, Scored: true, IRStable: irStable,
			Reason: "fixpoint-error: " + firstLine(err)}
	}
	if compiled != compiled2 || secondIR != thirdIR {
		return FileResult{Package: pkg, File: file, Scored: true, IRStable: irStable,
			Reason: "fixpoint-drift: recompiling the re-encoded program changed it again"}
	}

	return FileResult{Package: pkg, File: file, Scored: true, Clean: true,
		IRStable: irStable, Reason: "clean"}
}

// GoFilesUnder lists every non-test .go file under dir, sorted. Test files are
// excluded: they are not the library surface a consumer compiles.
func GoFilesUnder(dir string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(dir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == "testdata" || entry.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go") {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
}

// StudyDirectory runs Tier A over every .go file under dir.
func StudyDirectory(pkg, dir string) ([]FileResult, error) {
	files, err := GoFilesUnder(dir)
	if err != nil {
		return nil, err
	}
	results := make([]FileResult, 0, len(files))
	for _, path := range files {
		rel, relErr := filepath.Rel(dir, path)
		if relErr != nil {
			rel = path
		}
		rel = filepath.ToSlash(rel)
		// Read as BYTES: no newline translation, so a semantic lone \r survives.
		source, readErr := os.ReadFile(path)
		if readErr != nil {
			results = append(results, FileResult{Package: pkg, File: rel, Scored: true,
				Reason: "read-error: " + firstLine(readErr)})
			continue
		}
		results = append(results, StudyFile(pkg, rel, string(source)))
	}
	return results, nil
}

// Report prints the same summary shape as every other Tier A harness and
// returns the process exit code. A run that scored nothing is a
// harness/checkout failure, not a 0% result.
func Report(out *strings.Builder, results []FileResult, missingPins []string) (int, error) {
	scored := make([]FileResult, 0, len(results))
	for _, r := range results {
		if r.Scored {
			scored = append(scored, r)
		}
	}
	total := len(scored)
	clean, irStable := 0, 0
	byReason := map[string]int{}
	for _, r := range scored {
		if r.Clean {
			clean++
		}
		if r.IRStable {
			irStable++
		}
		tag, _, _ := strings.Cut(r.Reason, ":")
		byReason[tag]++
	}

	tags := make([]string, 0, len(byReason))
	for tag := range byReason {
		tags = append(tags, tag)
	}
	sort.Slice(tags, func(i, j int) bool {
		if byReason[tags[i]] != byReason[tags[j]] {
			return byReason[tags[i]] > byReason[tags[j]]
		}
		return tags[i] < tags[j]
	})
	for _, tag := range tags {
		fmt.Fprintf(out, "  %s: %d\n", tag, byReason[tag])
	}
	if skipped := len(results) - total; skipped > 0 {
		fmt.Fprintf(out, "  skipped (no declarations, not scored): %d\n", skipped)
	}
	if len(missingPins) > 0 {
		fmt.Fprintf(out, "  unreachable pins (not scored): %s\n", strings.Join(missingPins, ", "))
	}

	if total > 0 {
		fmt.Fprintf(out, "Funnel (scored files that survived each stage):\n")
		for _, row := range stageLabels {
			reached := 0
			for _, r := range scored {
				stage, err := StageReached(r.Reason)
				if err != nil {
					return 1, err
				}
				if stage >= row.Threshold {
					reached++
				}
			}
			fmt.Fprintf(out, "  %s: %d/%d\n", row.Label, reached, total)
		}
	}

	pct := 0
	if total > 0 {
		pct = int(float64(clean)*100/float64(total) + 0.5)
	}
	fmt.Fprintf(out, "Tier A: %d/%d clean (%d%%)\n", clean, total, pct)
	fmt.Fprintf(out, "Tier A (IR fixpoint, informational): %d/%d stable\n", irStable, total)
	fmt.Fprintf(out, "Results: %d passed, %d failed, %d total\n", clean, total-clean, total)

	if total < 1 {
		return 1, fmt.Errorf("Tier A scored 0 files — no package checkout was readable")
	}
	return 0, nil
}
