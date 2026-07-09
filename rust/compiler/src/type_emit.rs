//! Type emission + multi-module output (issue #38) — `typeDefs[]` → Rust
//! `struct`/`trait`/`enum`, class members (`main:Point.describe`,
//! `main:Point.new`, ...) → the owner type's `impl` block, cross-module
//! calls → `<mod>::` qualification. See the crate root's module doc comment
//! for the overall design: dynamic `BallValue::Message` stays the runtime
//! representation (a `struct`'s fields are a faithful, largely
//! documentation-level mapping of the `DescriptorProto` — Ball has no
//! static type checker for this compiler to lean on for anything richer),
//! and polymorphic method calls (two classes sharing a short method name)
//! dispatch on the receiver's actual `type_name` at *run time*
//! ([`Compiler::compile_method_dispatchers`]), not via Rust's own trait
//! system.
use std::collections::HashMap;

use ball_shared::proto::ball::v1::{Expression, FunctionDefinition, Module, TypeDefinition};
use ball_shared::proto::google::protobuf::field_descriptor_proto::{Label, Type};
use ball_shared::proto::google::protobuf::value::Kind;
use ball_shared::proto::google::protobuf::{
    EnumDescriptorProto, FieldDescriptorProto, Struct, Value,
};

use crate::Compiler;

// ════════════════════════════════════════════════════════════
// Name parsing
// ════════════════════════════════════════════════════════════

/// Strip a Ball type's module-qualifying prefix (`"main:Color"` →
/// `"Color"`) — the short form user code actually references (a bare
/// `reference{name: "Color"}` node, e.g. `Color.red`), as opposed to
/// `TypeDefinition.name`'s full `module:Type` form used for `type_name`
/// matching and `impl`/`struct`/`trait` naming.
pub(crate) fn type_short_name(full_name: &str) -> &str {
    match full_name.rfind(':') {
        Some(idx) => &full_name[idx + 1..],
        None => full_name,
    }
}

/// Split a class-member `FunctionDefinition.name` (`"main:Point.describe"`)
/// into its owner `TypeDefinition.name` (`"main:Point"`) and short member
/// name (`"describe"`). Mirrors `dart/compiler/lib/compiler.dart`'s
/// `_buildLibrary` colon-then-dot split exactly, including its fallback for
/// a name with no module-qualifying colon at all (`"Point.new"` →
/// `("Point", "new")`). Returns `None` when `name` has no dot to split on
/// (an ordinary standalone function name) — the caller ([`is_class_member`])
/// treats that as "not a class member", matching Dart's own fallthrough to
/// `standaloneFunctions`.
pub(crate) fn split_member_name(name: &str) -> Option<(String, String)> {
    match name.rfind(':') {
        Some(colon_idx) => {
            let after_colon = &name[colon_idx + 1..];
            let dot_idx = after_colon.find('.')?;
            let owner = name[..colon_idx + 1 + dot_idx].to_string();
            let member = after_colon[dot_idx + 1..].to_string();
            Some((owner, member))
        }
        None => {
            let dot_idx = name.find('.')?;
            let owner = name[..dot_idx].to_string();
            let member = name[dot_idx + 1..].to_string();
            Some((owner, member))
        }
    }
}

/// The sanitized Rust identifier for a class member's short name (the part
/// after the owner's `.` — `"describe"`, `"new"`, `"area"`, ...).
pub(crate) fn member_short_name(name: &str) -> String {
    match split_member_name(name) {
        Some((_, member)) => crate::sanitize_ident(&member),
        None => crate::sanitize_ident(name),
    }
}

/// Is `func` a class member (constructor/method — `static_field` is a
/// documented gap, see the crate doc comment) that belongs inside an
/// `impl`/`trait` block rather than being emitted as a free function? Keyed
/// purely on whether the name parses via [`split_member_name`] — every
/// reference encoder only ever sets `metadata.kind` to
/// `"method"`/`"constructor"`/`"static_field"` *together* with the
/// `module:Type.member` naming convention, and (mirroring
/// `DartCompiler._buildLibrary`'s own fallthrough) a function whose name
/// doesn't parse that way has no owner to place it under regardless of what
/// `metadata.kind` claims, so it's compiled as an ordinary standalone
/// function instead of silently dropped.
pub(crate) fn is_class_member(func: &FunctionDefinition) -> bool {
    split_member_name(&func.name).is_some()
}

/// Does `name` match the encoder's positional-constructor-argument
/// convention (`"arg0"`, `"arg1"`, ...)? See
/// [`Compiler::compile_message_creation`]'s doc comment for why this
/// matters: a `MessageCreation` field named this way needs renaming to the
/// constructor's real parameter name before insertion into the message's
/// field map.
pub(crate) fn is_positional_arg_name(name: &str) -> bool {
    name.strip_prefix("arg")
        .is_some_and(|rest| !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()))
}

// ════════════════════════════════════════════════════════════
// `google.protobuf.Struct` metadata-bag readers
// ════════════════════════════════════════════════════════════

/// Read a `google.protobuf.Struct` metadata bag's string-valued field.
pub(crate) fn meta_string_value(meta: &Struct, key: &str) -> Option<String> {
    match meta.fields.get(key).and_then(|v| v.kind.as_ref()) {
        Some(Kind::StringValue(v)) => Some(v.clone()),
        _ => None,
    }
}

/// Read a `google.protobuf.Struct` metadata bag's bool-valued field,
/// defaulting to `false` when absent or not a bool (matches
/// `base_call.rs`'s own `bool_field` helper).
pub(crate) fn meta_bool_value(meta: &Struct, key: &str) -> bool {
    matches!(
        meta.fields.get(key).and_then(|v| v.kind.as_ref()),
        Some(Kind::BoolValue(true))
    )
}

/// Read a `google.protobuf.Struct` metadata bag's list-valued field.
pub(crate) fn meta_list_value<'a>(meta: &'a Struct, key: &str) -> Option<&'a Vec<Value>> {
    match meta.fields.get(key).and_then(|v| v.kind.as_ref()) {
        Some(Kind::ListValue(list)) => Some(&list.values),
        _ => None,
    }
}

/// `func.metadata`'s bool-valued field, defaulting to `false` when
/// `metadata` itself is absent.
fn func_meta_bool(func: &FunctionDefinition, key: &str) -> bool {
    func.metadata
        .as_ref()
        .map(|m| meta_bool_value(m, key))
        .unwrap_or(false)
}

/// Whether a `let` binding is a **cascade** receiver (`metadata.kind ==
/// "cascade"` — the encoder tags `let __cascade_self__ = x` this way when
/// desugaring `x..a()..b()`). Issue #300 — see [`Compiler::compile_block`].
pub(crate) fn let_is_cascade(let_binding: &ball_shared::proto::ball::v1::LetBinding) -> bool {
    let_binding
        .metadata
        .as_ref()
        .and_then(|m| meta_string_value(m, "kind"))
        .as_deref()
        == Some("cascade")
}

/// `func.metadata.kind`, if present.
pub(crate) fn func_meta_kind(func: &FunctionDefinition) -> Option<String> {
    func.metadata
        .as_ref()
        .and_then(|m| meta_string_value(m, "kind"))
}

/// The short name under which `func` is dispatched as an **instance method**
/// (issue #298), or `None` if it isn't one. An instance method is a class
/// member that is not a constructor, not abstract (has a real `impl` to route
/// to), and not `is_static` (its dispatcher reads `input.self` to pick the
/// concrete type) — exactly the members [`Compiler::compile_method_dispatchers`]
/// emits a self-reading `pub fn <short>` for. The compiler injects the implicit
/// receiver into a call to one of these names made from inside an instance
/// method/constructor body.
pub(crate) fn instance_method_short_name(func: &FunctionDefinition) -> Option<String> {
    if !is_class_member(func) {
        return None;
    }
    if func_meta_kind(func).as_deref() == Some("constructor") {
        return None;
    }
    if func_meta_bool(func, "is_abstract") || func_meta_bool(func, "is_static") {
        return None;
    }
    Some(member_short_name(&func.name))
}

