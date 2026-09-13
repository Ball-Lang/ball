package conformance

// Corpus discovery, result types and diff formatting shared by every leg in this
// package.
//
// The C# harness's Fixtures.cs plays the same role for its three legs. Nothing
// in this package is build-tag-gated any more: since #586 the compiled engine is
// a committed artifact, so the engine leg (runner.go) and the round-trip leg
// (roundtrip.go) both build in a fresh checkout.

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

// detailBudget is the character budget one `FAILING [name] status detail` line
// gets. It matches what the sibling harnesses spend — csharp/engine/conformance/
// Fixtures.cs's `Truncate(detail, 200)` and rust/engine/tests/
// roundtrip_conformance.rs's `first_line` — so the four legs' logs are equally
// diagnosable.
const detailBudget = 200

// errorDetail renders a (possibly multi-line) error as the ONE line a leg prints
// per failing fixture.
//
// The compiler's and the encoder's errors are multi-line by construction — a
// header plus one bullet per unsupported construct — and a fixture's whole
// diagnosis lives in those bullets. This used to keep only the text before the
// first newline, so the Go row's CI log read `go→ball: 6 unsupported
// construct(s):` and nothing else: a truncation with no ellipsis and no hint
// that anything had been cut, which is why issue #642's investigation had to
// reproduce this leg locally to learn what the six were. Python joins with
// " / " (python/engine/conformance/roundtrip.py) and C#/Rust truncate visibly at
// 200 characters; this does both.
func errorDetail(s string) string {
	var parts []string
	for _, line := range strings.Split(s, "\n") {
		trimmed := strings.TrimRight(line, " \t\r")
		if strings.TrimSpace(trimmed) != "" {
			parts = append(parts, trimmed)
		}
	}
	joined := strings.Join(parts, " / ")
	if runes := []rune(joined); len(runes) > detailBudget {
		return string(runes[:detailBudget]) + "…"
	}
	return joined
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
