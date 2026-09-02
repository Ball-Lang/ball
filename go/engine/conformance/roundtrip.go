package conformance

// Whole-corpus ROUND-TRIP leg for the Go target (issue #452 item 3).
//
// The engine leg (runner.go, `-tags selfhost`) sweeps the corpus through the
// self-hosted Go engine. This is a different question: **can the Go encoder read
// back what the Go compiler emits?**
//
// Per fixture:
//
//  1. compiler.LoadProgramFile + compiler.Compile -> Go source (go/compiler).
//  2. encoder.Encode that source back into a Ball program (go/encoder).
//  3. Run the RE-ENCODED program on the DART reference engine
//     (`dart run dart/cli/bin/ball.dart run <reencoded.ball.json>`). Ground
//     truth on purpose: running it on Go's own engine would only prove the Go
//     pipeline agrees with itself.
//  4. Byte-compare stdout to the fixture's .expected_output.txt golden.
//
// A near-zero baseline is the honest, expected answer, not a bug: the compiler
// emits a flat package dispatching through ballrt.* helpers over ballrt.Value,
// while the encoder is a syntactic go/ast reader built for idiomatic
// hand-written Go. Neither was designed to meet in the middle. The C# analogue
// (csharp/engine/conformance/RoundTripLeg.cs, the row this leg mirrors) measures
// exactly 0. This leg keeps that number live and honest; raising it is
// encoder/compiler work tracked elsewhere.
//
// **No PR gate.** The `go-roundtrip` row lives in
// .github/workflows/conformance-matrix.yml, which has NO pull_request trigger —
// it runs on push-to-main, the weekly schedule, or manual dispatch. An absent
// check on a PR is not a green one.
//
// Deliberately NOT behind the `selfhost` build tag (unlike runner.go): this leg
// never touches the compiled engine, so it must not require the gitignored,
// regenerated compiled_engine.go to run.

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	compiler "github.com/ball-lang/ball/go/compiler"
	encoder "github.com/ball-lang/ball/go/encoder"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/encoding/protojson"
)

// roundTripTimeout bounds each fixture's Dart run so one runaway cannot wedge
// the sweep. Unlike the engine leg's cooperative guard, this is a real process
// kill: the Dart engine runs out-of-process here.
func roundTripTimeout() time.Duration {
	if ms := os.Getenv("BALL_TIMEOUT_MS"); ms != "" {
		if n, err := strconv.Atoi(ms); err == nil && n > 0 {
			return time.Duration(n) * time.Millisecond
		}
	}
	return 60 * time.Second
}

// dartExecutable is the Dart launcher used as ground truth. Override with
// BALL_DART (a full path, e.g. when `dart` is a shim not on PATH).
func dartExecutable() string {
	if d := os.Getenv("BALL_DART"); d != "" {
		return d
	}
	return "dart"
}

// RunRoundTrip drives every tests/conformance/*.ball.json fixture through
// compile -> re-encode -> Dart reference engine -> golden diff. A fixture with
// no golden is a documented carve-out and is skipped, exactly as every other
// runner skips them. If onlyFixture is non-empty, only that fixture runs.
//
// It returns an error only when the sweep itself could not run (no corpus, no
// Dart, zero fixtures) — never for a failing fixture, which is a counted result.
func RunRoundTrip(onlyFixture string) (Summary, error) {
	dir, err := conformanceDir()
	if err != nil {
		return Summary{}, err
	}
	repoRoot := filepath.Dir(filepath.Dir(dir)) // <root>/tests/conformance -> <root>
	ballDart := filepath.Join(repoRoot, "dart", "cli", "bin", "ball.dart")
	if _, err := os.Stat(ballDart); err != nil {
		return Summary{}, fmt.Errorf("the Dart reference CLI is required for the round-trip leg: %w", err)
	}
	dart, err := exec.LookPath(dartExecutable())
	if err != nil {
		return Summary{}, fmt.Errorf("the Dart reference engine is required for the round-trip leg but %q is not on PATH (set BALL_DART): %w", dartExecutable(), err)
	}

	entries, err := filepath.Glob(filepath.Join(dir, "*.ball.json"))
	if err != nil {
		return Summary{}, err
	}
	sort.Strings(entries)

	workdir, err := os.MkdirTemp("", "ball_go_roundtrip_")
	if err != nil {
		return Summary{}, err
	}
	defer os.RemoveAll(workdir)

	var s Summary
	for _, path := range entries {
		name := strings.TrimSuffix(filepath.Base(path), ".ball.json")
		goldenPath := strings.TrimSuffix(path, ".ball.json") + ".expected_output.txt"
		golden, gerr := os.ReadFile(goldenPath)
		if gerr != nil {
			s.Skipped++ // documented carve-out (no golden) — never counted
			continue
		}
		if onlyFixture != "" && name != onlyFixture {
			continue
		}
		r := roundTripOne(name, path, string(golden), dart, ballDart, repoRoot, workdir)
		s.Results = append(s.Results, r)
		s.Total++
		if r.Status == "pass" {
			s.Passed++
		} else {
			s.Failed++
		}
	}

	// Positive floor. A sweep that ran nothing would print "0 passed, 0 failed,
	// 0 total" and read as green — an exit code plus a failure count cannot tell
	// "all passed" from "nothing ran".
	if s.Total == 0 {
		return s, fmt.Errorf("the round-trip leg ran zero fixtures — refusing to report a vacuous pass (check BALL_FIXTURE)")
	}
	return s, nil
}

