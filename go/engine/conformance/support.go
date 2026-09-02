package conformance

// Corpus discovery, result types and diff formatting shared by every leg in this
// package.
//
// Deliberately UNTAGGED. The engine leg (runner.go) needs `-tags selfhost`
// because it drives the generated, gitignored compiled_engine.go; the round-trip
// leg (roundtrip.go) does not touch the compiled engine at all and must stay
// runnable in a fresh checkout. These shared pieces therefore cannot live behind
// the tag — the C# harness's Fixtures.cs plays the same role for its three legs.

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Result is one fixture's outcome. Status is "pass" plus, per leg, one of
// "fail", "timeout", "error", "compile-error", "encode-error".
type Result struct {
	Name   string
	Status string
	Detail string
}

// Summary is a whole-corpus sweep outcome.
type Summary struct {
	Passed  int
	Failed  int
	Total   int
	Skipped int // golden-less carve-outs
	Results []Result
}

func diffDetail(expected, actual string) string {
	el := strings.Split(expected, "\n")
	al := strings.Split(actual, "\n")
	if os.Getenv("BALL_FIXTURE") != "" {
		return "\n--- expected (" + strconv.Itoa(len(el)) + ") ---\n" + expected +
			"\n--- actual (" + strconv.Itoa(len(al)) + ") ---\n" + actual
	}
	return "expected(" + strconv.Itoa(len(el)) + "): " + first(el) + " | actual(" + strconv.Itoa(len(al)) + "): " + first(al)
}

func first(xs []string) string {
	if len(xs) == 0 {
		return "<none>"
	}
	return xs[0]
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// conformanceDir walks up from the test's working directory to the repo root and
// returns tests/conformance.
func conformanceDir() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		candidate := filepath.Join(dir, "tests", "conformance")
		if fi, err := os.Stat(candidate); err == nil && fi.IsDir() {
			return candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", os.ErrNotExist
		}
		dir = parent
	}
}
