package ballrt

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
)

// Print implements std.print: write the value's string form followed by a
// newline to stdout. Returns nil (Ball void).
func Print(v Value) Value {
	fmt.Println(ToStr(v))
	return nil
}

// PrintError implements std.print_error: write to stderr.
func PrintError(v Value) Value {
	fmt.Fprintln(os.Stderr, ToStr(v))
	return nil
}

// ── String operations ───────────────────────────────────────────────────────

// StrUpper implements std.string_to_upper.
func StrUpper(v Value) Value { return strings.ToUpper(ToStr(v)) }

// StrLower implements std.string_to_lower.
func StrLower(v Value) Value { return strings.ToLower(ToStr(v)) }

// StrTrim implements std.string_trim.
func StrTrim(v Value) Value { return strings.TrimSpace(ToStr(v)) }

// StrTrimStart implements std.string_trim_start (Dart's trimLeft).
func StrTrimStart(v Value) Value { return strings.TrimLeft(ToStr(v), " \t\n\r\f\v") }

// StrTrimEnd implements std.string_trim_end (Dart's trimRight).
func StrTrimEnd(v Value) Value { return strings.TrimRight(ToStr(v), " \t\n\r\f\v") }

// StrRunes implements std.string_runes: the string's Unicode code points as a
// list of ints (Dart's String.runes).
func StrRunes(v Value) Value {
	var out []Value
	for _, r := range ToStr(v) {
		out = append(out, int64(r))
	}
	return &List{Items: out}
}

// MathGcd implements std.math_gcd (Dart's int.gcd).
func MathGcd(a, b Value) Value {
	x, y := asInt64(a), asInt64(b)
	if x < 0 {
		x = -x
	}
	if y < 0 {
		y = -y
	}
	for y != 0 {
		x, y = y, x%y
	}
	return x
}

// RoundToDouble implements std.round_to_double (Dart's num.roundToDouble).
func RoundToDouble(v Value) Value { return roundHalfAway(asFloat(v)) }

// FloorToDouble implements std.floor_to_double.
func FloorToDouble(v Value) Value { return math.Floor(asFloat(v)) }

// CeilToDouble implements std.ceil_to_double.
func CeilToDouble(v Value) Value { return math.Ceil(asFloat(v)) }

// TruncateToDouble implements std.truncate_to_double.
func TruncateToDouble(v Value) Value { return math.Trunc(asFloat(v)) }

// roundHalfAway rounds to the nearest integer, ties away from zero (Dart's
// round semantics), returning a double.
func roundHalfAway(f float64) float64 {
	if f < 0 {
		return -math.Floor(-f + 0.5)
	}
	return math.Floor(f + 0.5)
}

// StrContains implements std.string_contains.
func StrContains(s, sub Value) Value { return strings.Contains(ToStr(s), ToStr(sub)) }

// StrStartsWith implements std.string_starts_with.
func StrStartsWith(s, pre Value) Value { return strings.HasPrefix(ToStr(s), ToStr(pre)) }

// StrEndsWith implements std.string_ends_with.
func StrEndsWith(s, suf Value) Value { return strings.HasSuffix(ToStr(s), ToStr(suf)) }

// StrIndexOf implements std.string_index_of.
func StrIndexOf(s, sub Value) Value {
	return int64(strings.Index(ToStr(s), ToStr(sub)))
}

// StrSplit implements std.string_split, returning a *List of substrings.
func StrSplit(s, sep Value) Value {
	parts := strings.Split(ToStr(s), ToStr(sep))
	items := make([]Value, len(parts))
	for i, p := range parts {
		items[i] = p
	}
	return &List{Items: items}
}

// StrReplaceAll implements std.string_replace_all.
func StrReplaceAll(s, from, to Value) Value {
	return strings.ReplaceAll(ToStr(s), ToStr(from), ToStr(to))
}

// Substring implements std.string_substring with Dart's (start, end) semantics.
func Substring(s, start, end Value) Value {
	r := []rune(ToStr(s))
	a := int(asFloat(start))
	b := len(r)
	if end != nil {
		b = int(asFloat(end))
	}
	if a < 0 {
		a = 0
	}
	if b > len(r) {
		b = len(r)
	}
	if a > b {
		a = b
	}
	return string(r[a:b])
}

// StrIsEmpty implements std.string_is_empty. Polymorphic: the syntactic encoder
// cannot tell a String.isEmpty from a List/Map/Set.isEmpty, so it routes every
// `.isEmpty`/`.isNotEmpty` here — this must answer emptiness for collections too
// (matching the reference engines' polymorphic std handler).
func StrIsEmpty(v Value) Value {
	switch x := unwrap(v).(type) {
	case string:
		return len(x) == 0
	case *List:
		return x.Len() == 0
	case *Map:
		return x.Len() == 0
	case *Set:
		return len(x.Items) == 0
	case []byte:
		return len(x) == 0
	case nil:
		return true
	}
	return len(ToStr(v)) == 0
}

// StrCodeUnitAt implements std.string_code_unit_at (UTF-16 code unit).
func StrCodeUnitAt(s, i Value) Value {
	u := utf16Units(ToStr(s))
	idx := int(asFloat(i))
	if idx < 0 || idx >= len(u) {
		panic(Thrown{Value: fmt.Sprintf("RangeError: index %d", idx)})
	}
	return int64(u[idx])
}

// StrLastIndexOf implements std.string_last_index_of.
func StrLastIndexOf(s, search Value) Value {
	return int64(strings.LastIndex(ToStr(s), ToStr(search)))
}

