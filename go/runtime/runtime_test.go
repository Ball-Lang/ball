package ballrt

import "testing"

func TestArithmetic(t *testing.T) {
	if got := Add(int64(2), int64(3)); got != int64(5) {
		t.Errorf("Add int: got %v", got)
	}
	if got := Add("a", "b"); got != "ab" {
		t.Errorf("Add string: got %v", got)
	}
	if got := Add(int64(1), float64(0.5)); got != float64(1.5) {
		t.Errorf("Add int+double: got %v", got)
	}
	if got := Sub(int64(5), int64(2)); got != int64(3) {
		t.Errorf("Sub: got %v", got)
	}
	if got := Mul(int64(4), int64(3)); got != int64(12) {
		t.Errorf("Mul: got %v", got)
	}
	if got := IntDiv(int64(7), int64(2)); got != int64(3) {
		t.Errorf("IntDiv: got %v", got)
	}
	if got := DivDouble(int64(7), int64(2)); got != float64(3.5) {
		t.Errorf("DivDouble: got %v", got)
	}
}

func TestModuloDartSemantics(t *testing.T) {
	// Dart/Euclidean: result takes the sign of the divisor.
	if got := Modulo(int64(-5), int64(3)); got != int64(1) {
		t.Errorf("Modulo(-5,3): got %v want 1", got)
	}
	if got := Modulo(int64(5), int64(3)); got != int64(2) {
		t.Errorf("Modulo(5,3): got %v want 2", got)
	}
}

func TestComparisonAndEquality(t *testing.T) {
	if !Lt(int64(1), int64(2)) {
		t.Error("Lt")
	}
	if !Eq(int64(1), float64(1.0)) {
		t.Error("Eq should promote int/double")
	}
	if Eq(int64(1), int64(2)) {
		t.Error("Eq mismatch")
	}
	if !Neq("a", "b") {
		t.Error("Neq")
	}
}

func TestTruthyAndLogic(t *testing.T) {
	if !Truthy(true) || Truthy(false) || Truthy(nil) {
		t.Error("Truthy bool/nil")
	}
	if !Not(false) {
		t.Error("Not")
	}
}

func TestToStr(t *testing.T) {
	cases := []struct {
		in   Value
		want string
	}{
		{int64(42), "42"},
		{float64(10), "10.0"},
		{float64(3.5), "3.5"},
		{"hi", "hi"},
		{true, "true"},
		{nil, "null"},
		{NewList(int64(1), int64(2)), "[1, 2]"},
	}
	for _, tc := range cases {
		if got := ToStr(tc.in); got != tc.want {
			t.Errorf("ToStr(%v): got %q want %q", tc.in, got, tc.want)
		}
	}
}

func TestListReferenceSemantics(t *testing.T) {
	l := NewList(int64(1))
	alias := l // copying the *List shares the backing (Dart reference semantics)
	alias.Add(int64(2))
	if l.Len() != 2 {
		t.Errorf("expected mutation through alias to be observed, len=%d", l.Len())
	}
}

func TestOrderedMap(t *testing.T) {
	m := NewMap()
	m.Set("b", int64(2))
	m.Set("a", int64(1))
	m.Set("b", int64(3)) // update keeps position
	keys := m.Keys()
	if len(keys) != 2 || keys[0] != "b" || keys[1] != "a" {
		t.Errorf("insertion order not preserved: %v", keys)
	}
	if v, _ := m.Get("b"); v != int64(3) {
		t.Errorf("update: got %v", v)
	}
}

func TestReturnFlow(t *testing.T) {
	fn := func(input Value) (__ret Value) {
		defer CatchReturn(&__ret)
		// Early return via flow signal, then unreachable tail.
		__ret = func() Value {
			_ = Return(int64(7))
			return int64(999)
		}()
		return
	}
	if got := fn(nil); got != int64(7) {
		t.Errorf("Return flow: got %v want 7", got)
	}
}

func TestBreakContinueFlow(t *testing.T) {
	// Sum 0..9 but break at 5, continue-skipping odd numbers below 5.
	sum := int64(0)
	for i := int64(0); i < 10; i++ {
		i := i
		brk := RunLoopBody("", func() {
			if i == 5 {
				_ = Break("")
			}
			if i%2 == 1 {
				_ = Continue("")
			}
			sum += i
		})
		if brk {
			break
		}
	}
	if sum != 0+2+4 {
		t.Errorf("break/continue flow: got %d want 6", sum)
	}
}

func TestTryCatch(t *testing.T) {
	got := TryCatch(
		func() Value { return Throw("boom") },
		func(e Value) Value { return "caught:" + ToStr(e) },
		nil,
	)
	if got != "caught:boom" {
		t.Errorf("TryCatch: got %v", got)
	}
}

func TestIndexAndIterate(t *testing.T) {
	l := NewList("a", "b", "c")
	if Index(l, int64(1)) != "b" {
		t.Error("Index list")
	}
	items := Iterate(l)
	if len(items) != 3 || items[2] != "c" {
		t.Errorf("Iterate: %v", items)
	}
}
