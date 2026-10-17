package conformance

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
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
//
// Since #862, roundTripOne's timeout path kills the WHOLE process tree
// (killProcessTree), not just the launcher — so left as originally written,
// this control's grandchild would be killed by the tree kill too, the pipe
// would close on its own, and Wait would return promptly with cmd.WaitDelay
// never engaging at all: the mutation this test exists to catch (deleting
// `cmd.WaitDelay = 5 * time.Second`) would then go undetected. The test
// substitutes `killOnTimeout` with a LAUNCHER-ONLY kill (see its body) to
// reproduce the pre-#862 topology — a descendant the tree kill does not
// reach — so a prompt return can only be explained by cmd.WaitDelay itself.
// TestRoundTripKillEndsTheWholeProcessTree below is the separate control that
// the real, unmodified killProcessTree does reach the whole tree.

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
		// The grandchild. Its liveness is observable from the outside through a
		// heartbeat file it appends to every 50ms, beside the binary both it and
		// the "hang" role above run from (os.Args[0] is that same path in both
		// processes — see heartbeatPath). A file that stops growing is a process
		// that is gone: portable, and unlike a pid probe it cannot be confused by
		// pid reuse (os.FindProcess always succeeds on unix, and signal 0 on
		// Windows TERMINATES rather than probes). See
		// TestRoundTripKillEndsTheWholeProcessTree.
		heartbeat := heartbeatPath(os.Args[0])
		deadline := time.Now().Add(helperHoldsPipeFor)
		for time.Now().Before(deadline) {
			appendHeartbeat(heartbeat)
			time.Sleep(50 * time.Millisecond)
		}
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

	// Isolate cmd.WaitDelay from #862's tree kill: substitute a kill that reaches
	// only the immediate `dart` process (cmd.Process), exactly roundTripOne's
	// pre-#862 behavior, so the grandchild "holder" below survives the kill and
	// keeps holding the stdout pipe. If this test came back quickly ONLY because
	// killProcessTree also reached the grandchild, it would prove nothing about
	// cmd.WaitDelay — see the file-level comment above.
	prevKill := killOnTimeout
	killOnTimeout = func(cmd *exec.Cmd) {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	defer func() { killOnTimeout = prevKill }()

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

// heartbeatPath is where the "holder" role (TestMain) appends its liveness
// heartbeat: beside the binary it runs from, mirroring
// rust/engine/tests/roundtrip_conformance.rs's `heartbeat_path` (there,
// `with_extension`; here, replacing whatever extension the binary itself
// carries — none on unix, ".exe" on Windows).
func heartbeatPath(dartBinary string) string {
	return strings.TrimSuffix(dartBinary, filepath.Ext(dartBinary)) + ".heartbeat"
}

// appendHeartbeat appends one byte to path, creating it on the first call.
// Errors are swallowed: the caller (TestMain's "holder" role) runs inside a
// FORKED helper process, where there is no test framework left to report to,
// and a positive-floor assertion on the reading side is what catches a
// heartbeat that never got written at all.
func appendHeartbeat(path string) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	_, _ = f.WriteString(".")
	_ = f.Close()
}

// heartbeatLen is the heartbeat file's size, or 0 while it does not exist yet.
func heartbeatLen(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

// TestRoundTripKillEndsTheWholeProcessTree is the Go leg's negative control
// for issue #862 — the last of the four `*-roundtrip` legs with #791's gap.
//
// `dart run` is a LAUNCHER: it forks the Dart VM, and the VM is what actually
// executes the re-encoded program and holds the inherited stdout pipe.
// Before this fix, roundTripOne's timeout path called only
// `cmd.Process.Kill()`, which reaches the immediate `dart` process and
// nothing else — leaving that VM running, orphaned, in the CI runner for the
// rest of the job. `csharp/engine/conformance/RoundTripLeg.cs` has always
// called `Kill(entireProcessTree: true)`, and the Rust/Python legs acquired
// the same guarantee in #791 (process-group kill); this is the Go leg's.
//
// The assertion is about the GRANDCHILD surviving, not about the harness
// returning: TestRoundTripKillReturnsEvenWhenAGrandchildHoldsThePipe already
// proves the harness comes back promptly, and it did even before this fix —
// a harness that returns promptly and a grandchild that is still running are
// exactly the same observation, which is why that elapsed-time assertion
// could never have caught this gap on its own. Liveness is observed through
// the "holder" role's heartbeat file rather than a pid probe, which has no
// portable "is it still running" spelling (os.FindProcess always succeeds on
// unix even for a reaped pid, and Windows' signal 0 equivalent TERMINATES
// rather than probes).
func TestRoundTripKillEndsTheWholeProcessTree(t *testing.T) {
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

	workdir, err := os.MkdirTemp("", "ball_roundtrip_tree_control_")
	if err != nil {
		t.Fatalf("workdir: %v", err)
	}
	defer os.RemoveAll(workdir)

	// Same reasoning as helperBinary's own call site: the helper processes may
	// still be shutting down when this test returns, so run a COPY out of a
	// directory the test framework never tries to clean up.
	dartBinary := helperBinary(t)
	heartbeat := heartbeatPath(dartBinary)
	_ = os.Remove(heartbeat) // a leftover from a previous run must not be read as "still alive"

	res := roundTripOne("tree_control", fixture, "irrelevant golden",
		dartBinary, "unused.dart", os.TempDir(), workdir)

	if res.Status != "timeout" {
		t.Fatalf("a non-terminating fixture reported status %q (detail %q), want \"timeout\"",
			res.Status, res.Detail)
	}

	// Let any write already in flight when the kill landed settle.
	time.Sleep(750 * time.Millisecond)
	first := heartbeatLen(heartbeat)
	// POSITIVE FLOOR. Without it a control that never managed to fork a
	// grandchild — a sandbox that forbids the spawn, a build quirk — would
	// report a frozen, zero-length heartbeat and pass while proving nothing at
	// all about the kill.
	if first == 0 {
		t.Fatalf("the stand-in never wrote a heartbeat (%s), so this run fabricated no live "+
			"grandchild and proves nothing about the kill", heartbeat)
	}

	// A live grandchild appends every 50ms (see TestMain's "holder" role), so
	// ~30 more bytes land in this window. A heartbeat that has not moved is a
	// process that is gone.
	time.Sleep(1500 * time.Millisecond)
	second := heartbeatLen(heartbeat)
	if first != second {
		t.Fatalf("the timed-out fixture's GRANDCHILD is still running: its heartbeat grew from "+
			"%d to %d bytes 1.5s after the harness reported the timeout. The kill reached only "+
			"the immediate `dart` process, so a real sweep leaks one orphaned Dart VM per "+
			"timed-out fixture (issue #862)", first, second)
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
