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
// BALL_TIMEOUT_MS for faster iteration sweeps. This is the *cooperative* budget:
// runOne feeds it to the compiled engine, whose per-expression timeout guard
// makes a runaway self-abort at this point (issue #436) so its goroutine exits
// rather than spinning for the rest of the sweep.
func perFixtureTimeout() time.Duration {
	if ms := os.Getenv("BALL_TIMEOUT_MS"); ms != "" {
		if n, err := strconv.Atoi(ms); err == nil && n > 0 {
			return time.Duration(n) * time.Millisecond
		}
	}
	return 120 * time.Second
}

// hardDeadlineGrace is how much longer runOne waits past the cooperative budget
// before falling back to the select backstop. In the flat-stack runaway case
// (an infinite while/for) the engine self-aborts at the budget, delivers its
// timeout on the buffered channel, and the goroutine exits — well before this
// grace elapses. The backstop fires for the runaways the cooperative guard does
// NOT reliably stop: (a) a native loop inside a runtime helper, which never
// returns to an expression eval, and (b) unbounded-stack Ball RECURSION, whose
// per-level guard checks were observed not to abort within the budget. In both
// cases Go cannot kill the goroutine in-process, so it keeps spinning (leaks)
// after the backstop reports the timeout — and unbounded recursion additionally
// risks a fatal Go stack overflow under the driver's 1 GiB stack ceiling, which
// would kill the whole sweep binary. Only flat-stack runaways are truly
// self-aborting; the backstop keeps the sweep moving for the rest.
const hardDeadlineGrace = 10 * time.Second

// isExecutionTimeout reports whether err is the compiled engine's cooperative
// execution-timeout self-abort (BallRuntimeError('Execution timeout exceeded'),
// surfaced through the driver's panic recovery). Such a fixture is reported as a
// "timeout", not a generic "error".
func isExecutionTimeout(err error) bool {
	return err != nil && strings.Contains(err.Error(), "Execution timeout exceeded")
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

	budget := perFixtureTimeout()

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
		// Drive the compiled engine's cooperative execution-timeout guard so a
		// runaway fixture self-aborts (and this goroutine then exits) instead of
		// spinning for the rest of the sweep — Go cannot kill a goroutine, so the
		// select backstop below alone would leak it (issue #436).
		eng.TimeoutMs = budget.Milliseconds()
		out, err := eng.Run()
		ch <- outcome{out, err}
	}()

	select {
	case res := <-ch:
		if res.err != nil {
			// A cooperative self-abort at the budget reports as a timeout, not a
			// generic error; the goroutine has already exited by the time we get
			// here (it delivered on the buffered channel).
			if isExecutionTimeout(res.err) {
				return Result{name, "timeout", ""}
			}
			return Result{name, "error", firstLine(res.err.Error())}
		}
		actual := strings.TrimRight(strings.Join(res.out, "\n"), "\n\r")
		expected := strings.TrimRight(strings.ReplaceAll(golden, "\r\n", "\n"), "\n")
		if actual == expected {
			return Result{name, "pass", ""}
		}
		return Result{name, "fail", diffDetail(expected, actual)}
	case <-time.After(budget + hardDeadlineGrace):
		// Backstop: the cooperative guard did not abort in time. This happens for
		// a native loop inside a runtime helper (never returns to an expression
		// eval) AND for unbounded-stack Ball recursion (guard checks run but were
		// observed not to abort within the budget). Report the timeout and move
		// on — but this goroutine is still running and LEAKS (Go cannot kill it),
		// and a recursing one may yet fatal the sweep via Go stack overflow. Only
		// flat-stack runaways (while/for) are reliably self-aborted upstream.
		return Result{name, "timeout", "cooperative timeout not observed"}
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
