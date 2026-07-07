//! Shared protobuf-descriptor construction helpers for the std module
//! builders (issue #35).
//!
//! Mirrors the small private `_type`/`_fn`/`_exprField`/`_stringField`/...
//! helper functions duplicated at the bottom of every
//! `dart/shared/lib/std*.dart` file. Rust favors a single source of truth
//! over copy-pasted private helpers per file, so they live here once and are
//! shared by `std_module`, `std_collections_module`, `std_io_module`, and
//! `std_memory_module`.

use crate::proto::google::protobuf::field_descriptor_proto::{Label, Type};
use crate::proto::google::protobuf::{DescriptorProto, FieldDescriptorProto};
use crate::{FunctionDefinition, TypeDefinition};

/// Fully-qualified type name used for every `Expression`-typed descriptor
/// field, matching the Dart builders' `_exprTypeName` constant.
const EXPRESSION_TYPE_NAME: &str = ".ball.v1.Expression";

/// Build a base-function input `TypeDefinition` from a name and its fields.
pub(crate) fn type_def(name: &str, fields: Vec<FieldDescriptorProto>) -> TypeDefinition {
    TypeDefinition {
        name: name.to_string(),
        descriptor: Some(DescriptorProto {
            name: Some(name.to_string()),
            field: fields,
            ..Default::default()
        }),
        ..Default::default()
    }
}

/// A single-valued `Expression` field (`LABEL_OPTIONAL`).
pub(crate) fn expr_field(name: &str, number: i32) -> FieldDescriptorProto {
    FieldDescriptorProto {
        name: Some(name.to_string()),
        number: Some(number),
        r#type: Some(Type::Message as i32),
        type_name: Some(EXPRESSION_TYPE_NAME.to_string()),
        label: Some(Label::Optional as i32),
        ..Default::default()
    }
}

/// A repeated `Expression` field (`LABEL_REPEATED`) — e.g. `switch`'s cases.
pub(crate) fn expr_list_field(name: &str, number: i32) -> FieldDescriptorProto {
    FieldDescriptorProto {
        name: Some(name.to_string()),
        number: Some(number),
        r#type: Some(Type::Message as i32),
        type_name: Some(EXPRESSION_TYPE_NAME.to_string()),
        label: Some(Label::Repeated as i32),
        ..Default::default()
    }
}

/// A single-valued `string` field.
pub(crate) fn string_field(name: &str, number: i32) -> FieldDescriptorProto {
    FieldDescriptorProto {
        name: Some(name.to_string()),
        number: Some(number),
        r#type: Some(Type::String as i32),
        label: Some(Label::Optional as i32),
        ..Default::default()
    }
}

/// A single-valued `bool` field.
pub(crate) fn bool_field(name: &str, number: i32) -> FieldDescriptorProto {
    FieldDescriptorProto {
        name: Some(name.to_string()),
        number: Some(number),
        r#type: Some(Type::Bool as i32),
        label: Some(Label::Optional as i32),
        ..Default::default()
    }
}

/// A single-valued `int64` field.
pub(crate) fn int_field(name: &str, number: i32) -> FieldDescriptorProto {
    FieldDescriptorProto {
        name: Some(name.to_string()),
        number: Some(number),
        r#type: Some(Type::Int64 as i32),
        label: Some(Label::Optional as i32),
        ..Default::default()
    }
}

/// Build a base `FunctionDefinition`: `is_base = true`, no `body` — the
/// per-platform compiler/engine supplies the implementation (invariant #3).
pub(crate) fn base_fn(
    name: &str,
    input_type: &str,
    output_type: &str,
    description: &str,
) -> FunctionDefinition {
    FunctionDefinition {
        name: name.to_string(),
        input_type: input_type.to_string(),
        output_type: output_type.to_string(),
        body: None,
        description: description.to_string(),
        is_base: true,
        metadata: None,
    }
}
