package ballrt

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// ── Numeric coercion ────────────────────────────────────────────────────────

// asFloat coerces a numeric Ball value to float64. Panics loudly (fail-loud
// doctrine, issue #55) on a non-numeric operand rather than silently yielding 0.
func asFloat(v Value) float64 {
	switch n := v.(type) {
	case int64:
		return float64(n)
	case float64:
		return n
	case int:
		return float64(n)
	case bool:
		if n {
			return 1
		}
		return 0
	case *Message:
		if u := unwrap(n); u != Value(n) {
			return asFloat(u)
		}
	case string:
		panic(fmt.Sprintf("ball: expected a number, got string %q", n))
	}
	panic(fmt.Sprintf("ball: expected a number, got %T", v))
}

// bothInt reports whether a and b are both Ball ints (int64), so an operation
// stays integer (Dart keeps int+int → int, int+double → double).
func bothInt(a, b Value) (int64, int64, bool) {
	ai, aok := a.(int64)
	bi, bok := b.(int64)
	return ai, bi, aok && bok
}

// ── Arithmetic ──────────────────────────────────────────────────────────────

// Add implements Ball std.add: numeric addition, or string/list concatenation
// when both operands are strings/lists (Dart's `+`).
func Add(a, b Value) Value {
	if as, ok := a.(string); ok {
		if bs, ok := b.(string); ok {
			return as + bs
		}
	}
	if al, ok := a.(*List); ok {
		if bl, ok := b.(*List); ok {
			out := make([]Value, 0, len(al.Items)+len(bl.Items))
			out = append(out, al.Items...)
			out = append(out, bl.Items...)
			return &List{Items: out}
		}
	}
	if ai, bi, ok := bothInt(a, b); ok {
		return ai + bi
	}
	return asFloat(a) + asFloat(b)
}

// Sub implements std.subtract.
func Sub(a, b Value) Value {
	if ai, bi, ok := bothInt(a, b); ok {
		return ai - bi
	}
	return asFloat(a) - asFloat(b)
}

// Mul implements std.multiply.
func Mul(a, b Value) Value {
	if ai, bi, ok := bothInt(a, b); ok {
		return ai * bi
	}
	return asFloat(a) * asFloat(b)
}

// IntDiv implements std.divide (Dart's `~/` — truncating integer division).
func IntDiv(a, b Value) Value {
	if ai, bi, ok := bothInt(a, b); ok {
		return ai / bi
	}
	return int64(asFloat(a) / asFloat(b))
}

// DivDouble implements std.divide_double (Dart's `/` — always double).
func DivDouble(a, b Value) Value {
	return asFloat(a) / asFloat(b)
}

// Modulo implements std.modulo with Dart's `%` semantics: the result is always
// non-negative, in the range `0 <= r < b.abs()` (so `-7 % 3 == 2`, `7 % -3 ==
// 1`), unlike Go's `%` which follows the dividend's sign.
func Modulo(a, b Value) Value {
	if ai, bi, ok := bothInt(a, b); ok {
		m := ai % bi
		if m < 0 {
			if bi < 0 {
				m -= bi
			} else {
				m += bi
			}
		}
		return m
	}
	af, bf := asFloat(a), asFloat(b)
	m := math.Mod(af, bf)
	if m < 0 {
		m += math.Abs(bf)
	}
	return m
}

// Negate implements std.negate (unary `-`).
func Negate(v Value) Value {
	if i, ok := v.(int64); ok {
		return -i
	}
	return -asFloat(v)
}

// ── Comparison ──────────────────────────────────────────────────────────────

// cmp returns -1/0/1 comparing two numeric or string operands.
func cmp(a, b Value) int {
	if as, ok := a.(string); ok {
		if bs, ok := b.(string); ok {
			return strings.Compare(as, bs)
		}
	}
	af, bf := asFloat(a), asFloat(b)
	switch {
	case af < bf:
		return -1
	case af > bf:
		return 1
	default:
		return 0
	}
}

// Lt implements std.less_than.
func Lt(a, b Value) bool { return cmp(a, b) < 0 }

// Gt implements std.greater_than.
func Gt(a, b Value) bool { return cmp(a, b) > 0 }

