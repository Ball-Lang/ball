package compiler_test

// Extension-override dispatch (issue #670, fixture
// `478_extension_override_selection`).
//
// `Ext(receiver).member` is encoded as a call NAMING the extension's own
// member (`<module>:<Ext>.<member>`) with the receiver in `self`, because the
// selection is the whole meaning of the node: two extensions can declare the
// SAME member on the SAME type, and the plain `receiver.member` emission
// resolves by ordinary lookup — a DIFFERENT member.
//
// Go emits each extension member as a free impl func (`AlphaTag__tag`) plus a
// short-named DISPATCHER (`tag`) that switches on the RECEIVER's message type.
// An extension receiver is an ordinary list, so that dispatcher can never pick
// between the two; the qualified name also sanitizes to no Go identifier the
// program declares, so the call fell through to `ballrt.CallMethod`, the
// Dart-SDK method dispatcher, which knows no method called
// `main:AlphaTag.tag`.
//
// These run on EVERY PR (`go test ./compiler/...` in ci.yml's `go` job). The
// whole-corpus `go-compiler` leg lives only in conformance-matrix.yml, which
// has no `pull_request:` trigger and RATCHETS an aggregate count — it fails
// only on a DROP, so it was green with this fixture failing.

import (
	"strings"
	"testing"
)

func TestExtensionOverrideCallsTheNamedMemberImpl(t *testing.T) {
	prog := load(t, conformancePath("478_extension_override_selection.ball.json"))
	src := compileFmt(t, prog)

	// Each of the six overrides must reach the extension's own impl.
	for _, impl := range []string{
		"AlphaTag__tag(", "BetaTag__tag(",
		"AlphaTag__label(", "BetaTag__label(",
		"AlphaTag__scale(", "BetaTag__scale(",
	} {
		if !strings.Contains(src, impl) {
			t.Errorf("emitted Go never calls %s\n---\n%s", impl, src)
		}
	}
	// ...and none of them may go through the receiver-asking dispatcher, which
	// cannot tell the two extensions apart.
	if strings.Contains(src, `ballrt.CallMethod("main:`) {
		t.Errorf("an extension override still dispatches dynamically\n---\n%s", src)
	}

	got := goRun(t, src)
	if want := readGolden(t, "478_extension_override_selection.expected_output.txt"); got != want {
		t.Errorf("478: got %q, want %q", got, want)
	}
}
