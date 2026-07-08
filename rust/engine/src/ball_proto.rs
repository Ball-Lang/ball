//! `ball_proto` access-pattern functions + virtual properties (issue #39).
//!
//! The self-hosted engine reads an already-deserialized Ball program through
//! the `ball_proto` compat module — oneof discriminators (`whichExpr`…),
//! presence checks (`hasBody`…), Struct field access (`getStructField`…), and
//! safe field get/set (see `dart/shared/lib/ball_proto.dart`, the
//! authoritative definition). These have `isBase: true` and no body; this
//! module is their native Rust implementation, operating on the canonical
//! proto3-JSON [`BallValue`] view [`crate::loader`] produces (a tree of
//! [`BallMap`]s keyed by camelCase `jsonName`s, oneofs represented by which
//! variant key is present).
//!
//! Semantics match `ball_proto.dart` exactly:
//! - A **discriminator** (`whichExpr`/`whichValue`/`whichStmt`/`whichKind`/
//!   `whichSource`) returns the name of whichever of its variant keys is
//!   present on the input map, or `"notSet"` if none is.
//! - A **presence check** (`hasBody`/`hasInput`/…) returns whether the named
//!   field is present (and, for a message/collection field, non-empty — the
//!   proto3 "present and non-default" rule).
//!
//! Virtual properties (`.length`, `.isEmpty`, …) are the computed accessors an
//! engine resolves dynamically on native `String`/`List`/`Map` values rather
//! than by a field lookup — see [`virtual_property`].

use ball_shared::BallValue;

// ════════════════════════════════════════════════════════════
// Oneof discriminators
// ════════════════════════════════════════════════════════════

/// The oneof variant keys of each discriminated message, in the check order
/// `ball_proto.dart` declares (the first present key wins). Keys are canonical
/// proto3 `jsonName`s — the shape [`crate::loader`] produces.
const EXPR_VARIANTS: &[&str] = &[
    "call",
    "literal",
    "reference",
    "fieldAccess",
    "messageCreation",
    "block",
    "lambda",
];
const LITERAL_VARIANTS: &[&str] = &[
    "intValue",
    "doubleValue",
    "stringValue",
    "boolValue",
    "bytesValue",
    "listValue",
];
const STMT_VARIANTS: &[&str] = &["let", "expression"];
const VALUE_KIND_VARIANTS: &[&str] = &[
    "nullValue",
    "numberValue",
    "stringValue",
    "boolValue",
    "structValue",
    "listValue",
];
const SOURCE_VARIANTS: &[&str] = &["http", "file", "git", "registry", "inline"];

/// Shared discriminator: return the first `variants` key present on `obj`, or
/// `"notSet"`. A non-map input has no oneof set, so it is `"notSet"` too
/// (matching `ball_proto.dart`, which treats a missing/empty object the same
/// way rather than throwing).
fn which(obj: &BallValue, variants: &[&str]) -> BallValue {
    if let BallValue::Map(map) = obj {
        for variant in variants {
            if map.get(*variant).is_some_and(|v| *v != BallValue::Null) {
                return BallValue::String((*variant).to_string());
            }
        }
    }
    BallValue::String("notSet".to_string())
}

/// `whichExpr(obj)` — which `Expression` oneof arm is set.
pub fn which_expr(obj: &BallValue) -> BallValue {
    which(obj, EXPR_VARIANTS)
}
/// `whichValue(obj)` — which `Literal` value arm is set.
pub fn which_value(obj: &BallValue) -> BallValue {
    which(obj, LITERAL_VARIANTS)
}
/// `whichStmt(obj)` — which `Statement` arm is set.
pub fn which_stmt(obj: &BallValue) -> BallValue {
    which(obj, STMT_VARIANTS)
}
/// `whichKind(obj)` — which `google.protobuf.Value` kind is set.
pub fn which_kind(obj: &BallValue) -> BallValue {
    which(obj, VALUE_KIND_VARIANTS)
}
/// `whichSource(obj)` — which `ModuleImport` source is set.
pub fn which_source(obj: &BallValue) -> BallValue {
    which(obj, SOURCE_VARIANTS)
}

// ════════════════════════════════════════════════════════════
// Presence checks
// ════════════════════════════════════════════════════════════

/// `has<Field>(obj)` — whether `field` is present and non-default on `obj`.
/// "Non-default" follows proto3: an absent key, an explicit `null`, an empty
/// string, or an empty list/map all read as *not present* (the same rule the
/// Dart getters encode). A present scalar/message reads as present.
pub fn has_field(obj: &BallValue, field: &str) -> BallValue {
    let present = match obj {
        BallValue::Map(map) => match map.get(field) {
            None | Some(BallValue::Null) => false,
            Some(BallValue::String(s)) => !s.is_empty(),
            Some(BallValue::List(l)) => !l.is_empty(),
            Some(BallValue::Map(m)) => !m.is_empty(),
            Some(_) => true,
        },
        _ => false,
    };
    BallValue::Bool(present)
}

// ════════════════════════════════════════════════════════════
// Safe field get / set + Struct access
// ════════════════════════════════════════════════════════════

/// `getField(obj, name)` — read `name` from a map, or `null` if missing/not a
/// map.
pub fn get_field(obj: &BallValue, name: &str) -> BallValue {
    match obj {
        BallValue::Map(map) => map.get(name).cloned().unwrap_or(BallValue::Null),
        BallValue::Message(msg) => msg.get(name).unwrap_or(BallValue::Null),
        _ => BallValue::Null,
    }
}

/// `getFieldOr(obj, name, default)` — read `name`, or `default` if missing.
pub fn get_field_or(obj: &BallValue, name: &str, default: BallValue) -> BallValue {
    match get_field(obj, name) {
        BallValue::Null => default,
        value => value,
    }
}

