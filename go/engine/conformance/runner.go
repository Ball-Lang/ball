//go:build selfhost

package conformance

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	engine "github.com/ball-lang/ball/go/engine"
)

// perFixtureTimeout bounds each fixture so a latent infinite loop cannot wedge
// the whole sweep (matches the Rust/C# runners' 120 s budget). Override with
// BALL_TIMEOUT_MS for faster iteration sweeps.
func perFixtureTimeout() time.Duration {
	if ms := os.Getenv("BALL_TIMEOUT_MS"); ms != "" {
		if n, err := strconv.Atoi(ms); err == nil && n > 0 {
			return time.Duration(n) * time.Millisecond
		}
	}
	return 120 * time.Second
}

// Result is one fixture's outcome.
type Result struct {
	Name   string
	Status string // "pass", "fail", "timeout", "error"
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

// RunAll drives every tests/conformance/*.ball.json fixture through the compiled
// self-hosted engine and compares stdout to its .expected_output.txt golden. A
// fixture with no golden is a documented carve-out and is skipped (like the Dart
// runner). If onlyFixture is non-empty, only that fixture runs.
func RunAll(onlyFixture string) (Summary, error) {
	dir, err := conformanceDir()
	if err != nil {
		return Summary{}, err
	}
	entries, err := filepath.Glob(filepath.Join(dir, "*.ball.json"))
	if err != nil {
		return Summary{}, err
	}
	sort.Strings(entries)

	var s Summary
	for _, path := range entries {
		name := strings.TrimSuffix(filepath.Base(path), ".ball.json")
		if onlyFixture != "" && name != onlyFixture {
			continue
		}
		goldenPath := strings.TrimSuffix(path, ".ball.json") + ".expected_output.txt"
		golden, gerr := os.ReadFile(goldenPath)
		if gerr != nil {
			s.Skipped++
			continue
		}
		r := runOne(name, path, string(golden))
		s.Results = append(s.Results, r)
		s.Total++
		if r.Status == "pass" {
			s.Passed++
		} else {
			s.Failed++
		}
	}
	return s, nil
}

func runOne(name, path, golden string) Result {
	data, err := os.ReadFile(path)
	if err != nil {
		return Result{name, "error", err.Error()}
	}

	type outcome struct {
		out []string
		err error
	}
	ch := make(chan outcome, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				ch <- outcome{nil, asError(r)}
			}
		}()
		eng, err := engine.FromJSON(data)
		if err != nil {
			ch <- outcome{nil, err}
			return
		}
		out, err := eng.Run()
		ch <- outcome{out, err}
	}()

	select {
	case res := <-ch:
		if res.err != nil {
			return Result{name, "error", firstLine(res.err.Error())}
		}
		actual := strings.TrimRight(strings.Join(res.out, "\n"), "\n\r")
		expected := strings.TrimRight(strings.ReplaceAll(golden, "\r\n", "\n"), "\n")
		if actual == expected {
			return Result{name, "pass", ""}
		}
		return Result{name, "fail", diffDetail(expected, actual)}
	case <-time.After(perFixtureTimeout()):
		return Result{name, "timeout", ""}
	}
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

func asError(r any) error {
	if e, ok := r.(error); ok {
		return e
	}
	return &recoveredError{r}
}

type recoveredError struct{ v any }

func (e *recoveredError) Error() string { return fmt.Sprint(e.v) }

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
