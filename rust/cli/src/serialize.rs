//! Serializing an encoded `ball.v1.Program` back out to `.ball.json`/
//! `.ball.bin` for `ball encode`'s output (issue #41) — the reverse
//! direction of [`crate::loader`] / `rust/engine/src/loader.rs`.
//!
//! - [`program_to_binary`] — plain protobuf binary (`prost::Message::
//!   encode_to_vec`), matching what [`ball_lang_engine::BallEngine::from_binary`]
//!   (and every other engine's `.ball.bin` loader) expects: no `Any`
//!   envelope, just the message's own wire encoding.
//! - [`program_to_json`] — canonical proto3 JSON (camelCase field names,
//!   default-valued fields omitted) via `prost-reflect`'s `DynamicMessage`,
//!   wrapped in the cosmetic `@type` `google.protobuf.Any` envelope every
//!   other target's `.ball.json` output carries (see `rust/engine/src/
//!   loader.rs`'s doc comment and `examples/hello_world/hello_world.ball.json`).
use ball_lang_shared::DESCRIPTOR_POOL;
use ball_lang_shared::proto::ball::v1::Program;
use prost::Message;
use prost_reflect::{DynamicMessage, SerializeOptions};

use crate::error::CliError;

/// `Program` -> raw protobuf binary bytes (`.ball.bin`).
pub fn program_to_binary(program: &Program) -> Vec<u8> {
    program.encode_to_vec()
}

/// `Program` -> pretty-printed, `@type`-enveloped proto3 JSON (`.ball.json`).
pub fn program_to_json(program: &Program) -> Result<String, CliError> {
    let descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .ok_or_else(|| {
            CliError::Runtime("ball.v1.Program missing from the embedded descriptor pool".into())
        })?;
    let dynamic = DynamicMessage::decode(descriptor, program.encode_to_vec().as_slice())
        .map_err(|e| CliError::Runtime(format!("failed to build proto3-JSON view: {e}")))?;

    let options = SerializeOptions::new()
        .use_proto_field_name(false)
        .skip_default_fields(true);
    let mut serializer = serde_json::Serializer::new(Vec::new());
    dynamic
        .serialize_with_options(&mut serializer, &options)
        .map_err(|e| CliError::Runtime(format!("failed to serialize proto3-JSON: {e}")))?;
    let serialized: serde_json::Value = serde_json::from_slice(&serializer.into_inner())
        .map_err(|e| CliError::Runtime(format!("failed to reparse proto3-JSON: {e}")))?;

    let mut enveloped = serde_json::Map::new();
    enveloped.insert(
        "@type".to_string(),
        serde_json::Value::String("type.googleapis.com/ball.v1.Program".to_string()),
    );
    if let serde_json::Value::Object(fields) = serialized {
        enveloped.extend(fields);
    }

    serde_json::to_string_pretty(&serde_json::Value::Object(enveloped))
        .map_err(|e| CliError::Runtime(format!("failed to format JSON: {e}")))
}
