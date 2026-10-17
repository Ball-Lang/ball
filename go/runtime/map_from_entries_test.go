package ballrt

import "testing"

// TestMapFromEntriesPresentButNilKeyFallsBackToArg0 and its value/arg1 sibling
// pin the Dart reference engine's exact field-fallback semantics for
// std_collections.map_from_entries (issue #715): `eMap['key'] ?? eMap['arg0']`
// (dart/engine/lib/engine_std.dart:1096) treats a PRESENT-BUT-NULL `key` the
// same as an ABSENT one — Dart's `??` falls through on null, not just on a
// missing map entry.
//
// Before #715, MapFromEntries only fell back to arg0/arg1 when the key/value
// field was absent (`!hasKey`); a present-but-nil key read `hasKey == true`,
// skipped the fallback, and then the `k == nil` guard silently dropped the
// whole entry — so an entry map shaped `{key: null, arg0: "x"}` vanished from
// the result instead of being kept under "x", a cross-target divergence from
// every other Ball engine (which share this exact Dart source).
func TestMapFromEntriesPresentButNilKeyFallsBackToArg0(t *testing.T) {
	entry := NewMap()
	entry.Set("key", nil)
	entry.Set("arg0", "x")
	entry.Set("value", "v")

	result := asMap(MapFromEntries(NewList(entry)))

	if got := result.Len(); got != 1 {
		t.Fatalf("MapFromEntries dropped the entry: got %d keys, want 1 (keys=%v)", got, result.Keys())
	}
	got, ok := result.Get("x")
	if !ok {
		t.Fatalf("MapFromEntries: result has no key %q, want it keyed by arg0; keys=%v", "x", result.Keys())
	}
	if got != "v" {
		t.Errorf("MapFromEntries: result[%q] = %#v, want %q", "x", got, "v")
	}
}

func TestMapFromEntriesPresentButNilValueFallsBackToArg1(t *testing.T) {
	entry := NewMap()
	entry.Set("key", "k")
	entry.Set("value", nil)
	entry.Set("arg1", "y")

	result := asMap(MapFromEntries(NewList(entry)))

	got, ok := result.Get("k")
	if !ok {
		t.Fatalf("MapFromEntries: result has no key %q; keys=%v", "k", result.Keys())
	}
	if got != "y" {
		t.Errorf("MapFromEntries: result[%q] = %#v, want %q (fallback to arg1)", "k", got, "y")
	}
}

// TestMapFromEntriesAbsentKeyStillSkipsEntry keeps the ORIGINAL behavior for a
// truly key-less, arg0-less entry: it must still be skipped, not panic or
// insert a "null" key.
func TestMapFromEntriesAbsentKeyStillSkipsEntry(t *testing.T) {
	entry := NewMap()
	entry.Set("value", "v")

	result := asMap(MapFromEntries(NewList(entry)))

	if got := result.Len(); got != 0 {
		t.Errorf("MapFromEntries: got %d keys, want 0 for a keyless entry (keys=%v)", got, result.Keys())
	}
}
