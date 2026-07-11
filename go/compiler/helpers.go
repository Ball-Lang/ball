package compiler

import (
	"strconv"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// goKeywords are the reserved words a sanitized Ball identifier must not collide
// with. A colliding name is prefixed with "ball_".
var goKeywords = map[string]bool{
	"break": true, "case": true, "chan": true, "const": true, "continue": true,
	"default": true, "defer": true, "else": true, "fallthrough": true, "for": true,
	"func": true, "go": true, "goto": true, "if": true, "import": true,
	"interface": true, "map": true, "package": true, "range": true, "return": true,
	"select": true, "struct": true, "switch": true, "type": true, "var": true,
}

// reservedEmitted are identifiers the compiler itself emits; a user name that
// sanitizes to one of these is prefixed to avoid capture.
var reservedEmitted = map[string]bool{
	"input": true, "ballrt": true, "main": true,
	"__ret": true, "__m": true, "__v": true,
}

// sanitize turns a Ball name into a valid, non-colliding Go identifier. Invalid
// characters become "_"; a leading digit, a Go keyword, or a compiler-reserved
// name is prefixed with "ball_".
func sanitize(name string) string {
	if name == "" {
		return "ball_anon"
	}
	var b strings.Builder
	for i, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r == '_':
			b.WriteRune(r)
		case r >= '0' && r <= '9':
			if i == 0 {
				b.WriteString("ball_")
			}
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	s := b.String()
	if goKeywords[s] || reservedEmitted[s] {
		return "ball_" + s
	}
	return s
}

// funcParams returns a function's declared parameter names from its
// metadata.params list (the encoders' convention for surfacing readable
// parameter names — e.g. fibonacci's "n"). Empty when the function takes no
// named parameter.
func funcParams(f *ballv1.FunctionDefinition) []string {
	meta := f.GetMetadata()
	if meta == nil {
		return nil
	}
	pv, ok := meta.GetFields()["params"]
	if !ok {
		return nil
	}
	lv := pv.GetListValue()
	if lv == nil {
		return nil
	}
	var out []string
	for _, v := range lv.GetValues() {
		sv := v.GetStructValue()
		if sv == nil {
			continue
		}
		if nameV, ok := sv.GetFields()["name"]; ok {
			if n := nameV.GetStringValue(); n != "" {
				out = append(out, n)
			}
		}
	}
	return out
}

// goFloat renders a float64 as a valid Go floating-point literal (always
// carrying a decimal point or exponent so it is typed float64, never int).
func goFloat(f float64) string {
	s := strconv.FormatFloat(f, 'g', -1, 64)
	// Ensure the literal reads as a float (add ".0" if it looks integral and has
	// no exponent).
	if !strings.ContainsAny(s, ".eEpPnN") {
		s += ".0"
	}
	return s
}

// goBytes renders a byte slice as a Go []byte composite literal.
func goBytes(bs []byte) string {
	if len(bs) == 0 {
		return "[]byte{}"
	}
	parts := make([]string, len(bs))
	for i, x := range bs {
		parts[i] = strconv.Itoa(int(x))
	}
	return "[]byte{" + strings.Join(parts, ", ") + "}"
}

// indent prefixes every non-empty line of s with prefix. Purely cosmetic — Go
// is not whitespace-sensitive and the output is gofmt'd — but it keeps the raw
// emission readable when debugging a gofmt failure.
func indent(s, prefix string) string {
	if s == "" {
		return ""
	}
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	var b strings.Builder
	for _, ln := range lines {
		if ln == "" {
			b.WriteByte('\n')
			continue
		}
		b.WriteString(prefix)
		b.WriteString(ln)
		b.WriteByte('\n')
	}
	return b.String()
}

// fieldMap indexes a call's input MessageCreation fields by name, for base
// functions that read named inputs (BinaryInput's left/right, etc.). Returns nil
// when the input is not a message (e.g. a single positional value).
func fieldMap(call *ballv1.FunctionCall) map[string]*ballv1.Expression {
	in := call.GetInput()
	if in == nil {
		return nil
	}
	mc := in.GetMessageCreation()
	if mc == nil {
		return nil
	}
	out := map[string]*ballv1.Expression{}
	for _, fv := range mc.GetFields() {
		out[fv.GetName()] = fv.GetValue()
	}
	return out
}

// stringLiteralField reads a field whose value is a plain string literal (e.g. a
// for_in loop's "variable", a labeled break's "label"). Returns "" if absent.
func stringLiteralField(f map[string]*ballv1.Expression, name string) string {
	e, ok := f[name]
	if !ok {
		return ""
	}
	if lit := e.GetLiteral(); lit != nil {
		return lit.GetStringValue()
	}
	return ""
}
