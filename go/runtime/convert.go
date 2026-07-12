package ballrt

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// std_convert base functions: JSON (order-preserving, Dart-jsonEncode-exact),
// UTF-8, and base64. Dart's jsonEncode preserves map insertion order and renders
// a whole double with a trailing .0, so JSON encoding is hand-written rather than
// delegated to encoding/json (which sorts keys and drops the .0).

// JSONEncode implements std_convert.json_encode (Dart jsonEncode).
func JSONEncode(v Value) Value {
	var b strings.Builder
	jsonEncodeInto(&b, unwrap(v))
	return b.String()
}

func jsonEncodeInto(b *strings.Builder, v Value) {
	switch x := unwrap(v).(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case float64:
		b.WriteString(formatDouble(x))
	case string:
		b.WriteString(jsonQuote(x))
	case []byte:
		b.WriteByte('[')
		for i, by := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(strconv.Itoa(int(by)))
		}
		b.WriteByte(']')
	case *List:
		b.WriteByte('[')
		for i, it := range x.Items {
			if i > 0 {
				b.WriteByte(',')
			}
			jsonEncodeInto(b, it)
		}
		b.WriteByte(']')
	case *Set:
		jsonEncodeInto(b, &List{Items: x.Items})
	case *Map:
		jsonEncodeMap(b, x)
	case *Message:
		jsonEncodeMap(b, x.Fields)
	default:
		b.WriteString(jsonQuote(ToStr(v)))
	}
}

func jsonEncodeMap(b *strings.Builder, m *Map) {
	b.WriteByte('{')
	for i, k := range m.keys {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsonQuote(k))
		b.WriteByte(':')
		val, _ := m.Get(k)
		jsonEncodeInto(b, val)
	}
	b.WriteByte('}')
}

// jsonQuote renders a Go string as a JSON string literal (Dart-compatible: escape
// control chars, quotes, backslashes; leave other Unicode as-is).
func jsonQuote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// JSONDecode implements std_convert.json_decode, producing ordered Ball values.
func JSONDecode(v Value) Value {
	dec := json.NewDecoder(strings.NewReader(ToStr(v)))
	dec.UseNumber()
	out, err := jsonDecodeValue(dec)
	if err != nil {
		panic(Thrown{Value: "FormatException: " + err.Error()})
	}
	return out
}

func jsonDecodeValue(dec *json.Decoder) (Value, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			m := NewMap()
			for dec.More() {
				keyTok, err := dec.Token()
				if err != nil {
					return nil, err
				}
				val, err := jsonDecodeValue(dec)
				if err != nil {
					return nil, err
				}
				m.Set(keyTok.(string), val)
			}
			_, err := dec.Token()
			return m, err
		case '[':
			l := NewList()
			for dec.More() {
				val, err := jsonDecodeValue(dec)
				if err != nil {
					return nil, err
				}
				l.Add(val)
			}
			_, err := dec.Token()
			return l, err
		}
		return nil, fmt.Errorf("unexpected %q", t)
	case string:
		return t, nil
	case bool:
		return t, nil
	case nil:
		return nil, nil
	case json.Number:
		if i, err := strconv.ParseInt(t.String(), 10, 64); err == nil && !strings.ContainsAny(t.String(), ".eE") {
			return i, nil
		}
		f, err := t.Float64()
		return f, err
	}
	return nil, fmt.Errorf("unexpected token %T", tok)
}

// UTF8Encode implements std_convert.utf8_encode: a string → its UTF-8 code units
// as a list of ints (Dart's utf8.encode → List<int>).
func UTF8Encode(v Value) Value {
	bytes := []byte(ToStr(v))
	out := make([]Value, len(bytes))
	for i, b := range bytes {
		out[i] = int64(b)
	}
	return &List{Items: out}
}

// UTF8Decode implements std_convert.utf8_decode: a byte list/bytes → a string.
func UTF8Decode(v Value) Value {
	return string(bytesOf(v))
}

// Base64Encode implements std_convert.base64_encode.
func Base64Encode(v Value) Value {
	return base64.StdEncoding.EncodeToString(bytesOf(v))
}

// Base64Decode implements std_convert.base64_decode, returning a list of byte
// ints (Dart's base64.decode → List<int>).
func Base64Decode(v Value) Value {
	raw, err := base64.StdEncoding.DecodeString(ToStr(v))
	if err != nil {
		panic(Thrown{Value: "FormatException: " + err.Error()})
	}
	out := make([]Value, len(raw))
	for i, b := range raw {
		out[i] = int64(b)
	}
	return &List{Items: out}
}

// bytesOf coerces a byte list / bytes / string to a raw byte slice.
func bytesOf(v Value) []byte {
	switch x := unwrap(v).(type) {
	case []byte:
		return x
	case string:
		return []byte(x)
	case *List:
		out := make([]byte, len(x.Items))
		for i, it := range x.Items {
			out[i] = byte(asInt64(it))
		}
		return out
	}
	panic(fmt.Sprintf("ball: expected bytes, got %T", v))
}
