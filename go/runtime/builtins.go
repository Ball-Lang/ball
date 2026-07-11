package ballrt

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Print implements std.print: write the value's string form followed by a
// newline to stdout. Returns nil (Ball void).
func Print(v Value) Value {
	fmt.Println(ToStr(v))
	return nil
}

// ── String operations ───────────────────────────────────────────────────────

// StrUpper implements std.string_to_upper.
func StrUpper(v Value) Value { return strings.ToUpper(ToStr(v)) }

// StrLower implements std.string_to_lower.
func StrLower(v Value) Value { return strings.ToLower(ToStr(v)) }

// StrTrim implements std.string_trim.
func StrTrim(v Value) Value { return strings.TrimSpace(ToStr(v)) }

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

// ToInt implements std.to_int (Dart num.toInt()).
func ToInt(v Value) Value {
	switch n := v.(type) {
	case int64:
		return n
	case float64:
		return int64(n)
	}
	return int64(asFloat(v))
}

// ToDouble implements std.to_double.
func ToDouble(v Value) Value { return asFloat(v) }
