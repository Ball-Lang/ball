// Package conformance is the Ball → Go *compiler* conformance leg: it sweeps the
// whole tests/conformance corpus through go/compiler (Ball → Go source), builds
// and runs each emitted program with the real Go toolchain, and byte-compares
// stdout to the fixture's .expected_output.txt golden.
//
// This is the compile-side sibling of go/engine/conformance (which measures the
// self-hosted *engine*). The two legs measure different claims: the engine leg
// says "the compiled self-hosted engine interprets this program correctly", this
// leg says "the Ball → Go compiler emits Go that prints the right answer".
//
// Honest counting (issue #55): a fixture the compiler cannot emit — an
// unsupported construct, invalid emitted Go, a non-zero exit, a runaway loop —
// is a FAILURE, never a skip and never a crash that aborts the sweep. The only
// skips are the 4 documented golden-less carve-outs (196_timeout, 197_memory_limit,
// 201_input_validation, 202_sandbox_mode), which every runner in the repo skips.
//
// No `selfhost` build tag is needed: this leg never touches the compiled engine.
package conformance

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ball-lang/ball/go/compiler"
)

// perFixtureTimeout bounds each fixture's *execution* so a latent infinite loop
// cannot wedge the whole sweep (the 120 s budget go/engine/conformance uses).
// Override with BALL_TIMEOUT_MS for faster iteration sweeps. Unlike the engine
// leg — which must ask the in-process engine to self-abort, because Go cannot
// kill a goroutine — a compiled fixture is a separate OS process, so the budget
// is enforced by killing it. Nothing leaks.
func perFixtureTimeout() time.Duration {
	if ms := os.Getenv("BALL_TIMEOUT_MS"); ms != "" {
		if n, err := strconv.Atoi(ms); err == nil && n > 0 {
			return time.Duration(n) * time.Millisecond
		}
	}
	return 120 * time.Second
}

// buildTimeout bounds `go build` of one emitted program. Generous because the
// first build in a cold cache also compiles the ballrt runtime module.
func buildTimeout() time.Duration {
	if ms := os.Getenv("BALL_BUILD_TIMEOUT_MS"); ms != "" {
		if n, err := strconv.Atoi(ms); err == nil && n > 0 {
			return time.Duration(n) * time.Millisecond
		}
	}
	return 180 * time.Second
}

// Result is one fixture's outcome.
type Result struct {
	Name   string
	Status string // "pass", "fail", "timeout", "error"
	Detail string
}

// Summary is a whole-corpus sweep outcome. Every non-pass counts in Failed.
type Summary struct {
	Passed  int
	Failed  int
	Total   int
	Skipped int // golden-less carve-outs
	Results []Result
}

// RunAll compiles every tests/conformance/*.ball.json fixture to Go, builds and
// runs it, and compares stdout to its .expected_output.txt golden. A fixture with
// no golden is a documented carve-out and is skipped. If onlyFixture is non-empty,
// only that fixture runs.
func RunAll(onlyFixture string) (Summary, error) {
	dir, err := conformanceDir()
	if err != nil {
		return Summary{}, fmt.Errorf("locate tests/conformance: %w", err)
	}
	rtDir, err := runtimeDir(dir)
	if err != nil {
		return Summary{}, err
	}

	entries, err := filepath.Glob(filepath.Join(dir, "*.ball.json"))
	if err != nil {
		return Summary{}, err
	}
	sort.Strings(entries)

	work, err := os.MkdirTemp("", "ballgo-compile-leg-")
	if err != nil {
		return Summary{}, err
	}
	defer os.RemoveAll(work)
	if err := writeWorkspace(work, rtDir); err != nil {
		return Summary{}, err
	}

	// Collect the jobs first so the worker pool sees a stable, sorted list.
	type job struct{ name, path, golden string }
	var jobs []job
	var s Summary
	for _, path := range entries {
		name := strings.TrimSuffix(filepath.Base(path), ".ball.json")
		if onlyFixture != "" && name != onlyFixture {
			continue
		}
		goldenPath := strings.TrimSuffix(path, ".ball.json") + ".expected_output.txt"
		golden, gerr := os.ReadFile(goldenPath)
		if gerr != nil {
			// Golden-less carve-out: behavioral (timeout / memory limit / input
			// validation / sandbox), skipped by every runner in the repo.
			s.Skipped++
			continue
		}
		jobs = append(jobs, job{name, path, string(golden)})
	}

	// Positive floor: a sweep that discovered nothing must not report a serene
	// "0 passed, 0 failed" — that reads as green to a human and to CI. An empty
	// job list means a broken fixture path or a misspelled BALL_FIXTURE, which is
	// an error, not a result.
	if len(jobs) == 0 {
		if onlyFixture != "" {
			return Summary{}, fmt.Errorf("no fixture named %q in %s", onlyFixture, dir)
		}
		return Summary{}, fmt.Errorf("no *.ball.json fixtures with goldens found in %s", dir)
	}

	// Warm the module cache serially with the first job so the parallel workers
	// below do not each pay for compiling ballrt from scratch.
	results := make([]Result, len(jobs))
	start := 0
	if len(jobs) > 0 {
		results[0] = runOne(jobs[0].name, jobs[0].path, jobs[0].golden, work)
		start = 1
	}

	workers := runtime.NumCPU()
	if workers > 8 {
		workers = 8
	}
	if workers < 1 {
		workers = 1
	}
	var wg sync.WaitGroup
	ch := make(chan int)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range ch {
				results[i] = runOne(jobs[i].name, jobs[i].path, jobs[i].golden, work)
			}
		}()
	}
	for i := start; i < len(jobs); i++ {
		ch <- i
	}
	close(ch)
	wg.Wait()

	for _, r := range results {
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

// runOne compiles, builds and runs a single fixture. Every failure mode returns a
// Result — it never panics out (a compiler panic on an unhandled shape is
// recovered and reported as that fixture's error), so one bad fixture cannot take
// the sweep down and inflate the pass rate by shrinking the denominator.
func runOne(name, path, golden, work string) Result {
	src, err := emit(path)
	if err != nil {
		return Result{name, "error", "compile: " + firstLine(err.Error())}
	}

	dir := filepath.Join(work, sanitize(name))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Result{name, "error", "mkdir: " + err.Error()}
	}
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte(src), 0o644); err != nil {
		return Result{name, "error", "write: " + err.Error()}
	}

	bin := filepath.Join(dir, "prog"+exeSuffix())
	if out, err := run(dir, buildTimeout(), goExe(), "build", "-o", bin, "."); err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return Result{name, "timeout", "go build exceeded budget"}
		}
		return Result{name, "error", "build: " + firstLine(strings.TrimSpace(out.stderr))}
	}

	out, err := run(dir, perFixtureTimeout(), bin)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return Result{name, "timeout", ""}
		}
		detail := firstLine(strings.TrimSpace(out.stderr))
		if detail == "" {
			detail = err.Error()
		}
		return Result{name, "error", "run: " + detail}
	}

	actual := normalize(out.stdout)
	expected := normalize(golden)
	if actual == expected {
		return Result{name, "pass", ""}
	}
	return Result{name, "fail", diffDetail(expected, actual)}
}

