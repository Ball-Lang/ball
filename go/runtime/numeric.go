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
//
// Dart's (and ECMAScript's) toStringAsFixed / toStringAsExponential /
// toStringAsPrecision differ from Go's strconv.FormatFloat in two ways that MUST
// match for conformance: round-half-AWAY-from-zero on an exact decimal tie
// (`(-2.5).toStringAsFixed(0)` → "-3", `2.5.toStringAsExponential(0)` → "3e+0",
// where Go's ties-to-even gives "-2"/"2e+0"), and a *minimal* exponent
// (`1.23e+2`, never `e+02`) with trailing-zero padding. Ported from the proven
// Rust runtime (rust/shared/src/runtime.rs) / C++ emission: extract the value's
// EXACT decimal digits and round the digit string ourselves. Formatting a
// double with 1080 fraction digits yields its exact decimal expansion (a double
// needs at most 767), so the discarded tail is exact and "away on a tie" reduces
// to the simple test `D[k] >= '5'`.

// roundSigDigits rounds the exact significant digits of ax (finite, > 0) to k
// significant digits, half away from zero. Returns the k-digit string and the
// decimal exponent of the leading digit (value = D[0].D[1..] × 10^E); a rounding
// carry (9.99 → 10) bumps the exponent.
func roundSigDigits(ax float64, k int) (string, int) {
	s := strconv.FormatFloat(ax, 'e', 1080, 64)
	epos := strings.IndexByte(s, 'e')
	exp, _ := strconv.Atoi(s[epos+1:])
	digits := s[:1] + s[2:epos] // strip the '.'
	if len(digits) <= k {
		return digits + strings.Repeat("0", k-len(digits)), exp
	}
	roundUp := digits[k] >= '5'
	kept := []byte(digits[:k])
	if roundUp {
		carried := true
		for i := len(kept) - 1; i >= 0; i-- {
			if kept[i] != '9' {
				kept[i]++
				carried = false
				break
			}
			kept[i] = '0'
		}
		if carried {
			trimTo := k - 1
			if trimTo < 0 {
				trimTo = 0
			}
			kept = append([]byte{'1'}, kept[:trimTo]...)
			exp++
		}
	}
	return string(kept), exp
}

// dartExponent appends Dart's minimal exponent suffix (`e+2` / `e-4`).
func dartExponent(e int) string {
	sign := "+"
	if e < 0 {
		sign = "-"
		e = -e
	}
	return "e" + sign + strconv.Itoa(e)
}

// fixedAwayFromZero renders a finite ax > 0 with d fraction digits, rounding
// half away from zero on an exact decimal tie.
func fixedAwayFromZero(ax float64, d int) string {
	s := strconv.FormatFloat(ax, 'e', 1080, 64)
	epos := strings.IndexByte(s, 'e')
	exp, _ := strconv.Atoi(s[epos+1:])
	k := exp + 1 + d
	var m string
	var e2 int
	if k <= 0 {
		// Every significant digit is dropped. At k == 0 the leading digit sits one
		// place below the last kept fraction place, so `>= 5` rounds up to a `1`.
		if k == 0 && s[0] >= '5' {
			m, e2 = "1", exp+1
		} else if d > 0 {
			return "0." + strings.Repeat("0", d)
		} else {
			return "0"
		}
	} else {
		m, e2 = roundSigDigits(ax, k)
	}
	intd := e2 + 1
	var intPart, frac string
	if intd <= 0 {
		intPart = "0"
		frac = strings.Repeat("0", -intd) + m
	} else if len(m) >= intd {
		intPart = m[:intd]
		frac = m[intd:]
	} else {
		// A rounding carry can leave fewer significant digits than integer places.
		intPart = m + strings.Repeat("0", intd-len(m))
	}
	for len(frac) < d {
		frac += "0"
	}
	frac = frac[:d]
	if d > 0 {
		return intPart + "." + frac
	}
	return intPart
}

// ToStringAsFixed implements num.toStringAsFixed(digits) (round half away).
func ToStringAsFixed(v, digits Value) Value {
	n := asFloat(v)
	d := int(asFloat(digits))
	if math.IsNaN(n) {
		return "NaN"
	}
	if math.IsInf(n, 0) {
		if n < 0 {
			return "-Infinity"
		}
		return "Infinity"
	}
	neg := math.Signbit(n)
	ax := math.Abs(n)
	var formatted string
	if ax == 0.0 {
		if d > 0 {
			formatted = "0." + strings.Repeat("0", d)
		} else {
			formatted = "0"
		}
	} else {
		formatted = fixedAwayFromZero(ax, d)
	}
	if neg {
		formatted = "-" + formatted
	}
	// A value that renders as all zeros drops the sign; the engine's own handler
	// re-adds it for a genuinely negative receiver (negative-zero parity, #101).
	if strings.HasPrefix(formatted, "-") && isAllZeroOrDot(formatted[1:]) {
		formatted = formatted[1:]
	}
	return formatted
}

func isAllZeroOrDot(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != '0' && s[i] != '.' {
			return false
		}
	}
	return true
}

// ToStringAsExponential implements num.toStringAsExponential([digits]). A nil
// digits means the no-argument form (shortest round-trip mantissa).
func ToStringAsExponential(v, digits Value) Value {
	x := asFloat(v)
	if math.IsNaN(x) {
		return "NaN"
	}
	if math.IsInf(x, 0) {
		if x < 0 {
			return "-Infinity"
		}
		return "Infinity"
	}
	neg := math.Signbit(x)
	ax := math.Abs(x)
	var out string
	if digits == nil {
		s := strconv.FormatFloat(ax, 'e', -1, 64)
		epos := strings.IndexByte(s, 'e')
		e, _ := strconv.Atoi(s[epos+1:])
		out = s[:epos] + dartExponent(e)
	} else {
		d := int(asFloat(digits))
		if ax == 0.0 {
			out = "0"
			if d > 0 {
				out += "." + strings.Repeat("0", d)
			}
			out += "e+0"
		} else {
			m, e := roundSigDigits(ax, d+1)
			out = m[:1]
			if d > 0 {
				out += "." + m[1:]
			}
			out += dartExponent(e)
		}
	}
	if neg {
		out = "-" + out
	}
	return out
}

// ToStringAsPrecision implements num.toStringAsPrecision(precision): p
// significant digits, choosing fixed vs exponential form by ECMAScript's rule
// (exponent < -6 or >= p ⇒ exponential).
func ToStringAsPrecision(v, precision Value) Value {
	x := asFloat(v)
	if math.IsNaN(x) {
		return "NaN"
	}
	if math.IsInf(x, 0) {
		if x < 0 {
			return "-Infinity"
		}
		return "Infinity"
	}
	p := int(asFloat(precision))
	if p < 1 {
		p = 1
	}
	neg := math.Signbit(x)
	ax := math.Abs(x)
	var out string
	if ax == 0.0 {
		out = "0"
		if p > 1 {
			out += "." + strings.Repeat("0", p-1)
		}
	} else {
		m, e := roundSigDigits(ax, p)
		switch {
		case e < -6 || e >= p:
			out = m[:1]
			if p > 1 {
				out += "." + m[1:]
			}
			out += dartExponent(e)
		case e >= 0:
			intd := e + 1
			out = m[:intd]
			if p > intd {
				out += "." + m[intd:]
			}
		default:
			out = "0." + strings.Repeat("0", -e-1) + m
		}
	}
	if neg {
		out = "-" + out
	}
	return out
}
