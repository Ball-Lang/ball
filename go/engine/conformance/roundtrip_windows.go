package conformance

import (
	"os/exec"
	"strconv"
)

// setProcessGroup is a no-op on Windows: there is no setpgid-equivalent flag
// that changes how killProcessTree targets the tree — it walks the
// OS-recorded parent-pid chain directly via `taskkill /T`, which needs no
// spawn-time setup.
func setProcessGroup(cmd *exec.Cmd) {}

// killProcessTree asks Windows to end cmd's immediate child AND every
// process it recorded as a descendant (issue #862, the Go leg's half of
// #791). `taskkill /T` is the documented way to walk that parent-pid chain —
// the same spelling rust/engine/tests/roundtrip_conformance.rs's
// kill_process_tree and python/engine/conformance/roundtrip.py's
// _kill_process_tree use on this platform.
func killProcessTree(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	_ = exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid)).Run()
	_ = cmd.Process.Kill()
}
