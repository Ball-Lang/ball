package ballrt

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// CallMethod is the dynamic Dart-SDK method dispatcher (epic #426 Phase 4). The
// encoder lowers a receiver method call `x.m(a, b)` to
// `call{module:"", function:"m", input:{self, arg0, arg1}}`; the compiler routes
// a same-module call whose callee is not a known user function here. Self and
// positional args are read from the input message; the big switch implements the
// Dart core-library semantics the reference engine relies on.
//
// Fail-loud (issue #55): an unrecognized method panics with its name rather than
// returning a placeholder — the grind surfaces exactly which method the engine
// uses that is not yet implemented.
func CallMethod(name string, input Value) Value {
	self := methodSelf(input)
	a0 := methodArg(input, 0)
	a1 := methodArg(input, 1)
	a2 := methodArg(input, 2)

	// A static call: receiver is a bare type marker (int.parse, List.filled, …).
	if tm, ok := self.(TypeMarker); ok {
		return staticMethod(tm.Name, name, a0, a1, a2)
	}

	switch name {
	// ── Universal ──────────────────────────────────────────────────────────
	case "toString":
		return ToStr(self)
	case "hashCode":
		return int64(0)
	case "runtimeType":
		return runtimeTypeName(self)
	case "noSuchMethod":
		panic(Thrown{Value: "NoSuchMethodError"})
	case "cast", "retype":
		// `.cast<T>()` is a no-op reinterpret in the dynamic value model.
		return self
	case "identical":
		// Dart's global `identical(a, b)` reaches here as a 2-arg call (no
		// `self` field). Canonical primitives compare by value; aggregates by
		// reference identity — matching engine_eval.dart's `identical(a, b)`.
		return ballIdentical(a0, a1)
	case "convert":
		// A dart:convert codec's `.convert(x)` (`const JsonEncoder().convert`,
		// `const JsonDecoder().convert`) — engine_std.dart's JSON encode/decode.
		if m, ok := self.(*Message); ok {
			switch messageShortName(m.TypeName) {
			case "JsonEncoder":
				return JSONEncode(a0)
			case "JsonDecoder":
				return JSONDecode(a0)
			}
		}
		panic(Thrown{Value: "ball: .convert on unsupported codec " + ToStr(self)})
	case "toIso8601String":
		return dateTimeToIso8601(self)

	// ── String ───────────────────────────────────────────────────────────────
	case "toUpperCase":
		return strings.ToUpper(ToStr(self))
	case "toLowerCase":
		return strings.ToLower(ToStr(self))
	case "trim":
		return strings.TrimSpace(ToStr(self))
	case "trimLeft":
		return strings.TrimLeft(ToStr(self), " \t\n\r\f\v")
	case "trimRight":
		return strings.TrimRight(ToStr(self), " \t\n\r\f\v")
	case "substring":
		return Substring(ToStr(self), a0, a1)
	case "startsWith":
		return strings.HasPrefix(ToStr(self), ToStr(a0))
	case "endsWith":
		return strings.HasSuffix(ToStr(self), ToStr(a0))
	case "split":
		return StrSplit(ToStr(self), a0)
	case "replaceAll":
		if isRegExp(a0) {
			return regexReplaceAll(self, compileRegex(regexPattern(a0)), ToStr(a1))
		}
		return strings.ReplaceAll(ToStr(self), ToStr(a0), ToStr(a1))
	case "replaceFirst":
		return strings.Replace(ToStr(self), ToStr(a0), ToStr(a1), 1)
	case "padLeft":
		return padString(ToStr(self), a0, a1, true)
	case "padRight":
		return padString(ToStr(self), a0, a1, false)
	case "codeUnitAt":
		u := utf16Units(ToStr(self))
		i := int(asFloat(a0))
		if i < 0 || i >= len(u) {
			panic(Thrown{Value: fmt.Sprintf("RangeError: index %d", i)})
		}
		return int64(u[i])
	case "compareTo":
		return int64(cmp(self, a0))

	// ── RegExp / RegExpMatch ─────────────────────────────────────────────────
	case "firstMatch":
		return regexFirstMatch(self, a0)
	case "hasMatch":
		return regexHasMatch(self, a0)
	case "allMatches":
		return regexAllMatches(self, a0)
	case "stringMatch":
		return regexStringMatch(self, a0)
	case "group":
		return regexGroup(self, a0)
	case "groups":
		return regexGroups(self, a0)

	// ── num / int / double ──────────────────────────────────────────────────
	case "abs":
		return MathAbs(self)
	case "floor":
		return MathFloor(self)
	case "ceil":
		return MathCeil(self)
	case "round":
		return MathRound(self)
	case "truncate":
		return int64(math.Trunc(asFloat(self)))
	case "toInt":
		return ToInt(self)
	case "toDouble":
		return asFloat(self)
	case "roundToDouble":
		return math.Round(asFloat(self))
	case "floorToDouble":
		return math.Floor(asFloat(self))
	case "ceilToDouble":
		return math.Ceil(asFloat(self))
	case "truncateToDouble":
		return math.Trunc(asFloat(self))
	case "toStringAsFixed":
		return ToStringAsFixed(self, a0)
	case "toStringAsExponential":
		return ToStringAsExponential(self, a0)
	case "toStringAsPrecision":
		return ToStringAsPrecision(self, a0)
	case "remainder":
		return numRemainder(self, a0)
	case "clamp":
		return numClamp(self, a0, a1)
	case "toRadixString":
		return strconv.FormatInt(asInt64(self), int(asFloat(a0)))

	// ── List / Iterable ───────────────────────────────────────────────────────
	case "add":
		return ListPush(self, a0)
	case "addAll":
		// Polymorphic (matching the reference engines): Map.addAll merges entries,
		// Set.addAll unions, List.addAll appends — each mutating the receiver.
		switch dest := unwrap(self).(type) {
		case *Map:
			MapSpread(dest, a0)
		case *Set:
			for _, it := range Iterate(a0) {
				dest.add(it)
			}
		default:
			for _, it := range Iterate(a0) {
				asList(self).Add(it)
			}
		}
		return nil
	case "removeLast":
		return ListPop(self)
	case "removeAt":
		return ListRemoveAt(self, a0)
	case "insert":
		return ListInsert(self, a0, a1)
	case "indexOf":
		return listOrStringIndexOf(self, a0)
	case "sublist":
		return ListSlice(self, a0, a1)
	case "toList":
		return ListToList(self)
	case "toSet":
		return SetCreate(self)
	case "map":
		return ListMap(self, a0)
	case "where":
		return ListFilter(self, a0)
	case "every":
		return ListAll(self, a0)
	case "any":
		return ListAny(self, a0)
	case "join":
		return ListJoin(self, a0)
	case "sort":
		return ListSort(self, a0)
	case "take":
		return ListTake(self, a0)
	case "skip":
		return ListDrop(self, a0)
	case "contains":
		return containsMethod(self, a0)
	case "forEach":
		for _, it := range Iterate(self) {
			Call(a0, it)
		}
		return nil
	case "fold":
		acc := a0
		for _, it := range Iterate(self) {
			m := NewMap()
			m.Set("arg0", acc)
			m.Set("arg1", it)
			acc = Call(a1, m)
		}
		return acc
	case "reduce":
		items := Iterate(self)
		if len(items) == 0 {
			panic(Thrown{Value: "Bad state: No element"})
		}
		acc := items[0]
		for _, it := range items[1:] {
			m := NewMap()
			m.Set("arg0", acc)
			m.Set("arg1", it)
			acc = Call(a0, m)
		}
		return acc
	case "firstWhere":
		return whereFirst(self, a0, a1, false)
	case "lastWhere":
		return whereFirst(self, a0, a1, true)
	case "indexWhere":
		for i, it := range Iterate(self) {
			if Truthy(Call(a0, it)) {
				return int64(i)
			}
		}
		return int64(-1)
	case "elementAt":
		return Index(asList(self), a0)
	case "expand":
		out := NewList()
		for _, it := range Iterate(self) {
			for _, e := range Iterate(Call(a0, it)) {
				out.Add(e)
			}
		}
		return out
	case "removeWhere":
		l := asList(self)
		kept := l.Items[:0]
		for _, it := range append([]Value(nil), l.Items...) {
			if !Truthy(Call(a0, it)) {
				kept = append(kept, it)
			}
		}
		l.Items = kept
		return nil
	case "remove":
		return removeMethod(self, a0)
	case "clear":
		return clearMethod(self)
	case "reversed":
		return ListReverse(self)

	// ── Map ────────────────────────────────────────────────────────────────
	case "containsKey":
		return MapContainsKey(self, a0)
	case "containsValue":
		return MapContainsValue(self, a0)
	case "putIfAbsent":
		// putIfAbsent(key, () => value): the value arg is a thunk in Dart.
		mm := asMap(self)
		k := ToStr(a0)
		if v, ok := mm.Get(k); ok {
			return v
		}
		v := Call(a1, nil)
		mm.Set(k, v)
		return v
	case "update":
		mm := asMap(self)
		k := ToStr(a0)
		if v, ok := mm.Get(k); ok {
			nv := Call(a1, v)
			mm.Set(k, nv)
			return nv
		}
		if a2 != nil {
			nv := Call(a2, nil)
			mm.Set(k, nv)
			return nv
		}
		panic(Thrown{Value: "unknown key: " + k})

	// ── Set ────────────────────────────────────────────────────────────────
	case "union":
		return SetUnion(self, a0)
	case "intersection":
		return SetIntersection(self, a0)
	case "difference":
		return SetDifference(self, a0)
	case "lookup":
		s := asSet(self)
		if i := s.indexOf(a0); i >= 0 {
			return s.Items[i]
		}
		return nil
	}

	// Proto presence check: `x.hasFoo()` — a generated proto has-method the
	// encoder left as a plain method call (e.g. `field.hasValue()`, which its
	// ball_proto has* list omits) — is a field-presence test. Mirrors the
	// compiler's ball_proto `has*` → HasField dispatch.
	if len(name) > 3 && strings.HasPrefix(name, "has") && name[3] >= 'A' && name[3] <= 'Z' {
		field := strings.ToLower(name[3:4]) + name[4:]
		return HasField(self, field)
	}

	panic(Thrown{Value: "ball: unimplemented method ." + name})
}