// Lte implements std.lte.
func Lte(a, b Value) bool { return cmp(a, b) <= 0 }

// Gte implements std.gte.
func Gte(a, b Value) bool { return cmp(a, b) >= 0 }

// Eq implements std.equals, promoting int/double so `1 == 1.0` is true (Dart).
func Eq(a, b Value) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	// Numeric cross-type promotion.
	if isNum(a) && isNum(b) {
		return asFloat(a) == asFloat(b)
	}
	switch av := a.(type) {
	case string:
		bv, ok := b.(string)
		return ok && av == bv
	case bool:
		bv, ok := b.(bool)
		return ok && av == bv
	}
	// Reference identity for aggregates (Dart's default ==).
	return a == b
}

// Neq implements std.not_equals.
func Neq(a, b Value) bool { return !Eq(a, b) }

func isNum(v Value) bool {
	switch v.(type) {
	case int64, float64, int:
		return true
	}
	return false
}

// ── Logic ───────────────────────────────────────────────────────────────────

// Truthy coerces a Ball value to a Go bool for use in native `if`/`for`/`&&`.
// A bool is itself; everything else follows Dart's rule that only `true` is
// truthy (non-bool conditions are a type error in Dart, but we accept the
// common cases loosely: nil → false).
func Truthy(v Value) bool {
	switch b := v.(type) {
	case bool:
		return b
	case nil:
		return false
	}
	return true
}

// Not implements std.not.
func Not(v Value) bool { return !Truthy(v) }

// ── Strings & conversion ────────────────────────────────────────────────────

// Concat implements std.concat / std.string_concat (string `+`).
func Concat(a, b Value) Value {
	return ToStr(a) + ToStr(b)
}

// ToStr implements std.to_string: the Ball value's Dart-flavored string form.
func ToStr(v Value) string {
	switch x := v.(type) {
	case nil:
		return "null"
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case int:
		return strconv.Itoa(x)
	case float64:
		return formatDouble(x)
	case *List:
		var sb strings.Builder
		sb.WriteByte('[')
		for i, it := range x.Items {
			if i > 0 {
				sb.WriteString(", ")
			}
			sb.WriteString(ToStr(it))
		}
		sb.WriteByte(']')
		return sb.String()
	case *Map:
		var sb strings.Builder
		sb.WriteByte('{')
		for i, k := range x.keys {
			if i > 0 {
				sb.WriteString(", ")
			}
			val, _ := x.Get(k)
			sb.WriteString(k)
			sb.WriteString(": ")
			sb.WriteString(ToStr(val))
		}
		sb.WriteByte('}')
		return sb.String()
	case *Set:
		var sb strings.Builder
		sb.WriteByte('{')
		for i, it := range x.Items {
			if i > 0 {
				sb.WriteString(", ")
			}
			sb.WriteString(ToStr(it))
		}
		sb.WriteByte('}')
		return sb.String()
	case *Message:
		if u := unwrap(x); u != Value(x) {
			return ToStr(u)
		}
		return x.TypeName
	case *Function:
		return "Closure"
	default:
		return fmt.Sprintf("%v", v)
	}
}

// formatDouble renders a float64 the way Dart's `toString()` does: an integral
// double keeps a trailing `.0` (e.g. 10.0 → "10.0"), otherwise the shortest
// round-tripping form.
func formatDouble(f float64) string {
	if math.IsInf(f, 1) {
		return "Infinity"
	}
	if math.IsInf(f, -1) {
		return "-Infinity"
	}
	if math.IsNaN(f) {
		return "NaN"
	}
	if f == math.Trunc(f) && math.Abs(f) < 1e21 {
		// Integral value → force a `.0` suffix like Dart (10.0 → "10.0").
		return strconv.FormatFloat(f, 'f', 1, 64)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// Length implements std.length / std.string_length.
func Length(v Value) Value {
	switch x := v.(type) {
	case string:
		return int64(len([]rune(x)))
	case *List:
		return int64(len(x.Items))
	case *Map:
		return int64(x.Len())
	case []byte:
		return int64(len(x))
	}
	panic(fmt.Sprintf("ball: length: unsupported operand %T", v))
}
