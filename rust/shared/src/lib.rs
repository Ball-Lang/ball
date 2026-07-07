//! `ball-shared` — protobuf bindings and shared runtime types for the Ball
//! Rust implementation.
//!
//! Phase 1b (issue #34) wires up the generated protobuf bindings for
//! `proto/ball/v1/ball.proto` plus a lazily-initialized
//! [`prost_reflect::DescriptorPool`] singleton built from the embedded
//! `FILE_DESCRIPTOR_SET`. Phase 1c (issue #35) adds the runtime value model
//! (`BallValue`/`BallList`/`BallMap`/`BallFunction`, see [`value`]) and the
//! universal std module builders (`std`, `std_collections`, `std_io`,
//! `std_memory`) that the compiler, encoder, and engine all consume.
//!
//! See `.claude/skills/new-ball-language/SKILL.md` for the full bootstrap
//! playbook this crate is part of.

use prost_reflect::DescriptorPool;
use std::sync::LazyLock;

mod descriptor_builders;
mod std_collections_module;
mod std_io_module;
mod std_memory_module;
mod std_module;
pub mod value;

pub use std_collections_module::build_std_collections_module;
pub use std_io_module::build_std_io_module;
pub use std_memory_module::build_std_memory_module;
pub use std_module::build_std_module;
pub use value::{BallFunction, BallList, BallMap, BallMessage, BallValue, extract_fields};

/// Generated protobuf bindings for `proto/ball/v1/ball.proto`.
///
/// **Never hand-edit `rust/shared/gen/**`.** It is produced by
/// `buf generate proto` via the `buf.build/community/neoeinstein-prost`
/// plugin entry in the repo-root `buf.gen.yaml` — regenerate it there, never
/// in this file. Downstream crates should import Ball proto types through
/// this module (`ball_shared::proto::ball::v1::…`) or the top-level
/// re-export below, never by reaching into `rust/shared/gen` directly.
pub mod proto {
    /// `google.protobuf` well-known types (`Struct`, `Value`, `Any`, the
    /// descriptor types, …), compiled from scratch by the `prost` plugin
    /// (`compile_well_known_types=true`) rather than aliased to the
    /// `prost-types` crate, so `ball.v1`'s generated types can reference
    /// them directly (e.g. `Program.metadata: Option<google::protobuf::Struct>`).
    #[allow(clippy::all)]
    pub mod google {
        pub mod protobuf {
            include!("../gen/google.protobuf.rs");
        }
    }

    /// The `ball.v1` package: every message in `proto/ball/v1/ball.proto`
    /// (`Program`, `Module`, `Expression`, `FunctionDefinition`, …).
    #[allow(clippy::all)]
    pub mod ball {
        pub mod v1 {
            include!("../gen/ball.v1.rs");
        }
    }
}

pub use proto::ball::v1::*;

/// Lazily-initialized, process-wide [`DescriptorPool`] resolving every
/// `ball.v1` message type plus its `google.protobuf` imports.
///
/// The buf `neoeinstein-prost` plugin's `file_descriptor_set=true` option
/// embeds one `FILE_DESCRIPTOR_SET` *per generated Rust module* (i.e. per
/// proto package), each containing only the files belonging to that
/// package — it does not flatten the whole transitive closure into a single
/// set. `ball.v1.ball.proto` depends on `google/protobuf/descriptor.proto`
/// and `google/protobuf/struct.proto` (both package `google.protobuf`), so
/// those must be added to the pool first, before `ball.v1`'s own set, or
/// resolution fails with "imported file ... has not been added".
///
/// `DescriptorPool`/`DynamicMessage` (from `prost-reflect`) are required by
/// later phases for descriptor-driven `MessageCreation` handling and
/// `google.protobuf.Struct` metadata — see issue #34.
pub static DESCRIPTOR_POOL: LazyLock<DescriptorPool> = LazyLock::new(|| {
    let mut pool = DescriptorPool::new();
    pool.decode_file_descriptor_set(proto::google::protobuf::FILE_DESCRIPTOR_SET)
        .expect(
            "embedded google.protobuf FILE_DESCRIPTOR_SET must decode into a valid DescriptorPool",
        );
    pool.decode_file_descriptor_set(proto::ball::v1::FILE_DESCRIPTOR_SET)
        .expect(
            "embedded ball.v1 FILE_DESCRIPTOR_SET must decode into the pool once its \
             google.protobuf dependencies are already present",
        );
    pool
});

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;
    use prost_reflect::DynamicMessage;
    use std::path::PathBuf;

    #[test]
    fn descriptor_pool_resolves_ball_v1_program() {
        let descriptor = DESCRIPTOR_POOL
            .get_message_by_name("ball.v1.Program")
            .expect("ball.v1.Program must be resolvable from the embedded descriptor pool");
        assert_eq!(descriptor.full_name(), "ball.v1.Program");
    }

    /// Round-trips `examples/hello_world/hello_world.ball.json` through
    /// prost-reflect: proto3 JSON -> `DynamicMessage` -> protobuf binary ->
    /// typed `Program` -> protobuf binary -> `DynamicMessage`, asserting the
    /// start and end `DynamicMessage`s are equal (a lossless round trip at
    /// the field-value level, independent of incidental wire-encoding
    /// ordering differences between the reflection-based and generated
    /// codecs).
    #[test]
    fn json_to_binary_round_trip_preserves_hello_world_program() {
        let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../examples/hello_world/hello_world.ball.json");
        let json = std::fs::read_to_string(&fixture_path)
            .unwrap_or_else(|err| panic!("failed to read {}: {err}", fixture_path.display()));

        // Every committed `*.ball.json` is a self-describing `google.protobuf.Any`-style
        // envelope carrying a cosmetic top-level `"@type": "type.googleapis.com/ball.v1.Program"`
        // field. That key is not part of the `ball.v1.Program` message schema itself, so
        // strip it before feeding proto3 JSON to prost-reflect — mirroring the `unwrapBallFile`
        // helper the TS toolchain uses for the same self-hosted-engine convention (see
        // CLAUDE.md's "Build & Test" section).
        let mut json_value: serde_json::Value =
            serde_json::from_str(&json).expect("hello_world.ball.json must be valid JSON");
        if let serde_json::Value::Object(map) = &mut json_value {
            map.remove("@type");
        }

        let program_descriptor = DESCRIPTOR_POOL
            .get_message_by_name("ball.v1.Program")
            .expect("ball.v1.Program must be resolvable from the embedded descriptor pool");

        let dynamic_from_json = DynamicMessage::deserialize(program_descriptor.clone(), json_value)
            .expect("hello_world.ball.json must deserialize into a ball.v1.Program DynamicMessage");

        let binary_from_json = dynamic_from_json.encode_to_vec();

        let typed_program = proto::ball::v1::Program::decode(binary_from_json.as_slice()).expect(
            "binary encoded from the DynamicMessage must decode as a typed ball.v1.Program",
        );
        assert!(
            !typed_program.name.is_empty(),
            "hello_world.ball.json's Program must have a non-empty name"
        );

        let binary_from_typed = typed_program.encode_to_vec();
        let dynamic_from_typed =
            DynamicMessage::decode(program_descriptor, binary_from_typed.as_slice()).expect(
                "binary re-encoded from the typed Program must decode back into a DynamicMessage",
            );

        assert_eq!(
            dynamic_from_json, dynamic_from_typed,
            "DynamicMessage -> binary -> typed Program -> binary -> DynamicMessage must be lossless"
        );
    }
}
