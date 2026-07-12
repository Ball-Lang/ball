package ballrt

import (
	"fmt"
	"sort"
	"strings"
)

// std_collections base functions + the Set value type. Semantics match the Dart
// reference engine (dart/shared/lib/std_collections.dart + the engine's list/map
// handlers). Reference-semantic like every other engine: a list/map/set passed
// around aliases its backing, so an in-place mutation is observed by the caller.

// Set is a Ball set: an insertion-ordered collection with structural-equality
// membership (Dart's LinkedHashSet). Backed by an ordered slice; membership uses
// Eq so 1 and 1.0 collapse the way Dart's set does.
type Set struct {
	Items []Value
}

// NewSet builds an empty set.
func NewSet() *Set { return &Set{} }

func (s *Set) indexOf(v Value) int {
	for i, it := range s.Items {
		if Eq(it, v) {
			return i
		}
	}
	return -1
}

// add inserts v if absent, reporting whether it was newly added.
func (s *Set) add(v Value) bool {
	if s.indexOf(v) >= 0 {
		return false
	}
	s.Items = append(s.Items, v)
	return true
}

// ── List ops ────────────────────────────────────────────────────────────────

func asList(v Value) *List {
	switch x := unwrap(v).(type) {
	case *List:
		return x
	case *Set:
		return &List{Items: append([]Value(nil), x.Items...)}
	case []byte:
		out := make([]Value, len(x))
		for i, b := range x {
			out[i] = int64(b)
		}
		return &List{Items: out}
	case nil:
		return NewList()
	}
	debugTrace()
	panic(fmt.Sprintf("ball: expected a list, got %T", v))
}

// ListGet returns list[index] (Dart's operator []).
func ListGet(list, index Value) Value { return Index(asList(list), index) }

// ListLength returns list.length.
func ListLength(list Value) Value { return int64(asList(list).Len()) }

// ListIsEmpty returns list.isEmpty.
func ListIsEmpty(list Value) Value { return asList(list).Len() == 0 }

// ListFirst returns list.first.
func ListFirst(list Value) Value {
	l := asList(list)
	if l.Len() == 0 {
		panic(Thrown{Value: "Bad state: No element"})
	}
	return l.Items[0]
}

// ListLast returns list.last.
func ListLast(list Value) Value {
	l := asList(list)
	if l.Len() == 0 {
		panic(Thrown{Value: "Bad state: No element"})
	}
	return l.Items[l.Len()-1]
}

// ListContains returns list.contains(value). Polymorphic: the syntactic encoder
// routes String.contains here too, so a string receiver does a substring search.
func ListContains(list, value Value) Value {
	if s, ok := unwrap(list).(string); ok {
		return strings.Contains(s, ToStr(value))
	}
	for _, it := range asList(list).Items {
		if Eq(it, value) {
			return true
		}
	}
	return false
}

// ListIndexOf returns list.indexOf(value). Polymorphic for a string receiver.
func ListIndexOf(list, value Value) Value {
	if s, ok := unwrap(list).(string); ok {
		return int64(strings.Index(s, ToStr(value)))
	}
	for i, it := range asList(list).Items {
		if Eq(it, value) {
			return int64(i)
		}
	}
	return int64(-1)
}

// ListReverse returns a new reversed list.
func ListReverse(list Value) Value {
	src := asList(list).Items
	out := make([]Value, len(src))
	for i, it := range src {
		out[len(src)-1-i] = it
	}
	return &List{Items: out}
}

// ListConcat implements std.list_concat, the target of Dart's `list + list` AND
// the syntactically-mis-routed `.addAll` on a List/Set/Map receiver. It is
// therefore polymorphic (matching the reference engines' std handler):
//   - a Map receiver → an in-place merge (Map.addAll mutates the receiver, which
//     the engine's own `methods.addAll(...)` relies on), returning it;
//   - a Set receiver → an in-place union;
//   - a List receiver → a fresh concatenated list (Dart's `+`, non-mutating).
func ListConcat(a, b Value) Value {
	switch dest := unwrap(a).(type) {
	case *Map:
		return MapSpread(dest, b)
	case *Set:
		for _, it := range Iterate(b) {
			dest.add(it)
		}
		return dest
	}
	la, lb := asList(a).Items, asList(b).Items
	out := make([]Value, 0, len(la)+len(lb))
	out = append(out, la...)
	out = append(out, lb...)
	return &List{Items: out}
}

