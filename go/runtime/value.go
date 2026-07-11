// Package ballrt is the runtime value model and base-operation library for Ball
// programs compiled to Go.
//
// # Value model
//
// A Ball value ([Value]) is one of: nil (Ball null), int64 (Ball int — Ball
// ints are fixed 64-bit, matching Dart), float64 (Ball double), string, bool,
// []byte (Ball bytes), *List, *Map, *Function, or *Message. The compiler emits
// Go source that constructs and manipulates these through the helpers in this
// package.
//
// # Reference vs value semantics
//
// Ball lists, maps, and messages are *reference* types (like Dart's), so the
// aggregate kinds here ([List], [Map], [Message]) are always handled as
// pointers — copying a *List copies the handle, not the backing slice. Only
// scalars (int64/float64/string/bool) are value-copied. [Map] is
// insertion-ordered (like Dart's LinkedHashMap / Rust's IndexMap / C++'s
// ordered BallMap) — never iterate a Ball map via a bare Go map, whose order is
// randomized.
package ballrt

// Value is any Ball runtime value. See the package doc for the concrete set.
type Value = any

// List is a Ball list: an ordered, reference-semantic sequence of values.
// Always used as *List so mutations (e.g. Add) are observed through every
// handle, matching Dart list semantics.
type List struct {
	Items []Value
}

// NewList builds a *List from the given items (a fresh backing slice).
func NewList(items ...Value) *List {
	// Copy into a fresh slice so a list *literal* never aliases a caller's
	// backing array (matches the reference compilers' snapshot-at-copy-point
	// rule).
	cp := make([]Value, len(items))
	copy(cp, items)
	return &List{Items: cp}
}

// Add appends v to the list in place (Dart's List.add).
func (l *List) Add(v Value) { l.Items = append(l.Items, v) }

// Len reports the number of elements.
func (l *List) Len() int { return len(l.Items) }

// Map is a Ball map: an insertion-ordered, string-keyed, reference-semantic
// collection. Keys preserves insertion order; vals holds the values.
type Map struct {
	keys []string
	vals map[string]Value
}

// NewMap builds an empty ordered map.
func NewMap() *Map {
	return &Map{vals: map[string]Value{}}
}

// Set inserts or updates key, preserving first-insertion order.
func (m *Map) Set(key string, v Value) {
	if _, ok := m.vals[key]; !ok {
		m.keys = append(m.keys, key)
	}
	m.vals[key] = v
}

// Get returns the value for key and whether it was present.
func (m *Map) Get(key string) (Value, bool) {
	v, ok := m.vals[key]
	return v, ok
}

// Keys returns the keys in insertion order (a copy; safe to mutate).
func (m *Map) Keys() []string {
	cp := make([]string, len(m.keys))
	copy(cp, m.keys)
	return cp
}

// Len reports the number of entries.
func (m *Map) Len() int { return len(m.keys) }

// Function is a first-class Ball function value: a single-input, single-output
// callable (invariant #1). Name is cosmetic (for diagnostics/tear-offs).
type Function struct {
	Name string
	Fn   func(Value) Value
}

// Fn wraps a Go func as a *Function value (used for function tear-offs — a bare
// reference to a top-level function used as a value).
func Fn(name string, f func(Value) Value) *Function {
	return &Function{Name: name, Fn: f}
}

// Message is a constructed instance of a user TypeDefinition: a type tag plus an
// ordered field map. Reference-semantic (always *Message), matching Dart object
// semantics.
type Message struct {
	TypeName string
	Fields   *Map
}

// NewMessage builds a *Message with the given type name and (already-populated)
// ordered field map.
func NewMessage(typeName string, fields *Map) *Message {
	if fields == nil {
		fields = NewMap()
	}
	return &Message{TypeName: typeName, Fields: fields}
}
