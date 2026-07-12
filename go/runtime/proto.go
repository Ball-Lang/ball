package ballrt

// ball_proto access-pattern base functions (epic #426 Phase 4) — the
// protobuf-compatibility layer the self-hosted engine reads its
// already-deserialized target program through. These have isBase:true and no
// body (invariant #3); this file is their Go implementation, the sibling of
// rust/engine/src/ball_proto.rs and csharp/shared/src/BallProto.cs, operating on
// the canonical proto3-JSON view the engine loader produces (a tree of
// insertion-ordered *Map keyed by camelCase jsonNames, oneofs represented by
// which variant key is present).
//
// Semantics match dart/shared/lib/ball_proto.dart (the authoritative definition)
// exactly: a discriminator returns the name of whichever variant key is present
// (declaration order, first wins) or "notSet"; a presence check follows the
// proto3 rule that an absent key / explicit null / empty string / empty
// list/map all read as not-present.

// Oneof variant keys of each discriminated message, in ball_proto.dart's check
// order (first present key wins). Keys are canonical proto3 jsonNames.
var (
	protoExprVariants      = []string{"call", "literal", "reference", "fieldAccess", "messageCreation", "block", "lambda"}
	protoLiteralVariants   = []string{"intValue", "doubleValue", "stringValue", "boolValue", "bytesValue", "listValue"}
	protoStmtVariants      = []string{"let", "expression"}
	protoValueKindVariants = []string{"nullValue", "numberValue", "stringValue", "boolValue", "structValue", "listValue"}
	protoSourceVariants    = []string{"http", "file", "git", "registry", "inline"}
)

// asFields returns the field map of a *Map or *Message value, or nil otherwise.
func asFields(obj Value) *Map {
	switch o := obj.(type) {
	case *Map:
		return o
	case *Message:
		return o.Fields
	}
	return nil
}

// protoWhich returns the first variant key present (and non-null) on obj, or
// "notSet". A non-map input has no oneof set, so it is "notSet" too.
func protoWhich(obj Value, variants []string) Value {
	if fields := asFields(obj); fields != nil {
		for _, variant := range variants {
			if v, ok := fields.Get(variant); ok && v != nil {
				return variant
			}
		}
	}
	return "notSet"
}

// WhichExpr reports which Expression oneof arm is set.
func WhichExpr(obj Value) Value { return protoWhich(obj, protoExprVariants) }

// WhichValue reports which Literal value arm is set.
func WhichValue(obj Value) Value { return protoWhich(obj, protoLiteralVariants) }

// WhichStmt reports which Statement arm is set.
func WhichStmt(obj Value) Value { return protoWhich(obj, protoStmtVariants) }

// WhichKind reports which google.protobuf.Value kind is set.
func WhichKind(obj Value) Value { return protoWhich(obj, protoValueKindVariants) }

// WhichSource reports which ModuleImport source is set.
func WhichSource(obj Value) Value { return protoWhich(obj, protoSourceVariants) }

// HasField reports whether field is present and non-default on obj (the proto3
// rule: absent / null / "" / [] / {} all read as not present).
func HasField(obj Value, field string) Value {
	fields := asFields(obj)
	if fields == nil {
		return false
	}
	v, ok := fields.Get(field)
	if !ok || v == nil {
		return false
	}
	switch x := v.(type) {
	case string:
		return len(x) != 0
	case *List:
		return x.Len() != 0
	case *Map:
		return x.Len() != 0
	case *Message:
		return x.Fields.Len() != 0
	default:
		return true
	}
}

// GetField reads name from obj, or null if missing / not a map.
func GetField(obj, name Value) Value {
	fields := asFields(obj)
	if fields == nil {
		return nil
	}
	v, _ := fields.Get(protoStr(name))
	return v
}

// GetFieldOr reads name from obj, or def if missing / null.
func GetFieldOr(obj, name, def Value) Value {
	fields := asFields(obj)
	if fields == nil {
		return def
	}
	v, ok := fields.Get(protoStr(name))
	if !ok || v == nil {
		return def
	}
	return v
}

// SetFieldValue sets name on a map/message and returns it (a non-map/message obj
// is returned unchanged — matching ball_proto.dart's permissive setter). Named
// SetFieldValue (not SetField) to avoid colliding with the FieldSet helper.
func SetFieldValue(obj, name, value Value) Value {
	switch o := obj.(type) {
	case *Map:
		o.Set(protoStr(name), value)
	case *Message:
		o.Fields.Set(protoStr(name), value)
	}
	return obj
}

// structFields returns the `fields` submap of a raw google.protobuf.Struct shape
// ({fields:{key:Value}}), or the object's own field map when already flat.
func structFields(structValue Value) *Map {
	fields := asFields(structValue)
	if fields == nil {
		return nil
	}
	if inner, ok := fields.Get("fields"); ok {
		if m, ok := inner.(*Map); ok {
			return m
		}
	}
	return fields
}

// valueArm returns the value carried by arm of a google.protobuf.Value map.
func valueArm(value Value, arm string) Value {
	fields := asFields(value)
	if fields == nil {
		return nil
	}
	v, _ := fields.Get(arm)
	return v
}

// GetStructField reads the raw Value map at key of a Struct, or null.
func GetStructField(structValue, key Value) Value {
	fields := structFields(structValue)
	if fields == nil {
		return nil
	}
	v, _ := fields.Get(protoStr(key))
	return v
}

