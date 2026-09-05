package ballrt

import "testing"

// TestSetAddRemoveBoolContract pins the ONE portable contract for
// std_collections.set_add / set_remove (issue #545): both mutate the receiver
// set IN PLACE and return a bool — true only when the element was newly
// inserted / was actually present — exactly like Dart's own Set.add/Set.remove.
//
// Before #545, SetAdd returned the set itself, so a compiled Go program that
// put set_add's result in a value position (`if (s.add(x)) …`) computed
// something different from every other target. Conformance fixture
// 459_set_add_remove_bool is the cross-target half of this guard; this is the
// Go runtime half, because no CI leg compiles a conformance fixture to Go.
func TestSetAddRemoveBoolContract(t *testing.T) {
	s := SetCreate(NewList(int64(1), int64(2)))

	if got := SetAdd(s, int64(3)); got != true {
		t.Errorf("SetAdd fresh insert: got %#v, want true", got)
	}
	if got := SetAdd(s, int64(3)); got != false {
		t.Errorf("SetAdd duplicate: got %#v, want false", got)
	}
	// The insert must have landed on the SHARED set, exactly once — a
	// functional (copying) implementation would leave this at 2.
	if got := SetLength(s); got != int64(3) {
		t.Errorf("SetLength after add: got %v, want 3", got)
	}
	if got := SetContains(s, int64(3)); got != true {
		t.Errorf("SetContains(3): got %v, want true", got)
	}

	if got := SetRemove(s, int64(2)); got != true {
		t.Errorf("SetRemove present: got %#v, want true", got)
	}
	if got := SetRemove(s, int64(2)); got != false {
		t.Errorf("SetRemove absent: got %#v, want false", got)
	}
	if got := SetLength(s); got != int64(2) {
		t.Errorf("SetLength after remove: got %v, want 2", got)
	}
	if got := SetContains(s, int64(2)); got != false {
		t.Errorf("SetContains(2): got %v, want false", got)
	}
}
