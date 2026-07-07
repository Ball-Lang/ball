//! Loading a target Ball [`Program`] into the runtime (issue #39).
//!
//! Two entry points, mirroring the CLI's two input formats (see
//! `.claude/skills/new-ball-language/SKILL.md` Phase 5.2):
//! - [`parse_program_json`] — proto3-JSON `.ball.json` (human-readable; the
//!   examples/conformance format). Strips the cosmetic `@type` Any envelope.
//! - [`parse_program_binary`] — binary protobuf `.ball.bin` (compact).
//!
//! Both return the typed [`Program`] (for the wrapper's own structural needs —
//! entry point, module/function lookup) **and** a canonical proto3-JSON
//! [`BallValue`] view of it (a tree of insertion-ordered [`BallMap`]s keyed by
//! camelCase `jsonName`s, oneofs represented as the set field being present).
//! The `BallValue` view is exactly the shape the compiled self-hosted engine
//! reads through the `ball_proto` access-pattern functions (see
//! [`crate::ball_proto`]): `whichExpr(expr)` inspects which of an
//! `Expression`'s oneof keys (`call`/`literal`/`fieldAccess`/…) is present,
//! `hasBody(func)` checks for a `body` key, and so on — the same convention
//! the TS wrapper's `protoWrap` normalization produces
//! (`ts/engine/src/engine_setup.ts`).
//!
//! Conversion goes through `prost_reflect::DynamicMessage` so the field names
//! are the canonical proto3 `jsonName`s regardless of the casing the source
//! `.ball.json` happened to use, and so a binary program is viewed identically
//! to the same program in JSON.

use ball_shared::proto::ball::v1::Program;
use ball_shared::{BallMap, BallValue, DESCRIPTOR_POOL};
use prost::Message;
use prost_reflect::{DynamicMessage, SerializeOptions};

use crate::EngineError;

/// Parse a proto3-JSON `.ball.json` program (a self-describing
/// `google.protobuf.Any` envelope carrying a cosmetic top-level `@type` key,
/// which is stripped before deserialization) into a typed [`Program`] plus its
/// canonical [`BallValue`] view. See the module doc comment.
pub fn parse_program_json(json: &str) -> Result<(Program, BallValue), EngineError> {
    let mut json_value: serde_json::Value =
        serde_json::from_str(json).map_err(|e| EngineError::Parse(e.to_string()))?;
    if let serde_json::Value::Object(map) = &mut json_value {
        map.remove("@type");
    }
    let descriptor = program_descriptor()?;
    let dynamic = DynamicMessage::deserialize(descriptor, json_value)
        .map_err(|e| EngineError::Parse(format!("not a valid ball.v1.Program: {e}")))?;
    finish(dynamic)
}

/// Parse a binary-protobuf `.ball.bin` program into a typed [`Program`] plus
/// its canonical [`BallValue`] view. See the module doc comment.
pub fn parse_program_binary(bytes: &[u8]) -> Result<(Program, BallValue), EngineError> {
    let descriptor = program_descriptor()?;
    let dynamic = DynamicMessage::decode(descriptor, bytes)
        .map_err(|e| EngineError::Parse(format!("not a valid ball.v1.Program: {e}")))?;
    finish(dynamic)
}

fn program_descriptor() -> Result<prost_reflect::MessageDescriptor, EngineError> {
    DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .ok_or_else(|| EngineError::Parse("ball.v1.Program missing from descriptor pool".into()))
}