// ── static (type-marker receiver) methods ───────────────────────────────────

func staticMethod(typeName, method string, a0, a1, a2 Value) Value {
	switch typeName {
	case "int":
		switch method {
		case "parse":
			return StrToInt(a0)
		case "tryParse":
			n, err := strconv.ParseInt(strings.TrimSpace(ToStr(a0)), 10, 64)
			if err != nil {
				return nil
			}
			return n
		}
	case "double", "num":
		switch method {
		case "parse":
			return StrToDouble(a0)
		case "tryParse":
			n, err := strconv.ParseFloat(strings.TrimSpace(ToStr(a0)), 64)
			if err != nil {
				return nil
			}
			return n
		}
	case "String":
		switch method {
		case "fromCharCode":
			return string(rune(asInt64(a0)))
		case "fromCharCodes":
			var sb strings.Builder
			for _, c := range Iterate(a0) {
				sb.WriteRune(rune(asInt64(c)))
			}
			return sb.String()
		}
	case "List":
		switch method {
		case "filled":
			return ListFilled(a0, a1)
		case "from", "of":
			return ListCopy(a0)
		case "generate":
			n := int(asFloat(a0))
			out := make([]Value, n)
			for i := 0; i < n; i++ {
				out[i] = Call(a1, int64(i))
			}
			return &List{Items: out}
		case "empty":
			return NewList()
		}
	case "Map":
		switch method {
		case "from", "of":
			return MapCopy(a0)
		}
	case "Set":
		switch method {
		case "from", "of":
			return SetCreate(a0)
		}
	case "DateTime":
		switch method {
		case "now":
			return dateTimeNow()
		case "fromMillisecondsSinceEpoch":
			return dateTimeFromMillis(asInt64(a0))
		case "parse":
			return dateTimeParse(ToStr(a0))
		}
	case "Function":
		switch method {
		case "apply":
			// Function.apply(fn, [arg]) — the engine (engine_std.dart's
			// std.invoke) always passes a single-element positional list
			// (`[value]`, `[null]`, or `[argsMap]`). Ball functions take one
			// input, so call the callee with that sole element.
			var arg Value
			if l, ok := a1.(*List); ok && len(l.Items) >= 1 {
				arg = l.Items[0]
			}
			return Call(a0, arg)
		}
	}
	panic(Thrown{Value: fmt.Sprintf("ball: unimplemented static %s.%s", typeName, method)})
}