// ListSlice returns list.sublist(start, [end]).
func ListSlice(list, start, end Value) Value {
	l := asList(list).Items
	a := int(asFloat(start))
	b := len(l)
	if end != nil {
		b = int(asFloat(end))
	}
	if a < 0 {
		a = 0
	}
	if b > len(l) {
		b = len(l)
	}
	if a > b {
		a = b
	}
	return &List{Items: append([]Value(nil), l[a:b]...)}
}

// ListTake returns the first n elements (Dart's take).
func ListTake(list, n Value) Value {
	l := asList(list).Items
	k := int(asFloat(n))
	if k < 0 {
		k = 0
	}
	if k > len(l) {
		k = len(l)
	}
	return &List{Items: append([]Value(nil), l[:k]...)}
}

// ListDrop returns all but the first n elements (Dart's skip).
func ListDrop(list, n Value) Value {
	l := asList(list).Items
	k := int(asFloat(n))
	if k < 0 {
		k = 0
	}
	if k > len(l) {
		k = len(l)
	}
	return &List{Items: append([]Value(nil), l[k:]...)}
}

// ListPush appends value to list in place and returns the list (Dart's add).
func ListPush(list, value Value) Value {
	l := asList(list)
	l.Add(value)
	return l
}

// ListPop removes and returns the last element (Dart's removeLast).
func ListPop(list Value) Value {
	l := asList(list)
	if l.Len() == 0 {
		panic(Thrown{Value: "Bad state: No element"})
	}
	v := l.Items[l.Len()-1]
	l.Items = l.Items[:l.Len()-1]
	return v
}

// ListInsert inserts value at index in place (Dart's insert).
func ListInsert(list, index, value Value) Value {
	l := asList(list)
	i := int(asFloat(index))
	if i < 0 || i > l.Len() {
		panic(Thrown{Value: fmt.Sprintf("RangeError: index %d", i)})
	}
	l.Items = append(l.Items, nil)
	copy(l.Items[i+1:], l.Items[i:])
	l.Items[i] = value
	// Return the (mutated) list, not null: the encoder lowers `x.insert(i, v)` to
	// `assign(x, list_insert(x, i, v))`, so the return value is stored back into
	// x — nil would blank the list (the self-host list_insert handler's own
	// `list.insert(...)` did exactly this, returning null to its caller).
	return l
}

// ListRemoveAt removes and returns the element at index (Dart's removeAt).
func ListRemoveAt(list, index Value) Value {
	l := asList(list)
	i := int(asFloat(index))
	if i < 0 || i >= l.Len() {
		panic(Thrown{Value: fmt.Sprintf("RangeError: index %d", i)})
	}
	v := l.Items[i]
	l.Items = append(l.Items[:i], l.Items[i+1:]...)
	return v
}

// ListSet sets list[index] = value in place.
func ListSet(list, index, value Value) Value { return SetIndex(asList(list), index, value) }

// ListClear empties list in place.
func ListClear(list Value) Value {
	asList(list).Items = nil
	return nil
}

// ListToList returns a shallow copy (Dart's toList / List.from).
func ListToList(list Value) Value {
	return &List{Items: append([]Value(nil), asList(list).Items...)}
}

// ListCopy is List.from / List.of.
func ListCopy(source Value) Value { return ListToList(source) }

// ListFilled is List.filled(n, value).
func ListFilled(n, value Value) Value {
	k := int(asFloat(n))
	if k < 0 {
		k = 0
	}
	out := make([]Value, k)
	for i := range out {
		out[i] = value
	}
	return &List{Items: out}
}

// StringJoin / ListJoin returns list.join([separator]).
func ListJoin(list, sep Value) Value {
	s := ""
	if sep != nil {
		s = ToStr(sep)
	}
	parts := asList(list).Items
	pieces := make([]string, len(parts))
	for i, it := range parts {
		pieces[i] = ToStr(it)
	}
	return strings.Join(pieces, s)
}