/// A `TypeDefinition`'s `metadata.superclass` (the parent class's **short**
/// name — the encoders store it bare, e.g. `main:BallObject`'s
/// `superclass: "BallMap"`), if it names a non-empty superclass. Drives
/// [`Compiler::all_instance_field_names`]'s chain walk (issue #39 gap #5).
pub(crate) fn superclass_of(td: &TypeDefinition) -> Option<String> {
    td.metadata
        .as_ref()
        .and_then(|m| meta_string_value(m, "superclass"))
        .filter(|s| !s.is_empty())
}

/// The backing instance fields of a **native** superclass — one the
/// self-hosted engine `extends` but that has no user `TypeDefinition` of its
/// own (so [`Compiler::all_instance_field_names`]'s chain walk can't read a
/// descriptor for it). The engine's `class BallObject extends BallMap`
/// inherits `BallMap`'s ordered-map backing field `entries`, which its
/// `setField`/`_refreshEntries`/`operator []=` bodies reference as a bare
/// name (Dart's implicit-instance-field convention). Any other native base
/// (`BallValue`, an abstract `BallModuleHandler` with no fields) contributes
/// nothing.
fn native_superclass_fields(name: &str) -> &'static [&'static str] {
    match name {
        "BallMap" => &["entries"],
        _ => &[],
    }
}

/// Strip a leading Dart generic type-argument prefix from an initializer's
/// cosmetic source text (`<String, int>{}` → `{}`, `<Object?>[]` → `[]`), so
/// the literal shape underneath can be recognized. Non-generic text is
/// returned unchanged.
fn strip_generic_prefix(s: &str) -> &str {
    if !s.starts_with('<') {
        return s;
    }
    let mut depth = 0usize;
    for (index, ch) in s.char_indices() {
        match ch {
            '<' => depth += 1,
            '>' => {
                depth -= 1;
                if depth == 0 {
                    return s[index + ch.len_utf8()..].trim_start();
                }
            }
            _ => {}
        }
    }
    s
}

/// Whether `s` is a plain identifier (a bare class name in `Type()` initializer
/// text) — used to recognize a zero-argument constructor default.
fn is_simple_ident(s: &str) -> bool {
    !s.is_empty()
        && !s.chars().next().is_some_and(|c| c.is_ascii_digit())
        && s.chars().all(|c| c.is_alphanumeric() || c == '_')
}

/// The descriptor field names of `td` (in declaration order), skipping
/// unnamed/empty entries — the shape both the struct declaration and the
/// method/constructor field-alias prologue read.
fn descriptor_field_names(td: &TypeDefinition) -> Vec<String> {
    let Some(descriptor) = &td.descriptor else {
        return Vec::new();
    };
    descriptor
        .field
        .iter()
        .filter_map(|field| field.name.as_deref())
        .filter(|name| !name.is_empty())
        .map(|name| name.to_string())
        .collect()
}

/// A constructor's declared parameters as `(name, is_this)` pairs, in
/// declaration order — read straight off `metadata.params` (each an
/// `{name, is_this, …}` struct). Used by
/// [`Compiler::compile_constructor_with_body`] to seed each `this.`-formal
/// field of the instance.
fn ctor_params(ctor: &FunctionDefinition) -> Vec<(String, bool)> {
    let Some(meta) = &ctor.metadata else {
        return Vec::new();
    };
    let Some(params) = meta_list_value(meta, "params") else {
        return Vec::new();
    };
    params
        .iter()
        .filter_map(|v| match &v.kind {
            Some(Kind::StructValue(param_struct)) => {
                let name = meta_string_value(param_struct, "name")?;
                Some((name, meta_bool_value(param_struct, "is_this")))
            }
            _ => None,
        })
        .collect()
}

/// The parameter name that initializes instance field `field`, if a
/// `metadata.initializers` entry sets it directly from a parameter (the common
/// `field = param` / `field = param ?? default` shape). The initializer's
/// `value` is cosmetic source text (not an expression tree), so this reads only
/// its leading identifier token and accepts it when it names a declared
/// parameter (`param_names`) — a richer initializer expression yields `None`
/// (the field stays `Null`), the documented best-effort boundary.
fn field_initializer_param(
    ctor: &FunctionDefinition,
    field: &str,
    param_names: &std::collections::HashSet<&str>,
) -> Option<String> {
    let meta = ctor.metadata.as_ref()?;
    let initializers = meta_list_value(meta, "initializers")?;
    for init in initializers {
        let Some(Kind::StructValue(init_struct)) = &init.kind else {
            continue;
        };
        if meta_string_value(init_struct, "kind").as_deref() != Some("field") {
            continue;
        }
        if meta_string_value(init_struct, "name").as_deref() != Some(field) {
            continue;
        }
        let value = meta_string_value(init_struct, "value")?;
        let token: String = value
            .trim()
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        if param_names.contains(token.as_str()) {
            return Some(token);
        }
        return None;
    }
    None
}

// ════════════════════════════════════════════════════════════
// Field-type mapping
// ════════════════════════════════════════════════════════════

/// Map a `FieldDescriptorProto`'s protobuf scalar type to a Rust field type
/// for [`Compiler::compile_struct_def`]. Scalars map to their obvious
/// native Rust type; anything else (message/enum/group fields, or an
/// unset/unrecognized `r#type`) maps to `BallValue` — the uniform dynamic
/// value type every other field/expression in this crate already uses, so
/// a nested class/enum-typed field is still perfectly usable even though
/// its *declared* Rust field type doesn't name the nested struct/enum
/// directly. `LABEL_REPEATED` wraps the scalar in `Vec<...>`.
///
/// This mapping is used **only** for the emitted `struct`'s field
/// declarations — see the crate root doc comment for why actual instances
/// stay a dynamic `BallValue::Message` regardless (this Rust type never
/// appears in a real field read/write in generated code, only in the
/// struct declaration itself).
pub(crate) fn proto_field_rust_type(field: &FieldDescriptorProto) -> String {
    let base = match field.r#type {
        Some(v)
            if v == Type::Int32 as i32
                || v == Type::Sint32 as i32
                || v == Type::Sfixed32 as i32 =>
        {
            "i32"
        }
        Some(v)
            if v == Type::Int64 as i32
                || v == Type::Sint64 as i32
                || v == Type::Sfixed64 as i32 =>
        {
            "i64"
        }
        Some(v) if v == Type::Uint32 as i32 || v == Type::Fixed32 as i32 => "u32",
        Some(v) if v == Type::Uint64 as i32 || v == Type::Fixed64 as i32 => "u64",
        Some(v) if v == Type::Double as i32 => "f64",
        Some(v) if v == Type::Float as i32 => "f32",
        Some(v) if v == Type::Bool as i32 => "bool",
        Some(v) if v == Type::String as i32 => "String",
        Some(v) if v == Type::Bytes as i32 => "Vec<u8>",
        _ => "BallValue",
    };
    let repeated = matches!(field.label, Some(v) if v == Label::Repeated as i32);
    if repeated {
        format!("Vec<{base}>")
    } else {
        base.to_string()
    }
}

// ════════════════════════════════════════════════════════════
// Oneof-discriminator enum namespaces (issue #39, self-host)
// ════════════════════════════════════════════════════════════

