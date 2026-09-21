package conformance

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// The round-trip leg's per-fixture kill must actually END the fixture.
//
// `roundTripOne` runs the Dart reference engine OUT of process with `cmd.Stdout`
// set to an io.Writer, so os/exec pipes the child and copies in a goroutine —
// and `cmd.Wait` does not return until that copy ends, which needs EVERY holder
// of the pipe's write end closed, the killed process's own descendants included.
// Killing the child is therefore not enough: one surviving grandchild makes the
// `<-done` after `Kill` block forever, the sweep never reaches its `Results:`
// line, and the CI row dies on the job's `timeout-minutes` instead of reporting
// a timeout. docs/TESTING_STRATEGY.md §2c item 6 calls that a defect in the
// harness itself, and it was live here until `cmd.WaitDelay` was set — it
// surfaced the moment issue #691 made enough fixtures re-encode for one of them
// to reach the engine and not terminate.
//
// This is the negative control: a stand-in `dart` that starts a grandchild
// inheriting stdout and then blocks, i.e. the exact shape. The test fails if the
// leg does not come back well inside the grandchild's lifetime.

// roundTripHelperEnv switches this test binary into one of the helper roles
// below instead of running tests. Re-executing the test binary is the standard
// os/exec testing idiom and keeps the control toolchain-free.
const roundTripHelperEnv = "BALL_ROUNDTRIP_TEST_HELPER"

// helperHoldsPipeFor is how long the grandchild keeps the inherited stdout pipe
// open. It must comfortably outlive the assertion window below, or the control
// would pass even with no WaitDelay at all.
const helperHoldsPipeFor = 30 * time.Second

// TestMain routes the helper roles. With the env var unset it is an ordinary
// test run.
func TestMain(m *testing.M) {
	switch os.Getenv(roundTripHelperEnv) {
	case "hang":
		// The stand-in `dart`: hand our stdout to a grandchild that outlives us,
		// then block. Killing this process leaves the pipe's write end open.
		holder := exec.Command(os.Args[0])
		holder.Env = append(os.Environ(), roundTripHelperEnv+"=holder")
		holder.Stdout = os.Stdout
		holder.Stderr = os.Stderr
		_ = holder.Start()
		time.Sleep(helperHoldsPipeFor)
		os.Exit(0)
	case "holder":
		time.Sleep(helperHoldsPipeFor)
		os.Exit(0)
	default:
		os.Exit(m.Run())
	}
}

func TestRoundTripKillReturnsEvenWhenAGrandchildHoldsThePipe(t *testing.T) {
	t.Setenv("BALL_TIMEOUT_MS", "500")
	// The leg starts its `dart` with this process's environment, so setting the
	// role here is what makes the stand-in behave as the runaway.
	t.Setenv(roundTripHelperEnv, "hang")

	dir, err := conformanceDir()
	if err != nil {
		t.Fatalf("locate the conformance corpus: %v", err)
	}
	fixture := filepath.Join(dir, "265_enc_hello.ball.json")
	if _, err := os.Stat(fixture); err != nil {
		t.Fatalf("the fixture this control compiles is missing: %v", err)
	}

	workdir, err := os.MkdirTemp("", "ball_roundtrip_control_")
	if err != nil {
		t.Fatalf("workdir: %v", err)
	}
	defer os.RemoveAll(workdir)

	// The helper processes are still alive when this test returns, so neither the
	// binary they run nor the directory they sit in may be anything the test
	// framework cleans up: on Windows a running image is locked and `t.TempDir`'s
	// RemoveAll (and `go test`'s own unlink of the test binary) then fails. Run a
	// COPY, out of a directory deliberately left behind for the OS to reap, and
	// give the leg an existing directory it does not own as the working dir.
	start := time.Now()
	res := roundTripOne("hang_control", fixture, "irrelevant golden",
		helperBinary(t), "unused.dart", os.TempDir(), workdir)
	elapsed := time.Since(start)

	if res.Status != "timeout" {
		t.Fatalf("a non-terminating fixture reported status %q (detail %q), want \"timeout\"",
			res.Status, res.Detail)
	}
	// The grandchild holds the pipe for helperHoldsPipeFor. Coming back inside a
	// fraction of that is the whole proof: without the WaitDelay bound, Wait
	// blocks until the grandchild exits — or forever, for a real runaway.
	if elapsed >= helperHoldsPipeFor/3 {
		t.Fatalf("the leg took %v to report the timeout — Wait blocked on the "+
			"grandchild's copy of the stdout pipe instead of being bounded by "+
			"cmd.WaitDelay", elapsed)
	}
}

// helperBinary copies this test binary somewhere the test framework will not try
// to delete, and returns the copy's path. See the comment at its call site for
// why a copy is required.
func helperBinary(t *testing.T) string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatalf("locate the test binary: %v", err)
	}
	body, err := os.ReadFile(self)
	if err != nil {
		t.Fatalf("read the test binary: %v", err)
	}
	dir, err := os.MkdirTemp("", "ball_roundtrip_helper_")
	if err != nil {
		t.Fatalf("helper dir: %v", err)
	}
	name := "dart"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, body, 0o755); err != nil {
		t.Fatalf("write the helper binary: %v", err)
	}
	return path
}
