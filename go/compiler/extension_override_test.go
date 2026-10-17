package compiler_test

// Extension-override dispatch (issue #670, fixture
// `480_extension_override_selection`).
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

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

func TestExtensionOverrideCallsTheNamedMemberImpl(t *testing.T) {
	prog := load(t, conformancePath("480_extension_override_selection.ball.json"))
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
	if want := readGolden(t, "480_extension_override_selection.expected_output.txt"); got != want {
		t.Errorf("480: got %q, want %q", got, want)
	}
}

// A READ through an override of a member that has BOTH a getter and a setter
// must call the GETTER (PR #829 review, round 2).
//
// A Dart `get label` and its `set label(v)` share ONE qualified Ball function
// name (`main:AlphaTag.label`) — only `metadata.is_getter`/`is_setter` tells
// them apart — and `extensionMemberImpl` is keyed by that qualified name. Once
// #813 gave the setter its own `__set` impl, filling the table per member let
// whichever accessor was indexed LAST win the slot, and every real extension
// declares `get` before `set`: the read `AlphaTag(xs).label` compiled to
// `AlphaTag__label__set(...)` and printed the setter's answer, with no error.
// (Before #813 the same program failed LOUD on a duplicate Go func.)
//
// The fixture carries no setter arm (#865 item 3 — no compiler but Dart can
// emit an override WRITE yet), so the setters are spliced into 480's own IR
// next to its getters, each answering "SETTER" so a mis-dispatched read is
// visible in the output. Both orders are pinned: the table must not depend on
// which accessor the program happens to declare first.
func TestExtensionOverrideReadOfAGetterSetterPairCallsTheGetter(t *testing.T) {
	for _, tc := range []struct {
		name         string
		setterBefore bool
	}{
		{"setter declared after its getter (the encoder's order)", false},
		{"setter declared before its getter", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			prog := load(t, conformancePath("480_extension_override_selection.ball.json"))
			spliced := 0
			for _, m := range prog.GetModules() {
				if m.GetName() != "main" {
					continue
				}
				var fns []*ballv1.FunctionDefinition
				for _, f := range m.GetFunctions() {
					if f.GetName() != "main:AlphaTag.label" && f.GetName() != "main:BetaTag.label" {
						fns = append(fns, f)
						continue
					}
					setter := extensionSetter(f.GetName())
					if tc.setterBefore {
						fns = append(fns, setter, f)
					} else {
						fns = append(fns, f, setter)
					}
					spliced++
				}
				m.Functions = fns
			}
			if spliced != 2 {
				t.Fatalf("480 no longer declares both label getters: spliced %d setters, want 2", spliced)
			}

			src := compileFmt(t, prog)
			// The setters are still EMITTED, under their own names — the getter
			// winning the read must not cost the setter its declaration.
			for _, decl := range []string{"func AlphaTag__label__set(", "func BetaTag__label__set("} {
				if !strings.Contains(src, decl) {
					t.Errorf("emitted Go never declares %s\n---\n%s", decl, src)
				}
			}
			// ...but no read in the entry function reaches one.
			if idx := strings.Index(src, "func main()"); idx < 0 {
				t.Fatalf("no func main() in emitted Go\n---\n%s", src)
			} else if strings.Contains(src[idx:], "__label__set(") {
				t.Errorf("a READ through the override calls the SETTER impl\n---\n%s", src[idx:])
			}

			got := goRun(t, src)
			if want := readGolden(t, "480_extension_override_selection.expected_output.txt"); got != want {
				t.Errorf("got %q, want %q (a read dispatched to the setter prints SETTER)", got, want)
			}
		})
	}
}

// A read naming a SETTER-ONLY extension member is not valid Dart, so it can
// only come from hand-built IR — and it must stay LOUD: routing it to the
// setter impl would run the setter with a null value and answer whatever the
// setter returns. With setters kept out of the call table, the read falls
// through to `ballrt.CallMethod`, whose unknown-name arm panics naming the
// method. Here 480's `AlphaTag.label` getter is turned into a setter, so the
// fixture's own `AlphaTag(xs).label` read names a member with no getter.
func TestExtensionOverrideReadOfASetterOnlyMemberNeverCallsTheSetter(t *testing.T) {
	prog := load(t, conformancePath("480_extension_override_selection.ball.json"))
	turned := false
	for _, m := range prog.GetModules() {
		if m.GetName() != "main" {
			continue
		}
		for i, f := range m.GetFunctions() {
			if f.GetName() == "main:AlphaTag.label" {
				m.Functions[i] = extensionSetter(f.GetName())
				turned = true
			}
		}
	}
	if !turned {
		t.Fatal("480 no longer declares main:AlphaTag.label")
	}

	src := compileFmt(t, prog)
	idx := strings.Index(src, "func main()")
	if idx < 0 {
		t.Fatalf("no func main() in emitted Go\n---\n%s", src)
	}
	entry := src[idx:]
	if strings.Contains(entry, "AlphaTag__label__set(") {
		t.Errorf("a READ of a setter-only member calls the SETTER impl\n---\n%s", entry)
	}
	if !strings.Contains(entry, `ballrt.CallMethod("main:AlphaTag.label"`) {
		t.Errorf("a READ of a setter-only member must reach ballrt.CallMethod's loud unknown-method arm\n---\n%s", entry)
	}
	// The untouched BetaTag getter still dispatches to its own impl.
	if !strings.Contains(entry, "BetaTag__label(") {
		t.Errorf("BetaTag(xs).label no longer reaches its getter impl\n---\n%s", entry)
	}
}

// extensionSetter is the setter the Dart encoder emits for
// `set label(String value) { … }` on an extension: the getter's qualified
// name, `is_setter`, and one declared parameter. Its body answers "SETTER" so
// a read that reaches it is visible in the program's output.
func extensionSetter(name string) *ballv1.FunctionDefinition {
	return &ballv1.FunctionDefinition{
		Name:       name,
		InputType:  "String",
		OutputType: "void",
		Body: &ballv1.Expression{Expr: &ballv1.Expression_Literal{
			Literal: &ballv1.Literal{Value: &ballv1.Literal_StringValue{StringValue: "SETTER"}}}},
		Metadata: metaStruct(map[string]any{
			"kind":            "method",
			"is_setter":       true,
			"expression_body": true,
			"params":          []any{map[string]any{"name": "value", "type": "String"}},
		}),
	}
}