// emit loads the fixture and compiles it to formatted Go. A compiler panic on an
// unhandled shape is recovered into an error: an honest failure for that fixture.
func emit(path string) (src string, err error) {
	defer func() {
		if r := recover(); r != nil {
			src, err = "", fmt.Errorf("panic: %v", r)
		}
	}()
	prog, err := compiler.LoadProgramFile(path)
	if err != nil {
		return "", err
	}
	src, cerr := compiler.Compile(prog)
	if cerr != nil {
		return "", cerr
	}
	// Formatting is cosmetic; if it fails the emitted Go is invalid and `go build`
	// will say so with a better message than gofmt would.
	if formatted, ferr := compiler.Format(src); ferr == nil {
		src = formatted
	}
	return src, nil
}

type captured struct{ stdout, stderr string }

// run executes a command with a hard timeout, killing the process when it
// expires. Returns context.DeadlineExceeded (wrapped) on timeout.
func run(dir string, budget time.Duration, name string, args ...string) (captured, error) {
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	// GOWORK=off so the throwaway module resolves standalone (it is not in
	// go/go.work); GOPROXY=off because ballrt has zero external dependencies, so a
	// build that reaches for the network is a bug, not something to wait on.
	cmd.Env = append(os.Environ(), "GOWORK=off", "GOFLAGS=", "GOPROXY=off")
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	got := captured{stdout.String(), stderr.String()}
	if ctx.Err() != nil {
		return got, fmt.Errorf("%s: %w", name, context.DeadlineExceeded)
	}
	return got, err
}

// writeWorkspace lays down the throwaway module every fixture package lives in:
// one module, one local replace of go/runtime, so the 320 builds share a module
// resolution and a build cache instead of each paying for their own.
func writeWorkspace(dir, rtDir string) error {
	gomod := "module ballgocompileleg\n\ngo 1.23\n\n" +
		"require github.com/ball-lang/ball/go/runtime v0.0.0\n\n" +
		"replace github.com/ball-lang/ball/go/runtime => " + filepath.ToSlash(rtDir) + "\n"
	return os.WriteFile(filepath.Join(dir, "go.mod"), []byte(gomod), 0o644)
}

func normalize(s string) string {
	return strings.TrimRight(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
}

func diffDetail(expected, actual string) string {
	el := strings.Split(expected, "\n")
	al := strings.Split(actual, "\n")
	if os.Getenv("BALL_FIXTURE") != "" {
		return "\n--- expected (" + strconv.Itoa(len(el)) + ") ---\n" + expected +
			"\n--- actual (" + strconv.Itoa(len(al)) + ") ---\n" + actual
	}
	return "expected(" + strconv.Itoa(len(el)) + "): " + first(el) +
		" | actual(" + strconv.Itoa(len(al)) + "): " + first(al)
}

func first(xs []string) string {
	if len(xs) == 0 || xs[0] == "" {
		return "<none>"
	}
	return xs[0]
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimRight(s[:i], "\r")
	}
	return s
}

// sanitize makes a fixture name safe as a Go package directory name.
func sanitize(name string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_':
			return r
		default:
			return '_'
		}
	}, name)
}

func goExe() string {
	if p, err := exec.LookPath("go"); err == nil {
		return p
	}
	return "go"
}

func exeSuffix() string {
	if runtime.GOOS == "windows" {
		return ".exe"
	}
	return ""
}

// conformanceDir walks up from the working directory to the repo root and returns
// tests/conformance.
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

// runtimeDir resolves go/runtime from the repo root (the parent of tests/).
func runtimeDir(confDir string) (string, error) {
	root := filepath.Dir(filepath.Dir(confDir))
	rt := filepath.Join(root, "go", "runtime")
	if fi, err := os.Stat(filepath.Join(rt, "go.mod")); err != nil || fi.IsDir() {
		return "", fmt.Errorf("go/runtime module not found at %s", rt)
	}
	return filepath.Abs(rt)
}
