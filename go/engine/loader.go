package engine

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"

	ballrt "github.com/ball-lang/ball/go/runtime"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/encoding/protojson"
)

// Loader turns a typed Ball Program into the canonical proto3-JSON BallValue
// view the compiled self-hosted engine reads (epic #426 Phase 4) — the Go
// sibling of csharp/engine/src/Loader.cs and rust/engine/src/loader.rs.
//
// The view is a tree of insertion-ordered *ballrt.Map keyed by camelCase
// jsonNames, oneofs represented by which variant key is present, that the engine
// walks through the ball_proto access-pattern functions (whichExpr/hasBody/…).

// buildView serializes program with proto3 default values materialized (an
// absent repeated field becomes [], an absent string ""), then reconstructs the
// BallValue tree with the loader special-cases: a bytesValue base64 string is
// decoded to raw bytes, a doubleValue is forced to a Ball double, and each
// metadata Struct is re-expanded to the raw {fields:{key:Value}} proto shape.
func buildView(program *ballv1.Program) (ballrt.Value, error) {
	data, err := protojson.MarshalOptions{
		EmitDefaultValues: true,
		UseProtoNames:     false,
	}.Marshal(program)
	if err != nil {
		return nil, fmt.Errorf("serialize program view: %w", err)
	}

	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	value, err := decodeValue(dec, "")
	if err != nil {
		return nil, fmt.Errorf("decode program view: %w", err)
	}
	return normalizeMetadata(value), nil
}

// decodeValue reads one JSON value from dec, preserving object key order. key is
// the object key this value is stored under (for the bytesValue/doubleValue
// special-cases), or "" at the root / inside an array.
func decodeValue(dec *json.Decoder, key string) (ballrt.Value, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			return decodeObject(dec)
		case '[':
			return decodeArray(dec)
		}
		return nil, fmt.Errorf("unexpected delimiter %q", t)
	case string:
		if key == "bytesValue" {
			raw, err := base64.StdEncoding.DecodeString(t)
			if err != nil {
				return nil, fmt.Errorf("decode bytesValue: %w", err)
			}
			return raw, nil
		}
		return t, nil
	case json.Number:
		return decodeNumber(t, key)
	case bool:
		return t, nil
	case nil:
		return nil, nil
	}
	return nil, fmt.Errorf("unexpected token %T", tok)
}

func decodeObject(dec *json.Decoder) (ballrt.Value, error) {
	m := ballrt.NewMap()
	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := keyTok.(string)
		if !ok {
			return nil, fmt.Errorf("object key not a string: %T", keyTok)
		}
		val, err := decodeValue(dec, key)
		if err != nil {
			return nil, err
		}
		m.Set(key, val)
	}
	// Consume the closing '}'.
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	return m, nil
}

func decodeArray(dec *json.Decoder) (ballrt.Value, error) {
	l := ballrt.NewList()
	for dec.More() {
		val, err := decodeValue(dec, "")
		if err != nil {
			return nil, err
		}
		l.Add(val)
	}
	// Consume the closing ']'.
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	return l, nil
}

// decodeNumber turns a JSON number into a Ball int or double. A doubleValue
// literal is always a double, even when proto3-JSON renders a whole double (9.0)
// as a bare integer (9); every other integral number is a Ball int.
func decodeNumber(n json.Number, key string) (ballrt.Value, error) {
	if key == "doubleValue" {
		f, err := n.Float64()
		if err != nil {
			return nil, err
		}
		return f, nil
	}
	if i, err := strconv.ParseInt(n.String(), 10, 64); err == nil {
		return i, nil
	}
	f, err := n.Float64()
	if err != nil {
		return nil, err
	}
	return f, nil
}

// normalizeMetadata reconstructs the raw google.protobuf.Struct proto shape for
// every metadata field (proto3-JSON collapses a Struct to a plain object, but
// the engine reads metadata through the proto object API).
func normalizeMetadata(value ballrt.Value) ballrt.Value {
	switch v := value.(type) {
	case *ballrt.Map:
		out := ballrt.NewMap()
		for _, key := range v.Keys() {
			val, _ := v.Get(key)
			if key == "metadata" {
				if structMap, ok := val.(*ballrt.Map); ok {
					out.Set(key, wrapStruct(structMap))
					continue
				}
			}
			out.Set(key, normalizeMetadata(val))
		}
		return out
	case *ballrt.List:
		out := ballrt.NewList()
		for _, item := range v.Items {
			out.Add(normalizeMetadata(item))
		}
		return out
	default:
		return value
	}
}

// wrapStruct turns a collapsed metadata object into the raw Struct shape
// {fields:{key:Value}}.
func wrapStruct(m *ballrt.Map) ballrt.Value {
	fields := ballrt.NewMap()
	for _, key := range m.Keys() {
		val, _ := m.Get(key)
		fields.Set(key, wrapValue(val))
	}
	out := ballrt.NewMap()
	out.Set("fields", fields)
	return out
}

// wrapValue turns a plain metadata value into a google.protobuf.Value wrapper
// (the arm keyed by its kind).
func wrapValue(value ballrt.Value) ballrt.Value {
	out := ballrt.NewMap()
	switch v := value.(type) {
	case nil:
		out.Set("nullValue", int64(0))
	case bool:
		out.Set("boolValue", v)
	case int64:
		out.Set("numberValue", float64(v))
	case float64:
		out.Set("numberValue", v)
	case string:
		out.Set("stringValue", v)
	case *ballrt.List:
		values := ballrt.NewList()
		for _, item := range v.Items {
			values.Add(wrapValue(item))
		}
		listValue := ballrt.NewMap()
		listValue.Set("values", values)
		out.Set("listValue", listValue)
	case *ballrt.Map:
		out.Set("structValue", wrapStruct(v))
	default:
		out.Set("stringValue", ballrt.ToStr(v))
	}
	return out
}