// GetStringField reads the string value at key of a Struct, or "".
func GetStringField(structValue, key Value) Value {
	if s, ok := valueArm(GetStructField(structValue, key), "stringValue").(string); ok {
		return s
	}
	return ""
}

// GetBoolField reads the bool value at key of a Struct, or false.
func GetBoolField(structValue, key Value) Value {
	if b, ok := valueArm(GetStructField(structValue, key), "boolValue").(bool); ok {
		return b
	}
	return false
}

// GetListField reads the list value at key of a Struct, or [].
func GetListField(structValue, key Value) Value {
	arm := valueArm(GetStructField(structValue, key), "listValue")
	if lv, ok := arm.(*Map); ok {
		if inner, ok := lv.Get("values"); ok {
			if l, ok := inner.(*List); ok {
				return l
			}
		}
	}
	if l, ok := arm.(*List); ok {
		return l
	}
	return NewList()
}

// GetNumberField reads the number value at key of a Struct, or 0.
func GetNumberField(structValue, key Value) Value {
	arm := valueArm(GetStructField(structValue, key), "numberValue")
	switch n := arm.(type) {
	case float64:
		return n
	case int64:
		return n
	}
	return float64(0)
}

// GetStructFieldKeys returns every key of a Struct/metadata map, in order.
func GetStructFieldKeys(structValue Value) Value {
	fields := structFields(structValue)
	out := NewList()
	if fields != nil {
		for _, k := range fields.keys {
			out.Add(k)
		}
	}
	return out
}

// EnsureDefaults is a pass-through — the loader materializes proto3 defaults.
func EnsureDefaults(obj, messageType Value) Value { return obj }

// DefaultString returns the proto3 default for a string field.
func DefaultString() Value { return "" }

// DefaultList returns the proto3 default for a repeated field.
func DefaultList() Value { return NewList() }

// DefaultBool returns the proto3 default for a bool field.
func DefaultBool() Value { return false }

// DefaultInt returns the proto3 default for an int field.
func DefaultInt() Value { return int64(0) }

// ExprCase validates an Expression oneof case name (identity when known).
func ExprCase(name Value) Value { return protoStr(name) }

// LiteralCase validates a Literal value case name (identity).
func LiteralCase(name Value) Value { return protoStr(name) }

// StmtCase validates a Statement oneof case name (identity).
func StmtCase(name Value) Value { return protoStr(name) }

// VirtualProperty resolves a virtual (computed) property Ball programs read as a
// bare field access on a native value (`.length`/`.isEmpty`/`.first`/`.keys`/…),
// or returns (nil, false) when name is not a virtual property of the value's
// type — the sibling of ball_proto.rs's virtual_property.
func VirtualProperty(value Value, name string) (Value, bool) {
	switch name {
	case "runtimeType":
		return runtimeTypeName(value), true
	case "hashCode":
		return int64(0), true
	}
	switch v := unwrap(value).(type) {
	case string:
		u := utf16Units(v)
		switch name {
		case "length":
			return int64(len(u)), true
		case "isEmpty":
			return len(v) == 0, true
		case "isNotEmpty":
			return len(v) != 0, true
		case "runes", "codeUnits":
			return UTF8Encode(v), true
		case "hashCode":
			return int64(0), true
		}
	case *List:
		switch name {
		case "length":
			return int64(v.Len()), true
		case "isEmpty":
			return v.Len() == 0, true
		case "isNotEmpty":
			return v.Len() != 0, true
		case "first":
			return ListFirst(v), true
		case "last":
			return ListLast(v), true
		case "single":
			if v.Len() != 1 {
				panic(Thrown{Value: "Bad state: too many/few elements"})
			}
			return v.Items[0], true
		case "reversed":
			return ListReverse(v), true
		}
	case *Set:
		switch name {
		case "length":
			return int64(len(v.Items)), true
		case "isEmpty":
			return len(v.Items) == 0, true
		case "isNotEmpty":
			return len(v.Items) != 0, true
		case "first":
			if len(v.Items) == 0 {
				panic(Thrown{Value: "Bad state: No element"})
			}
			return v.Items[0], true
		}
	case *Map:
		switch name {
		case "length":
			return int64(v.Len()), true
		case "isEmpty":
			return v.Len() == 0, true
		case "isNotEmpty":
			return v.Len() != 0, true
		case "keys":
			return MapKeys(v), true
		case "values":
			return MapValues(v), true
		case "entries":
			return mapEntries(v), true
		}
	case []byte:
		if name == "length" {
			return int64(len(v)), true
		}
	case int64, float64:
		switch name {
		case "isEven":
			return asInt64(v)%2 == 0, true
		case "isOdd":
			return asInt64(v)%2 != 0, true
		case "isNegative":
			return asFloat(v) < 0, true
		case "isNaN":
			return MathIsInfinite(v) == false && asFloat(v) != asFloat(v), true
		case "isFinite":
			return MathIsFinite(v), true
		case "isInfinite":
			return MathIsInfinite(v), true
		case "sign":
			return MathSign(v), true
		}
	}
	return nil, false
}

// mapEntries returns a map's entries as a list of {key, value} MapEntry views.
func mapEntries(m *Map) Value {
	out := NewList()
	for _, k := range m.keys {
		v, _ := m.Get(k)
		entry := NewMap()
		entry.Set("key", k)
		entry.Set("value", v)
		out.Add(NewMessage("MapEntry", entry))
	}
	return out
}

// protoStr coerces a Ball value to a Go string for a proto key/name argument.
func protoStr(value Value) string {
	if s, ok := value.(string); ok {
		return s
	}
	return ToStr(value)
}