func roundTripOne(name, path, golden, dart, ballDart, repoRoot, workdir string) Result {
	// 1. Ball -> Go (fail-loud by design; a scope gap is a FAILURE here).
	prog, err := compiler.LoadProgramFile(path)
	if err != nil {
		return Result{name, "error", "load: " + firstLine(err.Error())}
	}
	source, err := compiler.Compile(prog)
	if err != nil {
		return Result{name, "compile-error", firstLine(err.Error())}
	}

	// 2. Go -> Ball (the step expected to reject compiler-emitted shapes today —
	//    that rejection is the measurement).
	reencoded, err := encoder.Encode(source)
	if err != nil {
		return Result{name, "encode-error", firstLine(err.Error())}
	}

	// 3. Serialize as the `@type`-enveloped .ball.json every Ball CLI reads.
	ballJSON := filepath.Join(workdir, name+".ball.json")
	if err := writeEnvelopedJSON(ballJSON, reencoded); err != nil {
		return Result{name, "error", "serialize: " + firstLine(err.Error())}
	}

	// 4. Run the RE-ENCODED program on the Dart reference engine (ground truth).
	timeout := roundTripTimeout()
	cmd := exec.Command(dart, "run", ballDart, "run", ballJSON)
	cmd.Dir = repoRoot
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return Result{name, "error", "dart exec: " + firstLine(err.Error())}
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case waitErr := <-done:
		actual := strings.TrimRight(strings.ReplaceAll(stdout.String(), "\r\n", "\n"), "\n")
		expected := strings.TrimRight(strings.ReplaceAll(golden, "\r\n", "\n"), "\n")
		if actual == expected {
			return Result{name, "pass", ""}
		}
		if waitErr != nil {
			detail := lastLine(strings.ReplaceAll(stderr.String(), "\r\n", "\n"))
			if detail == "" {
				detail = "dart run failed: " + firstLine(waitErr.Error())
			}
			return Result{name, "error", detail}
		}
		return Result{name, "fail", diffDetail(expected, actual)}
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		<-done
		return Result{name, "timeout", fmt.Sprintf("killed after %s", timeout)}
	}
}

// writeEnvelopedJSON renders prog as proto3 JSON inside the cosmetic "@type"
// google.protobuf.Any envelope every .ball.json carries — the same shape
// go/cli's programToJSON writes and every Ball loader accepts.
func writeEnvelopedJSON(path string, prog *ballv1.Program) error {
	body, err := protojson.Marshal(prog)
	if err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		return err
	}
	enveloped := map[string]json.RawMessage{
		"@type": json.RawMessage(`"type.googleapis.com/ball.v1.Program"`),
	}
	for k, v := range fields {
		enveloped[k] = v
	}
	out, err := json.Marshal(enveloped)
	if err != nil {
		return err
	}
	return os.WriteFile(path, out, 0o644)
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	return lines[len(lines)-1]
}
