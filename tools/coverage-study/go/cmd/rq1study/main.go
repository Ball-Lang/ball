// Command rq1study runs Tier A of the third-party coverage study over pinned
// Go modules (issue #493) — the Go sibling of
// `dart run tools/coverage-study/rq1_study.dart`.
//
// Usage (from tools/coverage-study/go):
//
//	go run ./cmd/rq1study --pins ../packages/go.json --checkouts <dir> [--json <out>]
//	go run ./cmd/rq1study --package <name> --source-dir <dir> [--json <out>]
//
// Report-only: the methodology and the load-bearing harness settings are
// documented in tests/conformance/COVERAGE_STUDY.md. The one thing that fails
// here is a run that scored zero files — a harness/checkout failure, never a 0%
// result.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ball-lang/ball/tools/coverage-study/rq1study"
)

type pin struct {
	Name string `json:"name"`
	Repo string `json:"repo"`
	Ref  string `json:"ref"`
	Lib  string `json:"lib"`
}

type pinFile struct {
	Packages []pin `json:"packages"`
}

func main() {
	pins := flag.String("pins", "", "pin list (tools/coverage-study/packages/go.json)")
	checkouts := flag.String("checkouts", "", "directory holding one clone per pinned package")
	pkg := flag.String("package", "", "single package name (with --source-dir)")
	sourceDir := flag.String("source-dir", "", "single source tree (with --package)")
	jsonOut := flag.String("json", "", "write the per-file report here")
	flag.Parse()

	var (
		results     []rq1study.FileResult
		missingPins []string
	)

	switch {
	case *pins != "":
		if *checkouts == "" {
			fmt.Fprintln(os.Stderr, "--pins requires --checkouts <dir>")
			os.Exit(2)
		}
		raw, err := os.ReadFile(*pins)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		var parsed pinFile
		if err := json.Unmarshal(raw, &parsed); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		for _, p := range parsed.Packages {
			lib := p.Lib
			if lib == "" {
				lib = "."
			}
			dir := filepath.Join(*checkouts, p.Name, lib)
			if info, err := os.Stat(dir); err != nil || !info.IsDir() {
				// An unreachable pin is NOT an encoder regression — report it as
				// a distinct outcome instead of scoring it as a failure.
				missingPins = append(missingPins, p.Name)
				continue
			}
			r, err := rq1study.StudyDirectory(p.Name, dir)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(2)
			}
			results = append(results, r...)
		}
	case *pkg != "" && *sourceDir != "":
		if info, err := os.Stat(*sourceDir); err != nil || !info.IsDir() {
			fmt.Fprintf(os.Stderr, "--source-dir does not exist: %s\n", *sourceDir)
			os.Exit(2)
		}
		r, err := rq1study.StudyDirectory(*pkg, *sourceDir)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		results = r
	default:
		fmt.Fprintln(os.Stderr,
			"Usage: rq1study --pins <file> --checkouts <dir> [--json <out>]\n"+
				"       rq1study --package <name> --source-dir <dir> [--json <out>]")
		os.Exit(2)
	}

	if *jsonOut != "" {
		if missingPins == nil {
			missingPins = []string{}
		}
		if results == nil {
			results = []rq1study.FileResult{}
		}
		blob, err := json.MarshalIndent(map[string]any{
			"missingPins": missingPins,
			"files":       results,
		}, "", "  ")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		if err := os.WriteFile(*jsonOut, append(blob, '\n'), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
	}

	var out strings.Builder
	code, err := rq1study.Report(&out, results, missingPins)
	fmt.Print(out.String())
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
	}
	os.Exit(code)
}
