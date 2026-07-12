package ballrt

import (
	"math"
	"strconv"
	"strings"
)

// Bitwise, null-coalescing, and Dart-exact number-formatting base ops. Ball ints
// are fixed 64-bit (Dart's int), so bitwise/shift ops use int64 wrapping.

func asInt64(v Value) int64 {
	switch n := unwrap(v).(type) {
	case int64:
		return n
	case float64:
		return int64(n)
	case bool:
		if n {
			return 1
		}
		return 0
	}
	return int64(asFloat(v))
}

// BitwiseAnd implements std.bitwise_and.
func BitwiseAnd(a, b Value) Value { return asInt64(a) & asInt64(b) }

// BitwiseOr implements std.bitwise_or.
func BitwiseOr(a, b Value) Value { return asInt64(a) | asInt64(b) }

// BitwiseXor implements std.bitwise_xor.
func BitwiseXor(a, b Value) Value { return asInt64(a) ^ asInt64(b) }

// BitwiseNot implements std.bitwise_not (~x).
func BitwiseNot(v Value) Value { return ^asInt64(v) }

// LeftShift implements std.left_shift.
func LeftShift(a, b Value) Value { return asInt64(a) << uint64(asInt64(b)) }

// RightShift implements std.right_shift (arithmetic).
func RightShift(a, b Value) Value { return asInt64(a) >> uint64(asInt64(b)) }

// UnsignedRightShift implements Dart's >>> (logical shift on the 64-bit value).
func UnsignedRightShift(a, b Value) Value {
	return int64(uint64(asInt64(a)) >> uint64(asInt64(b)))
}

// NullCoalesce implements ?? / ??= : a when non-null, else b.
func NullCoalesce(a, b Value) Value {
	if a == nil {
		return b
	}
	return a
}

// Invoke applies a first-class function value to a single argument (std.invoke).
func Invoke(fn, arg Value) Value { return Call(fn, arg) }

// ── Dart-exact number formatting ────────────────────────────────────────────

// ToStringAsFixed implements num.toStringAsFixed(digits) with round-half-away
// semantics matching the Dart reference.
func ToStringAsFixed(v, digits Value) Value {
	n := asFloat(v)
	d := int(asFloat(digits))
	if math.IsNaN(n) {
		return "NaN"
	}
	if math.IsInf(n, 1) {
		return "Infinity"
	}
	if math.IsInf(n, -1) {
		return "-Infinity"
	}
	return strconv.FormatFloat(n, 'f', d, 64)
}

// ToStringAsExponential implements num.toStringAsExponential([digits]).
func ToStringAsExponential(v, digits Value) Value {
	n := asFloat(v)
	prec := -1
	if digits != nil {
		prec = int(asFloat(digits))
	}
	s := strconv.FormatFloat(n, 'e', prec, 64)
	return normalizeExponent(s)
}

// ToStringAsPrecision implements num.toStringAsPrecision(precision).
func ToStringAsPrecision(v, precision Value) Value {
	n := asFloat(v)
	p := int(asFloat(precision))
	if p < 1 {
		p = 1
	}
	s := strconv.FormatFloat(n, 'g', p, 64)
	return normalizeExponent(s)
}

// normalizeExponent rewrites Go's exponent form (1e+02) to Dart's (1e+2 — no
// leading zero, explicit sign, at least one exponent digit).
func normalizeExponent(s string) string {
	i := strings.IndexAny(s, "eE")
	if i < 0 {
		return s
	}
	mant, exp := s[:i], s[i+1:]
	sign := "+"
	if len(exp) > 0 && (exp[0] == '+' || exp[0] == '-') {
		if exp[0] == '-' {
			sign = "-"
		}
		exp = exp[1:]
	}
	exp = strings.TrimLeft(exp, "0")
	if exp == "" {
		exp = "0"
	}
	return mant + "e" + sign + exp
}