/// The Ball-proto **oneof-discriminator enums** the self-hosted engine
/// references as bare `Expression_Expr.call`, `Literal_Value.stringValue`,
/// `Statement_Stmt.let`, `structpb_Value_Kind.numberValue`,
/// `ModuleImport_Source.inline`, … — each an `(enum_name, &[member, …])` pair.
///
/// These are **not** real protobuf `enum`s: they are the synthesized oneof
/// discriminators the Dart protobuf codegen emits for each `oneof`
/// (`Expression.expr` → `Expression_Expr`, `Literal.value` →
/// `Literal_Value`, `Statement.stmt` → `Statement_Stmt`, `ModuleImport.source`
/// → `ModuleImport_Source`, `google.protobuf.Value.kind` →
/// `structpb_Value_Kind`). They carry no `EnumDescriptorProto` in any
/// `Module.enums[]`, so [`Compiler::compile_module_types`] never emits them —
/// yet the engine's `switch (expr.whichExpr()) { case Expression_Expr.call: … }`
/// logic compares the `ball_proto` discriminators' return value against them.
///
/// Member order is irrelevant (they are read by name), so this lists the full
/// arm set of each oneof plus the trailing `notSet` sentinel — mirroring the
/// TypeScript compiler's `preamble.ts` constants (`Expression_Expr`,
/// `Literal_Value`, `Statement_Stmt`, `ModuleImport_Source`,
/// `structpb_Value_Kind`) exactly.
const ONEOF_DISCRIMINATOR_ENUMS: &[(&str, &[&str])] = &[
    (
        "Expression_Expr",
        &[
            "call",
            "literal",
            "reference",
            "fieldAccess",
            "messageCreation",
            "block",
            "lambda",
            "notSet",
        ],
    ),
    (
        "Literal_Value",
        &[
            "intValue",
            "doubleValue",
            "stringValue",
            "boolValue",
            "bytesValue",
            "listValue",
            "notSet",
        ],
    ),
    ("Statement_Stmt", &["let", "expression", "notSet"]),
    (
        "ModuleImport_Source",
        &["http", "file", "git", "registry", "inline", "notSet"],
    ),
    (
        "structpb_Value_Kind",
        &[
            "nullValue",
            "numberValue",
            "stringValue",
            "boolValue",
            "structValue",
            "listValue",
            "notSet",
        ],
    ),
];

/// Emit each [`ONEOF_DISCRIMINATOR_ENUMS`] entry as a crate-root
/// `pub static <Enum>: LazyLock<BallValue>` namespace — the compile-time
/// counterpart of the `ball_proto` discriminator functions
/// (`whichExpr`/`whichValue`/`whichStmt`/`whichKind`/`whichSource`), whose
/// runtime return value is the set oneof arm's **string** case name
/// (`rust/engine/src/ball_proto.rs`). Each member therefore resolves to
/// `BallValue::String("<caseName>")` (a `field_access` `Expression_Expr.call`
/// lowers to `ball_field_get(Expression_Expr.clone(), "call")` — see
/// [`Compiler::compile_field_access`]), so the engine's
/// `whichExpr() == Expression_Expr.call` comparisons hold. Same shape as
/// [`Compiler::compile_enum_descriptor`], but with **string** members rather
/// than `index`/`name` `Message`s, because a discriminator arm *is* just its
/// case-name string, not an ordinal enum value.
///
/// Emitted once at the crate root (before the nested per-module `mod` blocks),
/// so top-level entry-module code sees them directly and every nested
/// `mod … { use super::*; }` sees them via its glob import — matching the
/// TypeScript target's always-present preamble constants (harmless dead code
/// for a program that never touches the Ball AST; `#![allow(dead_code)]`
/// already covers it).
pub(crate) fn oneof_discriminator_enum_defs() -> String {
    let mut out = String::new();
    for (enum_name, members) in ONEOF_DISCRIMINATOR_ENUMS {
        let mut inserts = String::new();
        for member in *members {
            inserts.push_str(&format!(
                "    __ns.insert({member:?}.to_string(), BallValue::String({member:?}.to_string()));\n"
            ));
        }
        out.push_str(&format!(
            "pub static {enum_name}: std::sync::LazyLock<BallValue> = std::sync::LazyLock::new(|| {{\n\
             let mut __ns = BallMap::new();\n{inserts}\
             BallValue::Message(BallMessage::new({enum_name:?}, __ns))\n\
             }});\n"
        ));
    }
    out
}

