package ballrt

import "testing"

// TestSinkIsATaggedReferenceValue pins the two properties of the declared text
// sink (issue #630) that fail SILENTLY when a target gets them wrong.
//
//  1. `std.type_of` answers "Sink" — not the host type. A backing of
//     `*strings.Builder` would answer "Builder" here and diverge from the
//     reference engine and from every other target, so a Ball program that
//     switches on `type_of` would take a different branch per target.
//  2. The sink is REFERENCE-SEMANTIC: a value handed to another function and
//     appended to there is observably longer to the caller. Go's own docs make
//     this the likely bug — "Do not copy a non-zero Builder"
//     (https://pkg.go.dev/strings#Builder) — and the precedent is issue #300,
//     where a by-value `[]Value` clone lost every list append.
func TestSinkIsATaggedReferenceValue(t *testing.T) {
	sink := SinkCreate(nil)

	if got := TypeOf(sink); got != "Sink" {
		t.Errorf("TypeOf(sink): got %v, want \"Sink\"", got)
	}

	SinkWrite(sink, "a")
	// The by-value trap: hand the sink to a callee (a plain function call is
	// exactly what a compiled Ball program does) and append there.
	func(s Value) { SinkWrite(s, "b") }(sink)

	if got := SinkToString(sink); got != "ab" {
		t.Errorf("SinkToString after a cross-call append: got %q, want %q", got, "ab")
	}
}

// TestSinkCreateSeed pins the optional `initial` seed (Dart's
// `StringBuffer('x')`, Rust's `String::from("x")`).
func TestSinkCreateSeed(t *testing.T) {
	sink := SinkCreate("x")
	SinkWrite(sink, "y")
	if got := SinkToString(sink); got != "xy" {
		t.Errorf("SinkToString: got %q, want %q", got, "xy")
	}
}