// ── method helpers ──────────────────────────────────────────────────────────

func methodSelf(input Value) Value {
	if f := asFields(input); f != nil {
		if v, ok := f.Get("self"); ok {
			return v
		}
	}
	return input
}

func methodArg(input Value, i int) Value {
	f := asFields(input)
	if f == nil {
		if i == 0 {
			return input
		}
		return nil
	}
	key := "arg" + strconv.Itoa(i)
	if v, ok := f.Get(key); ok {
		return v
	}
	return nil
}

// ballIdentical implements Dart's `identical(a, b)`. Canonical primitives
// (num/String/bool/null) are identical when equal; every other value (List /
// Map / Set / Message / Function) compares by reference identity.
func ballIdentical(a, b Value) bool {
	switch a.(type) {
	case nil, int64, float64, int, string, bool:
		return Eq(a, b)
	}
	return a == b
}

func runtimeTypeName(v Value) string {
	switch x := unwrap(v).(type) {
	case nil:
		return "Null"
	case int64:
		return "int"
	case float64:
		return "double"
	case string:
		return "String"
	case bool:
		return "bool"
	case *List:
		return "List"
	case *Map:
		return "Map"
	case *Set:
		return "Set"
	case *Function:
		return "Function"
	case *Message:
		return messageShortName(x.TypeName)
	}
	return "Object"
}