// StrReplace implements std.string_replace (Dart's replaceFirst).
func StrReplace(s, from, to Value) Value {
	return strings.Replace(ToStr(s), ToStr(from), ToStr(to), 1)
}

// StrPadLeft implements std.string_pad_left.
func StrPadLeft(s, width, padding Value) Value { return padString(ToStr(s), width, padding, true) }

// StrPadRight implements std.string_pad_right.
func StrPadRight(s, width, padding Value) Value { return padString(ToStr(s), width, padding, false) }

// CompareTo implements std.compare_to (Comparable.compareTo → -1/0/1).
func CompareTo(a, b Value) Value { return int64(cmp(a, b)) }

// NullCheck implements Dart's null-assertion operator `x!`: return the value,
// throwing if it is null.
func NullCheck(v Value) Value {
	if v == nil {
		panic(Thrown{Value: "Null check operator used on a null value"})
	}
	return v
}

// MathTrunc implements std.math_trunc (returns an int, like num.truncate()).
func MathTrunc(v Value) Value { return int64(math.Trunc(asFloat(v))) }

// MathSign implements std.math_sign (num.sign: -1/0/1, preserving int-ness).
func MathSign(v Value) Value {
	if i, ok := unwrap(v).(int64); ok {
		switch {
		case i > 0:
			return int64(1)
		case i < 0:
			return int64(-1)
		default:
			return int64(0)
		}
	}
	f := asFloat(v)
	switch {
	case f > 0:
		return float64(1)
	case f < 0:
		return float64(-1)
	default:
		return f // preserves -0.0 / NaN
	}
}

// MathIsFinite implements std.math_is_finite.
func MathIsFinite(v Value) Value {
	f := asFloat(v)
	return !math.IsInf(f, 0) && !math.IsNaN(f)
}

// MathIsInfinite implements std.math_is_infinite.
func MathIsInfinite(v Value) Value { return math.IsInf(asFloat(v), 0) }

// MathClamp implements std.math_clamp (num.clamp).
func MathClamp(v, lo, hi Value) Value { return numClamp(v, lo, hi) }

// StrToInt implements std.string_to_int.
func StrToInt(v Value) Value {
	n, err := strconv.ParseInt(strings.TrimSpace(ToStr(v)), 10, 64)
	if err != nil {
		panic("ball: string_to_int: " + err.Error())
	}
	return n
}

// StrToDouble implements std.string_to_double.
func StrToDouble(v Value) Value {
	f, err := strconv.ParseFloat(strings.TrimSpace(ToStr(v)), 64)
	if err != nil {
		panic("ball: string_to_double: " + err.Error())
	}
	return f
}

// ── Math ────────────────────────────────────────────────────────────────────

// MathAbs implements std.math_abs.
func MathAbs(v Value) Value {
	if i, ok := v.(int64); ok {
		if i < 0 {
			return -i
		}
		return i
	}
	return math.Abs(asFloat(v))
}

// MathFloor implements std.math_floor (returns int, like Dart's num.floor()).
func MathFloor(v Value) Value { return int64(math.Floor(asFloat(v))) }

// MathCeil implements std.math_ceil.
func MathCeil(v Value) Value { return int64(math.Ceil(asFloat(v))) }

// MathRound implements std.math_round.
func MathRound(v Value) Value { return int64(math.Round(asFloat(v))) }

// MathSqrt implements std.math_sqrt.
func MathSqrt(v Value) Value { return math.Sqrt(asFloat(v)) }

// MathPow implements std.math_pow.
func MathPow(a, b Value) Value { return math.Pow(asFloat(a), asFloat(b)) }

// MathMin implements std.math_min, preserving int-ness when both are ints.
func MathMin(a, b Value) Value {
	if ai, bi, ok := bothInt(a, b); ok {
		if ai < bi {
			return ai
		}
		return bi
	}
	return math.Min(asFloat(a), asFloat(b))
}

// MathMax implements std.math_max.
func MathMax(a, b Value) Value {
	if ai, bi, ok := bothInt(a, b); ok {
		if ai > bi {
			return ai
		}
		return bi
	}
	return math.Max(asFloat(a), asFloat(b))
}

// ── Numeric conversion ──────────────────────────────────────────────────────

// ToInt implements std.to_int / num.toInt(). A numeric-string receiver is
// parsed: the proto3-JSON program view renders a Ball int64 literal as a string
// (`"10"`), and the engine reads it via `lit.intValue.toInt()`, so toInt on a
// string means "parse this int64 string".
func ToInt(v Value) Value {
	switch n := unwrap(v).(type) {
	case int64:
		return n
	case float64:
		return int64(n)
	case string:
		if i, err := strconv.ParseInt(strings.TrimSpace(n), 10, 64); err == nil {
			return i
		}
		if f, err := strconv.ParseFloat(strings.TrimSpace(n), 64); err == nil {
			return int64(f)
		}
		panic(Thrown{Value: "FormatException: " + n})
	}
	return int64(asFloat(v))
}

// ToDouble implements std.to_double / num.toDouble(). A numeric-string receiver
// is parsed (the doubleValue view path can hand a double literal through here).
func ToDouble(v Value) Value {
	if s, ok := unwrap(v).(string); ok {
		if f, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err == nil {
			return f
		}
		panic(Thrown{Value: "FormatException: " + s})
	}
	return asFloat(v)
}