// StringJoin is std_collections.string_join (alias for ListJoin).
func StringJoin(list, sep Value) Value { return ListJoin(list, sep) }

// ── List callback ops ───────────────────────────────────────────────────────

// ListMap returns list.map(fn).toList().
func ListMap(list, fn Value) Value {
	src := asList(list).Items
	out := make([]Value, len(src))
	for i, it := range src {
		out[i] = Call(fn, it)
	}
	return &List{Items: out}
}

// ListFilter returns list.where(fn).toList().
func ListFilter(list, fn Value) Value {
	out := NewList()
	for _, it := range asList(list).Items {
		if Truthy(Call(fn, it)) {
			out.Add(it)
		}
	}
	return out
}

// ListAll returns list.every(fn).
func ListAll(list, fn Value) Value {
	for _, it := range asList(list).Items {
		if !Truthy(Call(fn, it)) {
			return false
		}
	}
	return true
}

// ListAny returns list.any(fn).
func ListAny(list, fn Value) Value {
	for _, it := range asList(list).Items {
		if Truthy(Call(fn, it)) {
			return true
		}
	}
	return false
}

// ListSort sorts list in place (Dart's sort). cmpFn may be null (natural order).
func ListSort(list, cmpFn Value) Value {
	l := asList(list)
	items := l.Items
	sort.SliceStable(items, func(i, j int) bool {
		if cmpFn != nil {
			return invokeCompare(cmpFn, items[i], items[j]) < 0
		}
		return cmp(items[i], items[j]) < 0
	})
	return l
}

// invokeCompare invokes a two-argument comparator packed as {arg0, arg1}.
func invokeCompare(cmpFn, a, b Value) int {
	m := NewMap()
	m.Set("arg0", a)
	m.Set("arg1", b)
	return int(asFloat(Call(cmpFn, m)))
}

// ── Map ops ─────────────────────────────────────────────────────────────────

func asMap(v Value) *Map {
	switch x := unwrap(v).(type) {
	case *Map:
		return x
	case *Message:
		return x.Fields
	case nil:
		return NewMap()
	}
	panic(fmt.Sprintf("ball: expected a map, got %T", v))
}

// MapCreate builds an empty ordered map.
func MapCreate() Value { return NewMap() }

// MapGet returns map[key], or null.
func MapGet(m, key Value) Value {
	v, _ := asMap(m).Get(ToStr(key))
	return v
}

// MapSet sets map[key] = value in place.
func MapSet(m, key, value Value) Value {
	asMap(m).Set(ToStr(key), value)
	return value
}

// MapAddEntry sets map[key] = value in place, returning the map (map-literal
// building).
func MapAddEntry(m, key, value Value) Value {
	mm := asMap(m)
	mm.Set(ToStr(key), value)
	return mm
}

// MapSpread merges src into dest in place, returning dest (map-literal spread).
func MapSpread(dest, src Value) Value {
	d := asMap(dest)
	s := asMap(src)
	for _, k := range s.keys {
		v, _ := s.Get(k)
		d.Set(k, v)
	}
	return d
}

// MapDelete removes key, returning its former value (Dart's remove).
func MapDelete(m, key Value) Value {
	mm := asMap(m)
	k := ToStr(key)
	v, ok := mm.Get(k)
	if !ok {
		return nil
	}
	delete(mm.vals, k)
	for i, kk := range mm.keys {
		if kk == k {
			mm.keys = append(mm.keys[:i], mm.keys[i+1:]...)
			break
		}
	}
	return v
}

// MapContainsKey returns map.containsKey(key).
func MapContainsKey(m, key Value) Value {
	_, ok := asMap(m).Get(ToStr(key))
	return ok
}

// MapContainsValue returns map.containsValue(value).
func MapContainsValue(m, value Value) Value {
	mm := asMap(m)
	for _, k := range mm.keys {
		v, _ := mm.Get(k)
		if Eq(v, value) {
			return true
		}
	}
	return false
}

// MapKeys returns map.keys as a list.
func MapKeys(m Value) Value {
	mm := asMap(m)
	out := make([]Value, len(mm.keys))
	for i, k := range mm.keys {
		out[i] = k
	}
	return &List{Items: out}
}

