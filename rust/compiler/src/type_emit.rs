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

use ball_shared::proto::ball::v1::{FunctionDefinition, Module, TypeDefinition};
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

/// `func.metadata.kind`, if present.
fn func_meta_kind(func: &FunctionDefinition) -> Option<String> {
    func.metadata
        .as_ref()
        .and_then(|m| meta_string_value(m, "kind"))
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

    /// Dispatch a single `TypeDefinition` to a `struct` (plain class) or
    /// `trait` (abstract class/interface) — `enum`-kind `TypeDefinition`s
    /// are never reached here (see [`Compiler::compile_module_types`]'s
    /// guard). `metadata.is_abstract` (set on the `TypeDefinition` itself,
    /// e.g. `main:Shape`) decides struct vs. trait, matching the issue's
    /// "kind → Rust shape" table (`"class"` → struct, abstract/interface →
    /// trait).
    fn compile_type_def(&self, td: &TypeDefinition) -> String {
        let is_abstract = td
            .metadata
            .as_ref()
            .map(|m| meta_bool_value(m, "is_abstract"))
            .unwrap_or(false);
        if is_abstract {
            self.compile_trait_def(td)
        } else {
            self.compile_struct_def(td)
        }
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

    /// `trait <Name> { fn method(input: BallValue) -> BallValue; ... }` for
    /// an abstract class/interface. Each abstract (bodyless) member becomes
    /// a signature-only trait method; a member that *does* carry a body (a
    /// concrete/default method declared directly on the abstract class)
    /// becomes a trait method with a default implementation. Nothing
    /// actually `impl`s this trait — see the crate root doc comment for why
    /// (dispatch is by runtime `type_name`, not Rust's trait system); it
    /// exists purely as a faithful, documentation-level shape declaration
    /// (harmless if never used — `#![allow(dead_code)]` already covers it).
    fn compile_trait_def(&self, td: &TypeDefinition) -> String {
        let rust_name = crate::sanitize_ident(&td.name);
        let mut out = format!("pub trait {rust_name} {{\n");
        for member in self
            .class_members_by_owner
            .get(&td.name)
            .into_iter()
            .flatten()
        {
            let short = member_short_name(&member.name);
            match &member.body {
                None => out.push_str(&format!("    fn {short}(input: BallValue) -> BallValue;\n")),
                Some(body) => {
                    let body_code = self.compile_expression(body);
                    out.push_str(&format!(
                        "    fn {short}(input: BallValue) -> BallValue {{\n{body_code}\n    }}\n"
                    ));
                }
            }
        }
        out.push_str("}\n");
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
                 let {var} = BallValue::Message(BallMessage {{ type_name: {full_name:?}.to_string(), fields: __m{index} }});\n\
                 __ns.insert({member_name:?}.to_string(), {var}.clone());\n"
            ));
            list_items.push_str(&format!("{var}.clone(), "));
        }
        format!(
            "pub static {short_name}: std::sync::LazyLock<BallValue> = std::sync::LazyLock::new(|| {{\n\
             let mut __ns = BallMap::new();\n{member_code}\
             __ns.insert(\"values\".to_string(), BallValue::List(vec![{list_items}]));\n\
             BallValue::Message(BallMessage {{ type_name: {full_name:?}.to_string(), fields: __ns }})\n\
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
        let prologue = self.method_prologue(owner_td, func);
        let body = match &func.body {
            Some(body) => self.compile_expression(body),
            None => "BallValue::Null".to_string(),
        };
        format!("    pub fn {short}(input: BallValue) -> BallValue {{\n{prologue}{body}\n    }}\n")
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
    fn method_prologue(&self, owner_td: &TypeDefinition, func: &FunctionDefinition) -> String {
        let mut out =
            String::from("        let self_ = ball_field_get(input.clone(), \"self\");\n");
        if let Some(descriptor) = &owner_td.descriptor {
            for field in &descriptor.field {
                let Some(field_name) = field.name.as_deref() else {
                    continue;
                };
                out.push_str(&format!(
                    "        let {} = ball_field_get(self_.clone(), {field_name:?});\n",
                    crate::sanitize_ident(field_name)
                ));
            }
        }
        if let Some(meta) = &func.metadata {
            if let Some(params) = meta_list_value(meta, "params") {
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
                    out.push_str(&format!(
                        "        let {} = ball_field_get(input.clone(), {name:?});\n",
                        crate::sanitize_ident(&name)
                    ));
                }
            }
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
            let body_code = self.compile_expression(body);
            return format!(
                "    pub fn {short}(input: BallValue) -> BallValue {{\n{body_code}\n    }}\n"
            );
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
             BallValue::Message(BallMessage {{ type_name: {:?}.to_string(), fields: __ball_map }})\n\
             }}\n",
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
    pub(crate) fn compile_method_dispatchers(&self, module: &Module) -> String {
        let mut owners_by_short: HashMap<String, Vec<&TypeDefinition>> = HashMap::new();
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
                owners_by_short.entry(short).or_default().push(td);
            }
        }

        let mut out = String::new();
        for short in short_name_order {
            let owners = &owners_by_short[&short];
            out.push_str(&format!(
                "pub fn {short}(input: BallValue) -> BallValue {{\n"
            ));
            out.push_str("    let __self = ball_field_get(input.clone(), \"self\");\n");
            out.push_str("    match ball_message_type_name(&__self).as_str() {\n");
            for td in owners {
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