/// `setField(obj, name, value)` — set `name` on a map and return the modified
/// map. A non-map `obj` is returned unchanged (never panics — matches
/// `ball_proto.dart`'s permissive setter).
pub fn set_field(obj: BallValue, name: &str, value: BallValue) -> BallValue {
    match obj {
        BallValue::Map(mut map) => {
            map.insert(name.to_string(), value);
            BallValue::Map(map)
        }
        BallValue::Message(msg) => {
            // Reference semantics (issue #298): `insert` mutates the shared
            // field map in place; the returned message shares it.
            msg.insert(name, value);
            BallValue::Message(msg)
        }
        other => other,
    }
}

/// `getStructFieldKeys(struct)` — every key of a `google.protobuf.Struct`/
/// metadata map, in order.
pub fn get_struct_field_keys(struct_val: &BallValue) -> BallValue {
    match struct_val {
        BallValue::Map(map) => {
            BallValue::List(map.keys().cloned().map(BallValue::String).collect())
        }
        _ => BallValue::List(Vec::new()),
    }
}

// ════════════════════════════════════════════════════════════
// Virtual properties
// ════════════════════════════════════════════════════════════

/// Resolve a virtual (computed) property `name` on a native value, or `None`
/// if `name` is not a virtual property of `value`'s type — the engine then
/// falls back to an ordinary field lookup. Covers the properties Ball programs
/// read as bare `.length`/`.isEmpty`/… field accesses on primitives rather
/// than as `std_collections` calls.
pub fn virtual_property(value: &BallValue, name: &str) -> Option<BallValue> {
    match (value, name) {
        (BallValue::String(s), "length") => Some(BallValue::Int(s.chars().count() as i64)),
        (BallValue::List(l), "length") => Some(BallValue::Int(l.len() as i64)),
        (BallValue::Map(m), "length") => Some(BallValue::Int(m.len() as i64)),
        (BallValue::Bytes(b), "length") => Some(BallValue::Int(b.len() as i64)),
        (BallValue::String(s), "isEmpty") => Some(BallValue::Bool(s.is_empty())),
        (BallValue::List(l), "isEmpty") => Some(BallValue::Bool(l.is_empty())),
        (BallValue::Map(m), "isEmpty") => Some(BallValue::Bool(m.is_empty())),
        (BallValue::String(s), "isNotEmpty") => Some(BallValue::Bool(!s.is_empty())),
        (BallValue::List(l), "isNotEmpty") => Some(BallValue::Bool(!l.is_empty())),
        (BallValue::Map(m), "isNotEmpty") => Some(BallValue::Bool(!m.is_empty())),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ball_shared::BallMap;

    fn map(pairs: &[(&str, BallValue)]) -> BallValue {
        let mut m = BallMap::new();
        for (k, v) in pairs {
            m.insert((*k).to_string(), v.clone());
        }
        BallValue::Map(m)
    }

    #[test]
    fn which_expr_returns_the_present_oneof_arm() {
        let call_expr = map(&[("call", map(&[("function", BallValue::String("f".into()))]))]);
        assert_eq!(which_expr(&call_expr), BallValue::String("call".into()));

        let ref_expr = map(&[("reference", map(&[("name", BallValue::String("x".into()))]))]);
        assert_eq!(which_expr(&ref_expr), BallValue::String("reference".into()));
    }

    #[test]
    fn which_expr_returns_not_set_when_no_arm_present() {
        assert_eq!(which_expr(&map(&[])), BallValue::String("notSet".into()));
        assert_eq!(
            which_expr(&BallValue::Null),
            BallValue::String("notSet".into())
        );
    }

    #[test]
    fn which_value_and_kind_use_their_own_variant_sets() {
        let lit = map(&[("stringValue", BallValue::String("hi".into()))]);
        assert_eq!(which_value(&lit), BallValue::String("stringValue".into()));
        let val = map(&[("numberValue", BallValue::Double(1.0))]);
        assert_eq!(which_kind(&val), BallValue::String("numberValue".into()));
    }

    #[test]
    fn has_field_follows_proto3_present_and_non_default() {
        let func = map(&[("body", map(&[("literal", BallValue::Null)]))]);
        assert_eq!(has_field(&func, "body"), BallValue::Bool(true));
        assert_eq!(has_field(&func, "metadata"), BallValue::Bool(false));
        // Empty string / empty list read as not present.
        let empties = map(&[
            ("name", BallValue::String(String::new())),
            ("items", BallValue::List(Vec::new())),
        ]);
        assert_eq!(has_field(&empties, "name"), BallValue::Bool(false));
        assert_eq!(has_field(&empties, "items"), BallValue::Bool(false));
    }

    #[test]
    fn get_and_set_field_round_trip() {
        let obj = map(&[("a", BallValue::Int(1))]);
        assert_eq!(get_field(&obj, "a"), BallValue::Int(1));
        assert_eq!(get_field(&obj, "missing"), BallValue::Null);
        assert_eq!(
            get_field_or(&obj, "missing", BallValue::Int(9)),
            BallValue::Int(9)
        );
        let updated = set_field(obj, "b", BallValue::Int(2));
        assert_eq!(get_field(&updated, "b"), BallValue::Int(2));
    }

    #[test]
    fn virtual_property_length_and_is_empty() {
        assert_eq!(
            virtual_property(&BallValue::String("abc".into()), "length"),
            Some(BallValue::Int(3))
        );
        assert_eq!(
            virtual_property(&BallValue::List(vec![BallValue::Int(1)]), "isEmpty"),
            Some(BallValue::Bool(false))
        );
        // Not a virtual property -> None (engine falls back to field lookup).
        assert_eq!(virtual_property(&BallValue::Int(1), "length"), None);
    }
}