// MapValues returns map.values as a list.
func MapValues(m Value) Value {
	mm := asMap(m)
	out := make([]Value, len(mm.keys))
	for i, k := range mm.keys {
		out[i], _ = mm.Get(k)
	}
	return &List{Items: out}
}

// MapLength returns map.length.
func MapLength(m Value) Value { return int64(asMap(m).Len()) }

// MapIsEmpty returns map.isEmpty.
func MapIsEmpty(m Value) Value { return asMap(m).Len() == 0 }

// MapMerge returns a new map = a with b's entries overlaid (Dart spread merge).
func MapMerge(a, b Value) Value {
	out := NewMap()
	for _, k := range asMap(a).keys {
		v, _ := asMap(a).Get(k)
		out.Set(k, v)
	}
	for _, k := range asMap(b).keys {
		v, _ := asMap(b).Get(k)
		out.Set(k, v)
	}
	return out
}

// MapCopy is Map.from / Map.of.
func MapCopy(source Value) Value { return MapMerge(NewMap(), source) }

// MapPutIfAbsent sets map[key] only if absent, returning the effective value.
// The value argument follows Dart's putIfAbsent(key, () => value): the "ifAbsent"
// argument is a THUNK evaluated lazily only when the key is absent, so a
// *Function value is called to produce the value (not stored as-is — storing the
// thunk is what left every _dispatch entry a handler-returning closure).
func MapPutIfAbsent(m, key, value Value) Value {
	mm := asMap(m)
	k := ToStr(key)
	if v, ok := mm.Get(k); ok {
		return v
	}
	if fn, ok := value.(*Function); ok {
		value = fn.Fn(nil)
	}
	mm.Set(k, value)
	return value
}

// ── Set ops ─────────────────────────────────────────────────────────────────

func asSet(v Value) *Set {
	switch x := unwrap(v).(type) {
	case *Set:
		return x
	case *List:
		s := NewSet()
		for _, it := range x.Items {
			s.add(it)
		}
		return s
	case nil:
		return NewSet()
	}
	panic(fmt.Sprintf("ball: expected a set, got %T", v))
}

// SetCreate builds a set from an optional iterable (Set() / Set.from(xs)).
func SetCreate(iterable Value) Value {
	s := NewSet()
	if iterable != nil {
		for _, it := range Iterate(iterable) {
			s.add(it)
		}
	}
	return s
}

// SetAdd adds value to the set in place, returning the set.
func SetAdd(set, value Value) Value {
	s := asSet(set)
	s.add(value)
	return s
}

// SetRemove removes value from the set in place, reporting whether it was present.
func SetRemove(set, value Value) Value {
	s := asSet(set)
	if i := s.indexOf(value); i >= 0 {
		s.Items = append(s.Items[:i], s.Items[i+1:]...)
		return true
	}
	return false
}

// SetContains returns set.contains(value).
func SetContains(set, value Value) Value { return asSet(set).indexOf(value) >= 0 }

// SetLength returns set.length.
func SetLength(set Value) Value { return int64(len(asSet(set).Items)) }

// SetIsEmpty returns set.isEmpty.
func SetIsEmpty(set Value) Value { return len(asSet(set).Items) == 0 }

// SetToList returns set.toList().
func SetToList(set Value) Value {
	return &List{Items: append([]Value(nil), asSet(set).Items...)}
}

// SetUnion returns a ∪ b.
func SetUnion(a, b Value) Value {
	out := NewSet()
	for _, it := range asSet(a).Items {
		out.add(it)
	}
	for _, it := range asSet(b).Items {
		out.add(it)
	}
	return out
}

// SetIntersection returns a ∩ b.
func SetIntersection(a, b Value) Value {
	other := asSet(b)
	out := NewSet()
	for _, it := range asSet(a).Items {
		if other.indexOf(it) >= 0 {
			out.add(it)
		}
	}
	return out
}

// SetDifference returns a \ b.
func SetDifference(a, b Value) Value {
	other := asSet(b)
	out := NewSet()
	for _, it := range asSet(a).Items {
		if other.indexOf(it) < 0 {
			out.add(it)
		}
	}
	return out
}
