//go:build unix

package conformance

import (
	"os/exec"
	"syscall"
)

// setProcessGroup makes cmd's child the leader of its own process group, so
// killProcessTree below can reach every descendant it forks. This has to
// happen at SPAWN time, via SysProcAttr — a group cannot be imposed on a
// process that is already running.
func setProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killProcessTree kills the whole process GROUP setProcessGroup put the
// child in — the `dart` launcher AND the Dart VM it forks, the real shape of
// a round-trip fixture's process tree (issue #862, the Go leg's half of
// #791: csharp/engine/conformance/RoundTripLeg.cs and the Rust/Python legs
// all kill the tree already). `syscall.Kill` with a NEGATED pid targets the
// whole group that pid leads; `cmd.Process.Kill()` is an unconditional
// backstop for the immediate child, mirroring
// rust/engine/tests/roundtrip_conformance.rs's kill_process_tree.
func killProcessTree(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}