func utf16Units(s string) []uint16 {
	var out []uint16
	for _, r := range s {
		if r <= 0xFFFF {
			out = append(out, uint16(r))
		} else {
			r -= 0x10000
			out = append(out, uint16(0xD800+(r>>10)), uint16(0xDC00+(r&0x3FF)))
		}
	}
	return out
}

func padString(s string, width, pad Value, left bool) string {
	w := int(asFloat(width))
	p := " "
	if pad != nil {
		p = ToStr(pad)
	}
	n := len([]rune(s))
	if n >= w || p == "" {
		return s
	}
	fill := strings.Repeat(p, w-n)
	if left {
		return fill + s
	}
	return s + fill
}

func listOrStringIndexOf(self, a0 Value) Value {
	if s, ok := unwrap(self).(string); ok {
		return int64(strings.Index(s, ToStr(a0)))
	}
	return ListIndexOf(self, a0)
}

func containsMethod(self, a0 Value) Value {
	switch unwrap(self).(type) {
	case string:
		return strings.Contains(ToStr(self), ToStr(a0))
	case *Set:
		return SetContains(self, a0)
	default:
		return ListContains(self, a0)
	}
}

func removeMethod(self, a0 Value) Value {
	switch unwrap(self).(type) {
	case *Set:
		return SetRemove(self, a0)
	case *Map:
		return MapDelete(self, a0)
	default:
		l := asList(self)
		if i := listRawIndexOf(l, a0); i >= 0 {
			l.Items = append(l.Items[:i], l.Items[i+1:]...)
			return true
		}
		return false
	}
}

func listRawIndexOf(l *List, v Value) int {
	for i, it := range l.Items {
		if Eq(it, v) {
			return i
		}
	}
	return -1
}

func clearMethod(self Value) Value {
	switch unwrap(self).(type) {
	case *Map:
		m := asMap(self)
		m.keys = nil
		m.vals = map[string]Value{}
	case *Set:
		asSet(self).Items = nil
	default:
		asList(self).Items = nil
	}
	return nil
}

func numRemainder(a, b Value) Value {
	if ai, bi, ok := bothInt(a, b); ok {
		return ai % bi
	}
	return math.Mod(asFloat(a), asFloat(b))
}

func numClamp(v, lo, hi Value) Value {
	if cmp(v, lo) < 0 {
		return lo
	}
	if cmp(v, hi) > 0 {
		return hi
	}
	return v
}

func whereFirst(self, pred, orElse Value, last bool) Value {
	items := Iterate(self)
	if last {
		for i := len(items) - 1; i >= 0; i-- {
			if Truthy(Call(pred, items[i])) {
				return items[i]
			}
		}
	} else {
		for _, it := range items {
			if Truthy(Call(pred, it)) {
				return it
			}
		}
	}
	if orElse != nil {
		return Call(orElse, nil)
	}
	panic(Thrown{Value: "Bad state: No element"})
}