/// Shared tail of both parsers: a `DynamicMessage` -> (typed `Program`,
/// canonical `BallValue` view). The typed decode goes through the message's
/// own binary encoding (lossless); the `BallValue` view goes through
/// canonical proto3-JSON serialization (`use_proto_field_name = false` ->
/// camelCase `jsonName`s, the shape `ball_proto` expects).
fn finish(dynamic: DynamicMessage) -> Result<(Program, BallValue), EngineError> {
    let program = Program::decode(dynamic.encode_to_vec().as_slice())
        .map_err(|e| EngineError::Parse(format!("typed decode failed: {e}")))?;

    let options = SerializeOptions::new()
        .use_proto_field_name(false)
        .skip_default_fields(true);
    let mut serializer = serde_json::Serializer::new(Vec::new());
    dynamic
        .serialize_with_options(&mut serializer, &options)
        .map_err(|e| EngineError::Parse(format!("proto3-JSON view failed: {e}")))?;
    let json: serde_json::Value = serde_json::from_slice(&serializer.into_inner())
        .map_err(|e| EngineError::Parse(format!("proto3-JSON reparse failed: {e}")))?;

    Ok((program, json_to_ball_value(&json)))
}

/// Convert a `serde_json::Value` (canonical proto3 JSON) into a [`BallValue`]
/// tree. Objects become insertion-ordered [`BallMap`]s (proto3 JSON preserves
/// declared field order, which the engine's map-order-sensitive output relies
/// on); arrays become [`BallValue::List`]s; a JSON number is an
/// [`BallValue::Int`] when it is an exact integer, else a
/// [`BallValue::Double`].
///
/// **Note (proto3 JSON int64):** proto3 JSON encodes 64-bit integer fields as
/// *strings* (e.g. `Literal.intValue` -> `"42"`). This conversion leaves such
/// a value as a [`BallValue::String`] — faithful to the wire representation;
/// the compiled engine's own literal-evaluation path is responsible for
/// parsing it, exactly as the Dart/TS engines parse the same string form.
pub fn json_to_ball_value(value: &serde_json::Value) -> BallValue {
    match value {
        serde_json::Value::Null => BallValue::Null,
        serde_json::Value::Bool(b) => BallValue::Bool(*b),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                BallValue::Int(i)
            } else {
                BallValue::Double(n.as_f64().unwrap_or(f64::NAN))
            }
        }
        serde_json::Value::String(s) => BallValue::String(s.clone()),
        serde_json::Value::Array(items) => {
            BallValue::List(items.iter().map(json_to_ball_value).collect())
        }
        serde_json::Value::Object(fields) => {
            let mut map = BallMap::with_capacity(fields.len());
            for (key, val) in fields {
                map.insert(key.clone(), json_to_ball_value(val));
            }
            BallValue::Map(map)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HELLO: &str = r#"{
        "@type": "type.googleapis.com/ball.v1.Program",
        "name": "hello", "version": "1.0.0",
        "entryModule": "main", "entryFunction": "main",
        "modules": [ { "name": "main", "functions": [
            { "name": "main", "body": { "literal": { "stringValue": "hi" } } }
        ] } ]
    }"#;

    #[test]
    fn parses_json_program_and_strips_type_envelope() {
        let (program, value) = parse_program_json(HELLO).expect("must parse");
        assert_eq!(program.name, "hello");
        assert_eq!(program.entry_module, "main");
        // The BallValue view is a map keyed by canonical proto3 jsonName.
        let BallValue::Map(root) = &value else {
            panic!("program view must be a map");
        };
        assert!(root.contains_key("name"));
        assert!(root.contains_key("modules"));
        // The cosmetic `@type` envelope is gone from the typed/canonical view.
        assert!(!root.contains_key("@type"));
    }

    #[test]
    fn json_and_binary_views_are_identical() {
        let (program, json_view) = parse_program_json(HELLO).expect("json parse");
        // Re-encode the typed program to binary, then load it back.
        let bytes = program.encode_to_vec();
        let (_program2, bin_view) = parse_program_binary(&bytes).expect("binary parse");
        assert_eq!(
            json_view, bin_view,
            "the JSON and binary views of the same program must be identical"
        );
    }

    #[test]
    fn number_conversion_picks_int_vs_double() {
        assert_eq!(json_to_ball_value(&serde_json::json!(7)), BallValue::Int(7));
        assert_eq!(
            json_to_ball_value(&serde_json::json!(2.5)),
            BallValue::Double(2.5)
        );
    }
}
