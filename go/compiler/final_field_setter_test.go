package compiler_test

// A `final` field a BODYLESS constructor's own initializer list assigns, next
// to a user-written setter of the same name (issue #706, fixture
// 472_initializer_list_field_with_setter).
//
// ── The mechanism, measured ─────────────────────────────────────────────────
//
// `indexConstructors` recorded a class's UNNAMED constructor only when it
// carried a BODY, and `compileMessageCreation` invokes the constructor impl
// only for a class that has such a recording. A bodyless
// `FixedSlice(this.source, int end) : windowSize = end;` therefore took the
// inline-field-map path, which knows `metadata.params` (the `this.`-formals)
// but NOT `metadata.initializers` — so the emitted instance carried the
// constructor's plain parameter `end` as a bogus field and never carried
// `windowSize` at all. `print(slice.windowSize)` then read a missing key and
// printed `null`: a SILENT WRONG ANSWER, not a build failure.
//
// Note what the mechanism is NOT: issue #706 hypothesised that "the emitted
// setter shadows the field read". It does not. Go emits the setter as the
// free function `windowSize(input)` and the read as
// `ballrt.FieldGet(slice, "windowSize")` — two different namespaces that never
// meet. Dropping the initializer list is the whole of it, and it bites every
// bodyless constructor with an initializer list, setter or no setter (the
// second test below pins exactly that, with no setter in sight).
//
// These are PR-gated (`go test ./compiler/...` in ci.yml's `go` job). The
// whole-corpus `go-compiler` leg that would also have measured this lives only
// in conformance-matrix.yml, which has no `pull_request:` trigger and is a
// RATCHET on an aggregate count — it fails only on a DROP, so it was green with
// this fixture failing and stays green now that it passes. Read the per-fixture
// line, never the leg's colour.

import (
	"strings"
	"testing"
)

// TestFinalFieldWithSetterReadsBackItsInitializedValue is the field-READ pin:
// the fixture's `print(slice.windowSize)` must print 3, never `null`.
func TestFinalFieldWithSetterReadsBackItsInitializedValue(t *testing.T) {
	prog := load(t, conformancePath("472_initializer_list_field_with_setter.ball.json"))
	src := compileFmt(t, prog)

	// The construction site must INVOKE the constructor impl — the only place
	// the initializer list is applied — never build the instance inline.
	if !strings.Contains(src, "FixedSlice__new(") {
		t.Errorf("construction does not invoke the constructor impl\n---\n%s", src)
	}
	// The initializer list's field must be seeded from the constructor's own
	// parameter, and the parameter must NOT be grafted on as a field of its own.
	if !strings.Contains(src, `__fields.Set("windowSize", end)`) {
		t.Errorf("initializer list `windowSize = end` not applied\n---\n%s", src)
	}
	// ...and the plain (non-`this.`) parameter must NOT be grafted on as an
	// instance field of its own. `__fields` is the INSTANCE map the constructor
	// impl builds; `__m` is the ARGUMENT map the call site packs, where an
	// entry keyed by the parameter's own name is correct.
	if strings.Contains(src, `__fields.Set("end", `) {
		t.Errorf("constructor parameter `end` emitted as an instance field\n---\n%s", src)
	}

	got := goRun(t, src)
	if want := readGolden(t, "472_initializer_list_field_with_setter.expected_output.txt"); got != want {
		t.Errorf("472: got %q, want %q", got, want)
	}
}

// TestBodylessConstructorInitializerListIsApplied pins the mechanism WITHOUT a
// setter anywhere: a bodyless constructor's initializer list is dropped on its
// own, so a fix that special-cased "field with a same-named setter" would be
// treating the symptom. 470_setter_beside_final_field is the same class shape
// with the setter actually CALLED; it exercises live setter dispatch on a field
// read/write pair, which is a separate target gap (#664's write side) — so this
// test uses 438, whose constructor carries a body, as the control: it passed
// before this fix and must keep passing.
func TestBodyCarryingConstructorInitializerListStillApplied(t *testing.T) {
	prog := load(t, conformancePath("438_ctor_initializer_list_with_body.ball.json"))
	src := compileFmt(t, prog)
	got := goRun(t, src)
	if want := readGolden(t, "438_ctor_initializer_list_with_body.expected_output.txt"); got != want {
		t.Errorf("438: got %q, want %q", got, want)
	}
}
