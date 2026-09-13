package ballrt

import "testing"

// TestCatchMatches pins the clause-selection rule the compiled `try` dispatch
// relies on (issue #615): a typed `on <Type> catch` matches a thrown value's
// type tag by its FULL or BARE spelling, and an untagged value reports
// std.throw's own default, `Exception`.
func TestCatchMatches(t *testing.T) {
	fields := NewMap()
	fields.Set("arg0", "boom")
	qualified := NewMessage("main:StateError", fields)

	cases := []struct {
		name   string
		thrown Value
		clause string
		want   bool
	}{
		{"bare clause vs module-qualified tag", qualified, "StateError", true},
		{"full clause vs module-qualified tag", qualified, "main:StateError", true},
		{"non-matching clause", qualified, "ArgumentError", false},
		// A module-qualified clause must not match a DIFFERENT module's type.
		{"other module's tag", qualified, "other:StateError", false},
		{"map __type__ tag", typedMap("FormatException"), "FormatException", true},
		{"map __type__ tag, wrong clause", typedMap("FormatException"), "StateError", false},
		// std.throw tags an untagged value `Exception` (engine_std.dart).
		{"untagged string", "oops", "Exception", true},
		{"untagged string, typed clause", "oops", "StateError", false},
	}
	for _, tc := range cases {
		if got := CatchMatches(tc.thrown, tc.clause); got != tc.want {
			t.Errorf("%s: CatchMatches(%v, %q) = %v, want %v", tc.name, tc.thrown, tc.clause, got, tc.want)
		}
	}
}

// TestThrowAliasesArg0AsMessage pins std.throw's arg0 -> message rename
// (engine_std.dart): the encoder stores `StateError('boom')`'s argument
// positionally, while Dart source reads it back as `e.message`.
func TestThrowAliasesArg0AsMessage(t *testing.T) {
	fields := NewMap()
	fields.Set("arg0", "boom")
	thrown := normalizeThrown(NewMessage("main:StateError", fields))

	if got := FieldGet(thrown, "message"); got != "boom" {
		t.Errorf("e.message after throw: got %v, want %q", got, "boom")
	}

	// An explicit `message` field is never overwritten by `arg0`.
	explicit := NewMap()
	explicit.Set("arg0", "positional")
	explicit.Set("message", "explicit")
	kept := normalizeThrown(NewMessage("main:StateError", explicit))
	if got := FieldGet(kept, "message"); got != "explicit" {
		t.Errorf("explicit message clobbered: got %v", got)
	}
}

func typedMap(typeName string) Value {
	m := NewMap()
	m.Set("__type__", typeName)
	m.Set("message", "x")
	return m
}
