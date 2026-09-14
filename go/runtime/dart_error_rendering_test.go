package ballrt

import "testing"

// Issue #658 — the rendering table has to cover every built-in Dart error a USER
// PROGRAM can construct and throw, not only the ones this runtime raises itself.
//
// `type_error_contract_test.go` (#641) pins the runtime-RAISED half: every name
// `dartError`/`CastAssert` throws has an entry. Nothing pinned the other half,
// and it is the bigger one — a literal `throw ArgumentError('nope')` is ordinary
// user code, `ArgumentError` is raised by no runtime in the repo, and so it sat
// in NO target's table while every check stayed green.
//
// Each expectation is Dart's own `toString()`, measured against the SDK
// (3.12.0), and `ArgumentError` is why the table cannot be "type name + colon":
// Dart spells it `Invalid argument(s)`.
func TestUserThrownBuiltinErrorsRenderLikeDart(t *testing.T) {
	cases := []struct {
		typeName string
		message  string
		want     string
	}{
		{"StateError", "boom", "Bad state: boom"},
		{"FormatException", "bad", "FormatException: bad"},
		{"RangeError", "oops", "RangeError: oops"},
		{"ArgumentError", "nope", "Invalid argument(s): nope"},
		// A compiled throw carries the program's module prefix on the tag; the
		// table resolves through `messageShortName`, so both spellings render.
		{"main:StateError", "boom", "Bad state: boom"},
		{"main:ArgumentError", "nope", "Invalid argument(s): nope"},
	}

	for _, tc := range cases {
		t.Run(tc.typeName, func(t *testing.T) {
			fields := NewMap()
			fields.Set("message", tc.message)
			if got := ToStr(NewMessage(tc.typeName, fields)); got != tc.want {
				t.Errorf("ToStr(%s) = %q, want %q", tc.typeName, got, tc.want)
			}
		})
	}
}

// The table stays CLOSED: a user class whose name merely ends in `Error` and
// which happens to carry a `message` field is not a Dart error.
func TestAUserErrorSuffixedClassIsNotRenderedAsADartError(t *testing.T) {
	fields := NewMap()
	fields.Set("message", "not a dart error")
	if got := ToStr(NewMessage("main:ValidationError", fields)); got != "main:ValidationError" {
		t.Errorf("ToStr(user message) = %q, want the type name", got)
	}
}