impl Compiler<'_> {
    // ════════════════════════════════════════════════════════════
    // Cross-module call resolution
    // ════════════════════════════════════════════════════════════

    /// Resolve a user (non-base) `FunctionCall`'s callee prefix: empty for
    /// a same-module call (`call.module` empty, or equal to the module
    /// currently being compiled — see [`Compiler::compile_module_body`]),
    /// or `"<mod>::"` when `call.module` names a *different* known user
    /// module, so the emitted call reaches into that module's nested `mod`
    /// block. A `call.module` that names neither the current module nor
    /// any other known user module is treated as same-module (defensive
    /// fallback, not a panic — matches this crate's existing posture of
    /// never guessing a silent coercion but also never hard-failing on a
    /// merely-unexpected shape).
    pub(crate) fn resolve_user_call_name(&self, call_module: &str) -> String {
        let current = self.current_module.borrow();
        if !call_module.is_empty()
            && call_module != current.as_str()
            && self.user_module_names.contains(call_module)
        {
            format!("{}::", crate::sanitize_ident(call_module))
        } else {
            String::new()
        }
    }

    // ════════════════════════════════════════════════════════════
    // Types: struct / trait / enum
    // ════════════════════════════════════════════════════════════

    /// Compile every type declaration in `module`: `Module.enums[]`
    /// (`EnumDescriptorProto`) first, then `Module.type_defs[]` — skipping
    /// any `TypeDefinition` with no `descriptor` at all, which is exactly
    /// the shape a `kind: "enum"` cosmetic `TypeDefinition` has (its real
    /// value/number data lives in the matching `Module.enums[]` entry, not
    /// the `TypeDefinition` itself). Mirrors
    /// `DartCompiler._buildLibrary`'s own `if (!td.hasDescriptor())
    /// continue;` guard, which skips the same redundant entry for the same
    /// reason.
    pub(crate) fn compile_module_types(&self, module: &Module) -> String {
        let mut out = String::new();
        for enum_def in &module.enums {
            out.push_str(&self.compile_enum_descriptor(enum_def));
            out.push('\n');
        }
        for td in &module.type_defs {
            if td.descriptor.is_none() {
                continue;
            }
            out.push_str(&self.compile_type_def(td));
            out.push('\n');
        }
        out
    }

    /// Compile a single `TypeDefinition` to a `struct` + inherent `impl` —
    /// including an **abstract** class/interface (`metadata.is_abstract`).
    /// `enum`-kind `TypeDefinition`s are never reached here (see
    /// [`Compiler::compile_module_types`]'s guard).
    ///
    /// An abstract class emits the same struct+`impl` shape as a concrete one,
    /// *not* a Rust `trait` (issue #39 gap #5). This crate's polymorphic
    /// dispatch is runtime `type_name` matching
    /// ([`Compiler::compile_method_dispatchers`]), never Rust's trait system,
    /// so a `trait` was pure dead documentation — and a `trait`'s default
    /// method can't be called as `Trait::method(input)` from the dispatcher
    /// (`error[E0790]`, "cannot call associated function on trait"), which the
    /// engine's `StdModuleHandler extends BallModuleHandler` needs for the
    /// inherited-but-not-overridden `init`. As an inherent `impl` fn it is a
    /// real callable. A purely abstract member (bodyless) is still excluded
    /// from the `impl` ([`Compiler::compile_struct_def`]) — only concrete
    /// (bodied) members, whether declared on the abstract base or an override,
    /// are emitted.
    fn compile_type_def(&self, td: &TypeDefinition) -> String {
        self.compile_struct_def(td)
    }

    /// `struct <Name> { pub field: Type, ... }` + an `impl <Name> { ... }`
    /// holding every non-abstract class member (constructors, methods —
    /// `static_field` is a documented gap, see the crate doc comment).
    /// Field types are [`proto_field_rust_type`]'s best-effort mapping from
    /// the `DescriptorProto`; the struct is a faithful shape declaration,
    /// not the actual runtime representation (see the crate root doc
    /// comment) — it is never itself constructed by generated code
    /// (`compile_message_creation` still always builds a dynamic
    /// `BallValue::Message`), so `#![allow(dead_code)]` (already in
    /// [`Compiler::compile`]'s preamble) keeps `cargo run`/`rustc` quiet
    /// about that.
    fn compile_struct_def(&self, td: &TypeDefinition) -> String {
        let rust_name = crate::sanitize_ident(&td.name);
        let mut out = format!("#[derive(Debug, Clone)]\npub struct {rust_name} {{\n");
        if let Some(descriptor) = &td.descriptor {
            for field in &descriptor.field {
                let Some(field_name) = field.name.as_deref() else {
                    continue;
                };
                if field_name.is_empty() {
                    continue;
                }
                out.push_str(&format!(
                    "    pub {}: {},\n",
                    crate::sanitize_ident(field_name),
                    proto_field_rust_type(field)
                ));
            }
        }
        out.push_str("}\n\n");

        let members = self
            .class_members_by_owner
            .get(&td.name)
            .cloned()
            .unwrap_or_default();
        let non_abstract: Vec<_> = members
            .into_iter()
            .filter(|m| !func_meta_bool(m, "is_abstract"))
            .collect();
        if !non_abstract.is_empty() {
            out.push_str(&format!("impl {rust_name} {{\n"));
            for member in &non_abstract {
                out.push_str(&self.compile_class_member(td, member));
            }
            out.push_str("}\n");
        }
        out
    }

    /// `pub static <ShortName>: LazyLock<BallValue> = ...;` — a Ball enum's
    /// namespace, built once and cached. Named by the enum's **short** name
    /// (`"main:Color"` → `Color`), not the sanitized full name, so a bare
    /// `reference{name: "Color"}` in user code (e.g. `Color.red`) resolves
    /// directly to this item (`Compiler::compile_reference` already lowers
    /// *every* non-`"input"` reference to `<name>.clone()`, with no
    /// enum-specific special-casing needed there).
    ///
    /// Each member is a `BallValue::Message` tagged with the enum's full
    /// `type_name` and carrying `index`/`name` fields (read by `c.index` —
    /// a `field_access` — in the enum conformance fixture); the namespace
    /// value itself carries one field per member name (`Color.red`) plus a
    /// `"values"` field (`Color.values`, a `List` in declaration order —
    /// `Color.values.length` then reads `ball_field_get`'s new virtual
    /// `"length"` property on that `List`, see `rust/shared/src/runtime.rs`).
    fn compile_enum_descriptor(&self, enum_def: &EnumDescriptorProto) -> String {
        let full_name = enum_def.name.clone().unwrap_or_default();
        let short_name = crate::sanitize_ident(type_short_name(&full_name));
        let mut member_code = String::new();
        let mut list_items = String::new();
        for (index, value) in enum_def.value.iter().enumerate() {
            let member_name = value.name.clone().unwrap_or_default();
            let ordinal = value.number.unwrap_or(index as i32);
            let var = format!("__ball_enum_{index}");
            member_code.push_str(&format!(
                "let mut __m{index} = BallMap::new();\n\
                 __m{index}.insert(\"index\".to_string(), BallValue::Int({ordinal}i64));\n\
                 __m{index}.insert(\"name\".to_string(), BallValue::String({member_name:?}.to_string()));\n\
                 let {var} = BallValue::Message(BallMessage::new({full_name:?}, __m{index}));\n\
                 __ns.insert({member_name:?}.to_string(), {var}.clone());\n"
            ));
            list_items.push_str(&format!("{var}.clone(), "));
        }
        format!(
            "pub static {short_name}: std::sync::LazyLock<BallValue> = std::sync::LazyLock::new(|| {{\n\
             let mut __ns = BallMap::new();\n{member_code}\
             __ns.insert(\"values\".to_string(), BallValue::List(BallList::from(vec![{list_items}])));\n\
             BallValue::Message(BallMessage::new({full_name:?}, __ns))\n\
             }});\n"
        )
    }

    // ════════════════════════════════════════════════════════════
    // Class members: constructors + methods
    // ════════════════════════════════════════════════════════════

    /// Compile one class member into its `impl`-block Rust source: a
    /// constructor ([`Compiler::compile_constructor`]) or an ordinary
    /// method (self/field-alias prologue + body —
    /// [`Compiler::method_prologue`]). Any kind other than `"constructor"`
    /// (including `"static_field"`, a documented gap — see the crate doc
    /// comment) falls back to the same method-shaped compilation, so
    /// nothing is silently dropped even though `static_field`'s own
    /// module-level-const semantics aren't specially handled yet.
    fn compile_class_member(
        &self,
        owner_td: &TypeDefinition,
        member: &FunctionDefinition,
    ) -> String {
        if func_meta_kind(member).as_deref() == Some("constructor") {
            self.compile_constructor(owner_td, member)
        } else {
            self.compile_method(owner_td, member)
        }
    }

    /// `pub fn <short>(input: BallValue) -> BallValue { ... }` inside the
    /// owner's `impl` block. The implicit receiver is still addressed via
    /// the single-`input` convention (invariant #1) —
    /// [`Compiler::method_prologue`] extracts it (`input`'s `"self"` field)
    /// plus every descriptor field of `owner_td` as local aliases, so the
    /// body's bare `x`/`y` references (Dart's implicit
    /// unqualified-field-access-inside-a-method convention) resolve exactly
    /// like `Compiler::param_alias_prologue` does for an ordinary
    /// function's single named parameter.
    fn compile_method(&self, owner_td: &TypeDefinition, func: &FunctionDefinition) -> String {
        let short = member_short_name(&func.name);
        let is_static = func_meta_bool(func, "is_static");
        self.push_scope();
        self.bind_local("input");
        let prologue = self.method_prologue(owner_td, func);
        // A non-static method body has a bound `self_`, so implicit-`this`
        // calls inside it get the receiver injected (issue #298).
        let body = self.with_instance_method(!is_static, || match &func.body {
            Some(body) => self.compile_expression(body),
            None => "BallValue::Null".to_string(),
        });
        // Persist body-mutated instance fields back into `self_` (issue #298).
        // Empty for a static member (no `self_`) and for a method that mutates
        // no field (the read-only common case — no `let mut`/extra emission).
        let writeback = if is_static {
            String::new()
        } else {
            self.method_field_writeback(owner_td, func.body.as_deref())
        };
        self.pop_scope();
        if writeback.is_empty() {
            format!(
                "    pub fn {short}(input: BallValue) -> BallValue {{\n{prologue}{body}\n    }}\n"
            )
        } else {
            // Run the body inside an **IIFE closure** so an *early* `return`
            // (`_Scope.set`'s `_bindings[name] = value; return;`) yields the
            // value to `__method_result` instead of returning past the field
            // write-back — otherwise the mutation to `this.<field>` is silently
            // lost (issue #300 — the loop-counter-never-advances hang). The
            // write-back then persists every body-mutated instance field, and
            // the method returns the captured value.
            format!(
                "    pub fn {short}(input: BallValue) -> BallValue {{\n{prologue}\
                 let __method_result = (|| -> BallValue {{\n{body}\n}})();\n{writeback}__method_result\n    }}\n"
            )
        }
    }

    /// The `ball_field_set(&mut self_, "<field>", <field>.clone());` lines that
    /// write each body-mutated instance field of `owner_td` back into `self_`
    /// (issue #298). A reference-semantic `BallValue::Message` shares its field
    /// map across clones, so this persists the mutation to the caller's
    /// instance (and to any other method that later reads the same instance) —
    /// the mechanism the constructor's own write-back already uses
    /// ([`Compiler::compile_constructor_with_body`]). Only fields the body
    /// actually mutates ([`Compiler::expr_mutates_var`]) are written back.
    fn method_field_writeback(
        &self,
        owner_td: &TypeDefinition,
        body: Option<&Expression>,
    ) -> String {
        let Some(body) = body else {
            return String::new();
        };
        let mut out = String::new();
        for field_name in self.all_instance_field_names(owner_td) {
            if self.expr_mutates_var(body, &field_name) {
                out.push_str(&format!(
                    "ball_field_set(&mut self_, {field_name:?}, {}.clone());\n",
                    crate::sanitize_ident(&field_name)
                ));
            }
        }
        out
    }

    /// Bind `self_` (`input`'s `"self"` field — `"self"` itself is a
    /// reserved Rust keyword, so [`crate::sanitize_ident`] already renames
    /// any bare `reference{name: "self"}` inside the body to `self_` too,
    /// keeping this consistent with zero enum/method-specific special-
    /// casing in `Compiler::compile_reference`) plus one local alias per
    /// field declared on `owner_td`'s descriptor (Dart's implicit
    /// unqualified-instance-field convention), plus any additional declared
    /// parameter beyond the receiver (rare — no required #38 fixture has a
    /// method with real extra parameters, but avoids silently dropping one
    /// if `metadata.params` ever carries more than just `self`).
    ///
    /// Both the `self_` binding and the descriptor-field aliases are skipped
    /// entirely when `func.metadata.is_static` is set — the reference
    /// encoders' shared convention for "this class member has no receiver"
    /// (`dart/encoder/lib/encoder.dart`'s `_encodeMethodDeclaration`,
    /// mirrored by the C++/TS compilers' own `is_static` checks). A
    /// receiver-less associated function's `input` never carries a `"self"`
    /// field at all, so unconditionally extracting one panics inside
    /// `ball_field_get` (`rust/shared/src/runtime.rs`) the instant such a
    /// function runs (issue #288) — compiling it without that prologue
    /// makes it behave exactly like an ordinary free function, which is all
    /// a static associated function ever is at the Rust level.
    fn method_prologue(&self, owner_td: &TypeDefinition, func: &FunctionDefinition) -> String {
        let mut out = String::new();
        if !func_meta_bool(func, "is_static") {
            // `self_` is `mut` so a body-mutated instance field can be written
            // back into it (issue #298 — [`Compiler::method_field_writeback`]);
            // a reference-semantic `BallValue::Message` clone shares its fields,
            // so the write-back persists to the caller's instance. `unused_mut`
            // is allowed by the emitted preamble, so a read-only method's
            // `let mut self_` is harmless.
            out.push_str("        let mut self_ = ball_field_get(input.clone(), \"self\");\n");
            self.bind_local("self");
            // A stable receiver clone for implicit-`this` injection (issue
            // #298). Injecting `__self_recv.clone()` (rather than `self_`) keeps
            // the receiver-clone's borrow off `self_` itself, so a call that
            // both mutably borrows `self_` (`self.removeAt(_toInt(x))`) and
            // injects the receiver into a sub-call doesn't collide (E0502), and
            // a `move` closure capturing the receiver pre-clones this local
            // (see `collect_referenced_names`) instead of moving `self_` out
            // (E0382). A `BallValue::Message` clone shares its fields, so the
            // injected receiver is the same instance.
            out.push_str("        let __self_recv = self_.clone();\n");
            self.bind_local("__self_recv");
            out.push_str(&self.field_alias_prologue(owner_td, func.body.as_deref(), "        "));
        }
        // Bind every declared parameter beyond the receiver. A static member
        // has no receiver, so its lone positional argument (if any) is passed
        // *directly* — exactly like a free function (`single_positional_is_direct`);
        // an instance member's `input` is always the `{self, arg0, …}` message
        // the reference encoders emit, so each parameter is a field of it.
        out.push_str(&self.params_binding_prologue(func, func_meta_bool(func, "is_static")));
        out
    }

    /// Every instance-field name of `owner_td` — its own descriptor fields
    /// first, then each field inherited from its superclass chain
    /// (`metadata.superclass` resolved via
    /// [`Compiler::type_defs_by_short_name`]), then any known
    /// [`native_superclass_fields`] of a native (no-`TypeDefinition`) base.
    /// Deduplicated, own-first (a subclass field shadows an inherited
    /// namesake). This is what lets a method/constructor body's bare reference
    /// to an *inherited* field bind like an own field — the engine's
    /// `BallObject extends BallMap` reads `entries`, and its `BallEngine`
    /// constructor body references its own fields (issue #39 gap #5).
    pub(crate) fn all_instance_field_names(&self, owner_td: &TypeDefinition) -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        for name in descriptor_field_names(owner_td) {
            if seen.insert(name.clone()) {
                names.push(name);
            }
        }
        let mut current = owner_td;
        // A finite guard against a malformed cyclic `superclass` chain.
        for _ in 0..32 {
            let Some(super_name) = superclass_of(current) else {
                break;
            };
            if let Some(super_td) = self.type_defs_by_short_name.get(super_name.as_str()) {
                for name in descriptor_field_names(super_td) {
                    if seen.insert(name.clone()) {
                        names.push(name);
                    }
                }
                current = super_td;
            } else {
                for name in native_superclass_fields(&super_name) {
                    if seen.insert((*name).to_string()) {
                        names.push((*name).to_string());
                    }
                }
                break;
            }
        }
        names
    }

    /// Emit one `let [mut] <field> = ball_field_get(self_.clone(), "<field>");`
    /// per instance field of `owner_td` ([`Compiler::all_instance_field_names`]
    /// — own + inherited), binding each as a local so the body's bare field
    /// references resolve (Dart's implicit unqualified-instance-field
    /// convention). A field the body reassigns (or mutates through) is declared
    /// `let mut` so its later `&mut` borrow compiles (E0596) — the same
    /// mechanism `params_binding_prologue` uses for reassigned parameters
    /// (issue #287). This aliases the local *copy* of the field (the by-value
    /// receiver model clones `self`), the documented method-model limitation.
    fn field_alias_prologue(
        &self,
        owner_td: &TypeDefinition,
        body: Option<&Expression>,
        indent: &str,
    ) -> String {
        let mut out = String::new();
        for field_name in self.all_instance_field_names(owner_td) {
            self.bind_local(&field_name);
            let keyword = if body.is_some_and(|body| self.expr_mutates_var(body, &field_name)) {
                "let mut"
            } else {
                "let"
            };
            out.push_str(&format!(
                "{indent}{keyword} {} = ball_field_get(self_.clone(), {field_name:?});\n",
                crate::sanitize_ident(&field_name)
            ));
        }
        out
    }

    /// Emit the `let`-bindings that destructure a function/method's single
    /// `input` (invariant #1) into each declared parameter, per the reference
    /// encoders' call-site convention (`dart/encoder/lib/encoder.dart`'s
    /// `_encodeArgList` + `_setCallInput`):
    ///
    /// - A **positional** parameter arrives as an `arg0`/`arg1`/… field of the
    ///   `input` message (positional index, the `self` receiver excluded), so
    ///   it binds via `ball_field_get(input, "arg{i}")`.
    /// - A **named** parameter (`is_named`/`is_required_named`/
    ///   `is_optional_named` — Dart's `{x}` / `{required x}` / optional-named
    ///   forms) arrives under its own name, so it binds via
    ///   `ball_field_get(input, "<name>")`.
    /// - The `self` receiver (bound separately as `self_` by
    ///   [`Compiler::method_prologue`]) is skipped and never counts toward the
    ///   positional index.
    ///
    /// When `single_positional_is_direct` is set — a free function, a lambda,
    /// or a *static* (receiver-less) member — and the function declares exactly
    /// one positional, non-`self` parameter, the encoder passes that lone
    /// argument *directly* rather than wrapped in a message (`_setCallInput`'s
    /// `args.length == 1 && arg0` branch), so it binds `let <name> =
    /// input.clone();`. An instance method always receives the `{self, arg0, …}`
    /// message, so it passes `false` and extracts every parameter from a field.
    ///
    /// Each binding is `let mut` when [`Compiler::expr_mutates_var`] finds the
    /// body reassigning that parameter (a counter/accumulator/out-parameter
    /// shape — issue #287), so a self-reassigning parameter doesn't hit Rust's
    /// "cannot assign twice to immutable variable"/"cannot borrow as mutable".
    pub(crate) fn params_binding_prologue(
        &self,
        func: &FunctionDefinition,
        single_positional_is_direct: bool,
    ) -> String {
        let Some(meta) = &func.metadata else {
            return String::new();
        };
        let Some(params) = meta_list_value(meta, "params") else {
            return String::new();
        };
        // (name, is_named) for each parameter beyond the implicit receiver, in
        // declaration order.
        let mut decls: Vec<(String, bool)> = Vec::new();
        for param in params {
            let Some(Kind::StructValue(param_struct)) = &param.kind else {
                continue;
            };
            let Some(name) = meta_string_value(param_struct, "name") else {
                continue;
            };
            if name.is_empty() || name == "self" {
                continue;
            }
            let is_named = meta_bool_value(param_struct, "is_named")
                || meta_bool_value(param_struct, "is_required_named")
                || meta_bool_value(param_struct, "is_optional_named");
            decls.push((name, is_named));
        }
        if decls.is_empty() {
            return String::new();
        }

        let keyword = |name: &str| {
            let mutates = func
                .body
                .as_deref()
                .is_some_and(|body| self.expr_mutates_var(body, name));
            if mutates { "let mut" } else { "let" }
        };

        // The lone positional argument of a receiver-less function is passed
        // directly, so `input` *is* that value — mirrors
        // [`Compiler::param_alias_prologue`]'s original single-parameter path
        // and the `name == "input"` short-circuit (the body already reads the
        // Rust `input` parameter).
        if single_positional_is_direct && decls.len() == 1 && !decls[0].1 {
            let name = &decls[0].0;
            if name == "input" {
                return String::new();
            }
            // Record the parameter as a local so a call/reference to it
            // resolves as a value, not a function item (issue #39, gap #6).
            self.bind_local(name);
            return format!(
                "{} {} = input.clone();\n",
                keyword(name),
                crate::sanitize_ident(name)
            );
        }

        let mut out = String::new();
        let mut positional_index = 0;
        // A parameter literally named `input` shadows the Rust `input` envelope
        // every other getter reads from (`StdModuleHandler.call(function, input,
        // engine)` — issue #300). Its binding is therefore deferred to *last*,
        // after every other parameter has been extracted from the still-raw
        // `input`, so `let input = …` does not disturb them.
        let mut input_binding: Option<String> = None;
        for (name, is_named) in &decls {
            // A named argument always arrives under its own name; a positional
            // one arrives as `arg{i}` but may be passed by name instead (see
            // [`ball_shared::runtime::ball_arg_get`]).
            let getter = if *is_named {
                format!("ball_field_get(input.clone(), {name:?})")
            } else {
                let positional_key = format!("arg{positional_index}");
                positional_index += 1;
                format!("ball_arg_get(input.clone(), {name:?}, {positional_key:?})")
            };
            self.bind_local(name);
            let binding = format!(
                "{} {} = {getter};\n",
                keyword(name),
                crate::sanitize_ident(name)
            );
            if name == "input" {
                input_binding = Some(binding);
            } else {
                out.push_str(&binding);
            }
        }
        if let Some(binding) = input_binding {
            out.push_str(&binding);
        }
        out
    }

    /// `pub fn <short>(input: BallValue) -> BallValue { ... }` for a
    /// constructor. Every #38 fixture's constructors are Dart's
    /// `Point(this.x, this.y)` init-formal-parameter shape (`body: None`,
    /// only `metadata.params` — each an `{name, is_this}` pair) — so the
    /// synthesized body just builds a `BallValue::Message` with one field
    /// per `is_this` param, read from `input`'s field of the same name (the
    /// convention [`Compiler::constructor_field_names`] documents). A
    /// constructor that *does* carry a real body (Java/TS-style `this.x =
    /// x;` assignments — not exercised by any required #38 fixture)
    /// compiles that body directly instead, as a defensive fallback: never
    /// a compiler panic, just without the synthesized field-building this
    /// shape doesn't need.
    fn compile_constructor(&self, owner_td: &TypeDefinition, ctor: &FunctionDefinition) -> String {
        let short = member_short_name(&ctor.name);
        if let Some(body) = &ctor.body {
            return self.compile_constructor_with_body(owner_td, ctor, body, &short);
        }
        let params = self.constructor_field_names(&owner_td.name);
        let mut inserts = String::new();
        for (name, is_this) in &params {
            if *is_this {
                inserts.push_str(&format!(
                    "__ball_map.insert({name:?}.to_string(), ball_field_get(input.clone(), {name:?}));\n"
                ));
            }
        }
        format!(
            "    pub fn {short}(input: BallValue) -> BallValue {{\n\
             let mut __ball_map = BallMap::new();\n{inserts}\
             BallValue::Message(BallMessage::new({:?}, __ball_map))\n\
             }}\n",
            owner_td.name
        )
    }

    /// A constructor that carries a **real body** (initializer-list +
    /// statements — the engine's `BallEngine(...)` / `BallObject(...)`, not the
    /// #38 fixtures' bodyless `Point(this.x, this.y)` init-formal shape). The
    /// synthesized associated fn (issue #39 gap #5):
    ///
    /// 1. binds each declared parameter from `input`
    ///    ([`Compiler::params_binding_prologue`]);
    /// 2. builds the instance `self_` — every instance field (own + inherited)
    ///    defaulted to `Null`, then overridden by each `this.`-formal parameter
    ///    and by every `metadata.initializers` field initializer whose value is
    ///    a plain parameter reference (the common `field = param` /
    ///    `field = param ?? default` shape; a richer initializer expression —
    ///    stored by the encoders as cosmetic source text, not an expression
    ///    tree — is a best-effort `Null`, the documented boundary);
    /// 3. binds each instance field as a local alias so the body's bare field
    ///    references resolve ([`Compiler::field_alias_prologue`]);
    /// 4. runs the body; then
    /// 5. writes every body-mutated field back into `self_` and returns it.
    ///
    /// Constructors are invoked directly only by the runtime wrapper (a
    /// `MessageCreation` builds its instance inline — see
    /// [`Compiler::compile_message_creation`]), so this is primarily the
    /// self-host wrapper's construction seam; the point here is a faithful,
    /// type-checking instance-building constructor rather than a body compiled
    /// with no `self_`/field/parameter bindings in scope.
    fn compile_constructor_with_body(
        &self,
        owner_td: &TypeDefinition,
        ctor: &FunctionDefinition,
        body: &Expression,
        short: &str,
    ) -> String {
        self.push_scope();
        self.bind_local("input");
        let params_prologue = self.params_binding_prologue(ctor, false);
        let self_init = self.constructor_self_init(owner_td, ctor);
        self.bind_local("self");
        // Stable receiver clone for implicit-`this` injection (see
        // [`Compiler::method_prologue`] for why this is a dedicated local).
        self.bind_local("__self_recv");
        let field_aliases = self.field_alias_prologue(owner_td, Some(body), "");
        // A body-carrying constructor has a bound `self_`, so implicit-`this`
        // calls in its body (`this._buildLookupTables()`, …) inject the
        // receiver (issue #298).
        let body_code = self.with_instance_method(true, || self.compile_expression(body));
        let mut writeback = String::new();
        for field_name in self.all_instance_field_names(owner_td) {
            if self.expr_mutates_var(body, &field_name) {
                // Reference-semantic message field write-back (issue #298):
                // `self_`'s fields live behind a shared `Arc<Mutex>`, so
                // `ball_field_set` persists the body-mutated field alias into
                // the instance (visible to every holder of it — the caller, and
                // any later method call on the same instance).
                writeback.push_str(&format!(
                    "ball_field_set(&mut self_, {field_name:?}, {}.clone());\n",
                    crate::sanitize_ident(&field_name)
                ));
            }
        }
        self.pop_scope();
        format!(
            "    pub fn {short}(input: BallValue) -> BallValue {{\n\
             {params_prologue}\
             let mut self_ = {self_init};\n\
             let __self_recv = self_.clone();\n\
             {field_aliases}\
             (|| -> BallValue {{\n{body_code}\n}})();\n\
             {writeback}\
             self_\n\
             }}\n"
        )
    }

    /// Build the initial instance `BallValue::Message` for a body-carrying
    /// constructor: every instance field (own + inherited) starts `Null`, then
    /// each `this.`-formal parameter and each parameter-referencing field
    /// initializer overrides its field with the (already-bound) parameter local
    /// (see [`Compiler::compile_constructor_with_body`]).
    /// The field-level default initializer's cosmetic source text for instance
    /// field `field` of `td` (searching `td`'s own then each inherited
    /// `metadata.fields[]` entry). The encoders record `final Map … _functions
    /// = {}` as an `{name: "_functions", initializer: "{}"}` field entry — this
    /// is the raw `"{}"`/`"[]"`/`"_Scope()"`/… text.
    /// Resolve a `MessageCreation.type_name` (full, e.g. `main:_Scope`) to its
    /// user `TypeDefinition`, or `None` for a Dart-SDK constructor / unknown
    /// type (no `TypeDefinition` — e.g. `List.filled`, `StringBuffer`).
    pub(crate) fn type_def_for(&self, type_name: &str) -> Option<&TypeDefinition> {
        self.type_defs_by_short_name
            .get(type_short_name(type_name))
            .copied()
    }

    /// The Rust associated-fn path (`main_BallObject::new`) of `type_name`'s
    /// **body-carrying constructor**, if it has one — the constructor whose
    /// body must actually *run* on construction (issue #300). Returns `None`
    /// for a type with only an init-formal (bodyless) constructor or no
    /// constructor (both build correctly as an inline field map).
    pub(crate) fn body_constructor_fn(&self, type_name: &str) -> Option<String> {
        let members = self.class_members_by_owner.get(type_name)?;
        let ctor = members.iter().copied().find(|member| {
            func_meta_kind(member).as_deref() == Some("constructor") && member.body.is_some()
        })?;
        Some(format!(
            "{}::{}",
            crate::sanitize_ident(type_name),
            member_short_name(&ctor.name)
        ))
    }

    pub(crate) fn field_initializer_text(
        &self,
        td: &TypeDefinition,
        field: &str,
    ) -> Option<String> {
        let mut current = td;
        for _ in 0..32 {
            if let Some(meta) = &current.metadata {
                if let Some(fields) = meta_list_value(meta, "fields") {
                    for entry in fields {
                        let Some(Kind::StructValue(entry_struct)) = &entry.kind else {
                            continue;
                        };
                        if meta_string_value(entry_struct, "name").as_deref() == Some(field) {
                            // The first (own-most) declaration of `field` wins,
                            // whether or not it carries an initializer.
                            return meta_string_value(entry_struct, "initializer");
                        }
                    }
                }
            }
            let Some(super_name) = superclass_of(current) else {
                break;
            };
            match self.type_defs_by_short_name.get(super_name.as_str()) {
                Some(super_td) => current = super_td,
                None => break,
            }
        }
        None
    }

    /// Lower a field-level initializer's cosmetic source text
    /// ([`Compiler::field_initializer_text`]) to a Rust `BallValue` expression
    /// for the common literal / zero-argument-constructor shapes — the
    /// constructor/message-creation field-default fix (issue #300): `_functions
    /// = {}` must build an empty map, not `Null` (which panicked the moment the
    /// engine indexed it), and `_globalScope = _Scope()` must build a real
    /// `_Scope` instance (with its own `_bindings = {}` default, recursively).
    /// A richer initializer expression the encoder stored only as source text
    /// yields `None` — the documented best-effort boundary (the field stays
    /// `Null`). `visiting` guards against a cyclic constructor-default chain.
    pub(crate) fn lower_field_initializer(
        &self,
        init: &str,
        visiting: &mut Vec<String>,
    ) -> Option<String> {
        let s = strip_generic_prefix(init.trim());
        match s {
            "{}" => return Some("BallValue::Map(BallMap::new())".to_string()),
            "[]" => return Some("BallValue::List(BallList::new())".to_string()),
            "''" | "\"\"" => return Some("BallValue::String(String::new())".to_string()),
            "true" => return Some("BallValue::Bool(true)".to_string()),
            "false" => return Some("BallValue::Bool(false)".to_string()),
            "null" => return Some("BallValue::Null".to_string()),
            _ => {}
        }
        if let Ok(int_value) = s.parse::<i64>() {
            return Some(format!("BallValue::Int({int_value}i64)"));
        }
        if let Ok(double_value) = s.parse::<f64>() {
            if double_value.is_finite() {
                return Some(format!("BallValue::Double({double_value}f64)"));
            }
        }
        if let Some(type_name) = s.strip_suffix("()") {
            let type_name = type_name.trim();
            if is_simple_ident(type_name) {
                return self.default_instance_of(type_name, visiting);
            }
        }
        None
    }

    /// Build a default instance of the class `short` (a `Type()` field
    /// initializer): a `BallValue::Message` whose every instance field is set
    /// to its own field-level default (recursively lowered) or `Null`. Returns
    /// `None` for an unknown class or a cycle (the field then stays `Null`).
    fn default_instance_of(&self, short: &str, visiting: &mut Vec<String>) -> Option<String> {
        let td = *self.type_defs_by_short_name.get(short)?;
        if visiting.iter().any(|v| v == short) {
            return None;
        }
        visiting.push(short.to_string());
        let mut inserts = String::new();
        for field in self.all_instance_field_names(td) {
            let value = self
                .field_initializer_text(td, &field)
                .and_then(|init| self.lower_field_initializer(&init, visiting))
                .unwrap_or_else(|| "BallValue::Null".to_string());
            inserts.push_str(&format!(
                "__ball_map.insert({field:?}.to_string(), {value});\n"
            ));
        }
        visiting.pop();
        Some(format!(
            "{{ let mut __ball_map = BallMap::new(); {inserts}\
             BallValue::Message(BallMessage::new({:?}, __ball_map)) }}",
            td.name
        ))
    }

    /// The default for a **native superclass** backing field of `owner_td` —
    /// currently just `BallMap`'s ordered-map `entries` (an empty map). Returns
    /// `None` when `field` is not such a field. Issue #300.
    fn native_inherited_field_default(
        &self,
        owner_td: &TypeDefinition,
        field: &str,
    ) -> Option<String> {
        let mut current = owner_td;
        for _ in 0..32 {
            let super_name = superclass_of(current)?;
            match self.type_defs_by_short_name.get(super_name.as_str()) {
                Some(super_td) => current = super_td,
                None => {
                    // A native (no-`TypeDefinition`) base: `BallMap`'s `entries`.
                    if native_superclass_fields(&super_name).contains(&field) && field == "entries"
                    {
                        return Some("BallValue::Map(BallMap::new())".to_string());
                    }
                    return None;
                }
            }
        }
        None
    }

    fn constructor_self_init(
        &self,
        owner_td: &TypeDefinition,
        ctor: &FunctionDefinition,
    ) -> String {
        let params = ctor_params(ctor);
        let param_names: std::collections::HashSet<&str> =
            params.iter().map(|(name, _)| name.as_str()).collect();
        let mut inserts = String::new();
        for field in self.all_instance_field_names(owner_td) {
            let value = if params
                .iter()
                .any(|(name, is_this)| *is_this && name == &field)
            {
                format!("{}.clone()", crate::sanitize_ident(&field))
            } else if let Some(param) = field_initializer_param(ctor, &field, &param_names) {
                format!("{}.clone()", crate::sanitize_ident(&param))
            } else if let Some(default) = self
                .field_initializer_text(owner_td, &field)
                .and_then(|init| self.lower_field_initializer(&init, &mut Vec::new()))
            {
                // A field-level default initializer (`final … _functions = {}`)
                // — an empty map/list/string/instance, not `Null` (issue #300).
                default
            } else if let Some(default) = self.native_inherited_field_default(owner_td, &field) {
                // A native-superclass backing field (`BallObject extends BallMap`
                // inherits the ordered-map `entries`) — its `super(<…>{})` call
                // seeds an empty map, which we cannot run (BallMap is native), so
                // default it directly (issue #300 — else `_refreshEntries`'s
                // `entries..clear()` panics on `Null`).
                default
            } else {
                "BallValue::Null".to_string()
            };
            inserts.push_str(&format!(
                "__ball_map.insert({field:?}.to_string(), {value});\n"
            ));
        }
        format!(
            "{{ let mut __ball_map = BallMap::new(); {inserts}\
             BallValue::Message(BallMessage::new({:?}, __ball_map)) }}",
            owner_td.name
        )
    }

    /// The constructor registered for `type_name` (via
    /// [`Compiler::class_members_by_owner`]), if any, as `(param_name,
    /// is_this)` pairs in declaration order — the shape both
    /// [`Compiler::compile_constructor`] (which field to build) and
    /// [`Compiler::compile_message_creation`] (which real field name a
    /// positional `argN` maps to) need. Returns an empty `Vec` for a type
    /// with no registered constructor (a plain literal-field
    /// `MessageCreation`, or a type this compiler never saw a
    /// `TypeDefinition` for at all) — the caller's own fallback (keep the
    /// field name as given) then applies unchanged.
    pub(crate) fn constructor_field_names(&self, type_name: &str) -> Vec<(String, bool)> {
        // Value-wrapper classes (`BallInt`/`BallDouble`/`BallString`/`BallBool`)
        // live in `ball_value.dart`, outside the self-host part graph, so they
        // carry no `TypeDefinition`/constructor metadata — yet the engine
        // constructs them positionally (`_evalLiteral` builds
        // `BallDouble(lit.doubleValue)`) and reads them back through their
        // single `value` field (`_toNum`/`_toDouble`/… do `v.value`). Each
        // wraps exactly one `value` (see `dart/engine/lib/ball_value.dart`), so
        // map the positional `arg0` to `value`; otherwise the value is stored
        // under `arg0` and every `.value` read is `Null` — which panicked
        // double-literal arithmetic with `expected a number, got Null`
        // (#39/#300). `BallNull` has no field and needs no entry.
        if matches!(
            type_short_name(type_name),
            "BallInt" | "BallDouble" | "BallString" | "BallBool"
        ) {
            return vec![("value".to_string(), true)];
        }
        let Some(members) = self.class_members_by_owner.get(type_name) else {
            return Vec::new();
        };
        let Some(ctor) = members
            .iter()
            .find(|m| func_meta_kind(m).as_deref() == Some("constructor"))
        else {
            return Vec::new();
        };
        let Some(meta) = &ctor.metadata else {
            return Vec::new();
        };
        let Some(params) = meta_list_value(meta, "params") else {
            return Vec::new();
        };
        params
            .iter()
            .filter_map(|v| match &v.kind {
                Some(Kind::StructValue(param_struct)) => {
                    let name = meta_string_value(param_struct, "name")?;
                    let is_this = meta_bool_value(param_struct, "is_this");
                    Some((name, is_this))
                }
                _ => None,
            })
            .collect()
    }

    // ════════════════════════════════════════════════════════════
    // Polymorphic method dispatch
    // ════════════════════════════════════════════════════════════

    /// Free dispatcher functions — one per method short name shared by 1+
    /// owner types declared in `module` (see the crate root doc comment for
    /// why this exists: a polymorphic method call site only knows the short
    /// name, e.g. `area`, not which concrete `impl` to reach — that's
    /// resolved at *run time* here, by switching on the receiver's actual
    /// `BallValue::Message::type_name`). Abstract (bodyless) members are
    /// excluded — they have no `impl` to route to (matches
    /// [`Compiler::compile_struct_def`]'s own exclusion). Constructors are
    /// excluded too — they're never invoked through a `call` node in any
    /// required #38 fixture (construction is a direct, compile-time-
    /// resolved `MessageCreation`), so a `new` dispatcher would just be
    /// dead code.
    ///
    /// A short name with exactly one owner whose member is itself
    /// receiver-less (`is_static` — see [`Compiler::method_prologue`]'s doc
    /// comment) skips the self-typed `match` entirely and forwards straight
    /// into that one `impl` block instead: a receiver-less call's `input`
    /// never carries a `"self"` field (there is no receiver value to read
    /// one off of), so the ordinary self-typed dispatch below — which reads
    /// exactly that field to decide which `impl` to route to — would panic
    /// before ever reaching the static member itself (issue #288). A short
    /// name shared by more than one *static* owner has no receiver value to
    /// disambiguate by at all — call sites for that shape aren't produced by
    /// any reference encoder yet, so it falls back to the same self-typed
    /// dispatch as an ordinary instance method (unchanged from before this
    /// fix, and no worse: it already panicked on every static call).
    pub(crate) fn compile_method_dispatchers(&self, module: &Module) -> String {
        let mut owners_by_short: HashMap<String, Vec<(&TypeDefinition, &FunctionDefinition)>> =
            HashMap::new();
        let mut short_name_order: Vec<String> = Vec::new();

        for td in &module.type_defs {
            for member in self
                .class_members_by_owner
                .get(&td.name)
                .into_iter()
                .flatten()
            {
                if func_meta_kind(member).as_deref() == Some("constructor") {
                    continue;
                }
                if func_meta_bool(member, "is_abstract") {
                    continue;
                }
                let short = member_short_name(&member.name);
                if !owners_by_short.contains_key(&short) {
                    short_name_order.push(short.clone());
                }
                owners_by_short.entry(short).or_default().push((td, member));
            }
        }

        let mut out = String::new();
        for short in short_name_order {
            let owners = &owners_by_short[&short];
            if let [(td, member)] = owners.as_slice() {
                if func_meta_bool(member, "is_static") {
                    let rust_name = crate::sanitize_ident(&td.name);
                    out.push_str(&format!(
                        "pub fn {short}(input: BallValue) -> BallValue {{\n    {rust_name}::{short}(input)\n}}\n\n"
                    ));
                    continue;
                }
            }
            out.push_str(&format!(
                "pub fn {short}(input: BallValue) -> BallValue {{\n"
            ));
            out.push_str("    let __self = ball_field_get(input.clone(), \"self\");\n");
            // `toString` is defined on EVERY Dart value (`Object.toString`), so
            // its dispatcher must accept a non-message receiver — a String/int/
            // list — rather than panic in `ball_message_type_name`. The
            // self-hosted engine's `_ballToStringAsync` does `result?.toString()`
            // where the user `toString` already returned a `String`; without this
            // fallback that `.toString()` on the `String` panicked, so every
            // class print fell back to the raw instance dump (issues #39/#300,
            // bucket 2). A message of a class that DOES override `toString`
            // routes to it; anything else (a primitive, or a message with no
            // override) uses the built-in stringify — matching Dart, where
            // `.toString()` never fails.
            if short == "toString" {
                out.push_str("    if let BallValue::Message(__m) = &__self {\n");
                out.push_str("        match __m.type_name.as_str() {\n");
                for (td, _) in owners {
                    let rust_name = crate::sanitize_ident(&td.name);
                    out.push_str(&format!(
                        "            {:?} => return {rust_name}::{short}(input),\n",
                        td.name
                    ));
                }
                out.push_str("            _ => {}\n");
                out.push_str("        }\n");
                out.push_str("    }\n");
                out.push_str("    ball_to_string(__self)\n");
                out.push_str("}\n\n");
                continue;
            }
            out.push_str("    match ball_message_type_name(&__self).as_str() {\n");
            for (td, _) in owners {
                let rust_name = crate::sanitize_ident(&td.name);
                out.push_str(&format!(
                    "        {:?} => {rust_name}::{short}(input),\n",
                    td.name
                ));
            }
            out.push_str(&format!(
                "        other => panic!(\"ball-compiler runtime: no method '{short}' for type '{{}}'\", other),\n"
            ));
            out.push_str("    }\n}\n\n");
        }
        out
    }
}
