//! Type declarations → Ball `TypeDefinition`s (issue #43): `struct` (named
//! fields only) → a class-shaped `TypeDefinition` + `DescriptorProto`;
//! `enum` (fieldless variants only) → `Module.enums[]` (an
//! `EnumDescriptorProto`) plus a companion, descriptor-less `TypeDefinition`;
//! `trait` → an `is_abstract` `TypeDefinition` with signature-only abstract
//! members; `impl`/`impl Trait for Type` blocks → instance methods
//! registered as `<Owner>.<method>` `FunctionDefinition`s. Mirrors
//! `dart/encoder/lib/encoder.dart`'s class/enum/abstract-class encoding
//! (the reference implementation this issue names) adapted to Rust's own
//! `struct`/`enum`/`trait`/`impl` split — there is no single "class"
//! keyword to dispatch on the way Dart has one.
//!
//! ## Why an associated function with no `self` receiver is a documented gap
//!
//! `ball-compiler`'s `method_prologue` (`rust/compiler/src/type_emit.rs`)
//! *unconditionally* extracts a `"self"` field from `input` and then reads
//! every owner-type descriptor field *off of it* — and `ball_field_get`
//! (`rust/shared/src/runtime.rs`) panics at run time on a non-message/
//! non-map value. An associated function called without a receiver
//! (`Point::new(3, 4)`) has no `"self"` field in its packed `input`, so
//! encoding it through the same `<Owner>.<method>` class-member path this
//! module uses for instance methods would produce a Ball program that
//! panics the moment it runs — a silent semantic corruption, not merely an
//! unimplemented feature. Rust's own idiomatic alternative — a direct
//! struct-literal expression (`Point { x: 3, y: 4 }`,
//! [`Encoder::encode_struct_literal`]) — covers construction without this
//! trap, since it needs no constructor at all (it's a plain
//! `message_creation`, exactly like every other reference encoder's
//! constructor-less literal-field instantiation path). Encountering
//! `Type::new(...)`-style call syntax therefore still hits `encode_call`'s
//! existing "unsupported call target" panic (issue #42) rather than being
//! silently accepted and miscompiled.
//!
//! ## Why a method mutating its own field is out of scope
//!
//! `method_prologue` extracts `self_` via `input.clone()`'s `"self"` field —
//! already a *clone* of whatever the caller passed as the receiver. Even a
//! correctly-compiling `self.field = value;` inside a method body would only
//! mutate that local clone, never the caller's own instance — so this crate
//! deliberately never writes a fixture (or documents an idiom) relying on an
//! instance method observably mutating its receiver; external mutation
//! (`instance.field = value;`, already supported since issue #42 via
//! ordinary `field_access` + `std.assign`) is the correct, working idiom
//! (matches `tests/conformance/101_simple_class.ball.json`'s own
//! `p2.x = 5;` outside any method).
use ball_shared::proto::ball::v1::expression::Expr;
use ball_shared::proto::ball::v1::{
    Expression, FieldValuePair, FunctionDefinition, MessageCreation, TypeDefinition, TypeParameter,
};
use ball_shared::proto::google::protobuf::field_descriptor_proto::{
    Label as ProtoLabel, Type as ProtoType,
};
use ball_shared::proto::google::protobuf::{
    DescriptorProto, EnumDescriptorProto, EnumValueDescriptorProto, FieldDescriptorProto,
};

use crate::{Encoder, MetaBuilder, bool_value, is_pub, str_value, struct_value, type_to_string};

/// This crate encodes one whole file into a single Ball module named
/// `"main"` (see the crate root doc comment) — every type name is qualified
/// with that fixed prefix, matching `dart/encoder/lib/encoder.dart`'s own
/// `"$moduleName:$shortName"` convention (`ballName` in that file).
const MODULE_PREFIX: &str = "main";

/// `"Point"` → `"main:Point"` — see [`MODULE_PREFIX`].
pub(crate) fn qualified_type_name(short_name: &str) -> String {
    format!("{MODULE_PREFIX}:{short_name}")
}

impl Encoder {
    // ════════════════════════════════════════════════════════════
    // struct
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_item_struct(&mut self, item: &syn::ItemStruct) -> TypeDefinition {
        let short = item.ident.to_string();
        let full = qualified_type_name(&short);
        let syn::Fields::Named(named) = &item.fields else {
            panic!(
                "ball-encoder: only a struct with named fields is supported (tuple/unit \
                 structs are a documented gap): `struct {short}`"
            );
        };

        let mut proto_fields = Vec::with_capacity(named.named.len());
        let mut fields_meta = Vec::with_capacity(named.named.len());
        for (index, field) in named.named.iter().enumerate() {
            let field_name = field
                .ident
                .as_ref()
                .expect("a named field always has an identifier")
                .to_string();
            proto_fields.push(field_descriptor(&field_name, (index + 1) as i32, &field.ty));
            fields_meta.push(struct_value(vec![
                ("name", str_value(&field_name)),
                ("type", str_value(type_to_string(&field.ty))),
                ("is_public", bool_value(is_pub(&field.vis))),
            ]));
        }

        let mut meta = MetaBuilder::new();
        meta.set_string("kind", "struct");
        meta.set_bool_if_true("is_public", is_pub(&item.vis));
        meta.set_list_if_nonempty("fields", fields_meta);
        meta.set_type_params(&item.generics);

        TypeDefinition {
            name: full.clone(),
            descriptor: Some(DescriptorProto {
                name: Some(full.clone()),
                field: proto_fields,
                ..Default::default()
            }),
            type_params: type_parameters(&item.generics),
            description: format!("Struct metadata for {full}"),
            metadata: meta.build(),
        }
    }

    /// `Point { x: 3, y: 4 }` / shorthand `Point { x, y }` → a
    /// `message_creation` under the type's real, module-qualified name,
    /// with each field keyed by its real declared name (never the
    /// positional `arg0`/`arg1` convention a *constructor call* would use —
    /// this crate never encodes a Dart-style init-formal-parameter
    /// constructor at all, see the module doc comment). `syn` already
    /// desugars the shorthand form (`.expr` is a path expression naming the
    /// same-named local) before this ever runs, so both forms are handled
    /// identically.
    pub(crate) fn encode_struct_literal(&mut self, e: &syn::ExprStruct) -> Expression {
        if e.rest.is_some() {
            panic!(
                "ball-encoder: struct-update syntax (`..base`) is not supported (a documented \
                 gap)"
            );
        }
        let short = e
            .path
            .segments
            .last()
            .expect("a struct-literal path always has at least one segment")
            .ident
            .to_string();
        let full = qualified_type_name(&short);
        let fields = e
            .fields
            .iter()
            .map(|field_value| {
                let name = member_name(&field_value.member);
                let value = self.encode_expr(&field_value.expr);
                FieldValuePair {
                    name,
                    value: Some(value),
                }
            })
            .collect();
        Expression {
            expr: Some(Expr::MessageCreation(MessageCreation {
                type_name: full,
                fields,
                metadata: None,
            })),
        }
    }

    // ════════════════════════════════════════════════════════════
    // enum (fieldless variants only)
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_item_enum(
        &mut self,
        item: &syn::ItemEnum,
    ) -> (TypeDefinition, EnumDescriptorProto) {
        let short = item.ident.to_string();
        let full = qualified_type_name(&short);

        let mut values = Vec::with_capacity(item.variants.len());
        let mut values_meta = Vec::with_capacity(item.variants.len());
        for (index, variant) in item.variants.iter().enumerate() {
            if !matches!(variant.fields, syn::Fields::Unit) {
                panic!(
                    "ball-encoder: an enum variant carrying data is not supported (only \
                     fieldless variants — a documented gap): `{short}::{}`",
                    variant.ident
                );
            }
            let variant_name = variant.ident.to_string();
            let number = match &variant.discriminant {
                Some((
                    _,
                    syn::Expr::Lit(syn::ExprLit {
                        lit: syn::Lit::Int(int_lit),
                        ..
                    }),
                )) => int_lit
                    .base10_parse::<i32>()
                    .unwrap_or_else(|err| panic!("ball-encoder: invalid enum discriminant: {err}")),
                _ => index as i32,
            };
            values.push(EnumValueDescriptorProto {
                name: Some(variant_name.clone()),
                number: Some(number),
                options: None,
            });
            values_meta.push(struct_value(vec![("name", str_value(&variant_name))]));
        }

        let mut meta = MetaBuilder::new();
        meta.set_string("kind", "enum");
        meta.set_bool_if_true("is_public", is_pub(&item.vis));
        meta.set_list_if_nonempty("values", values_meta);

        // No `descriptor` at all — mirrors `dart/encoder/lib/encoder.dart`'s
        // own enum `TypeDefinition` shape exactly (the real value/number
        // data lives in the `EnumDescriptorProto` below, not here); this is
        // also the shape `ball-compiler`'s `compile_module_types` relies on
        // to skip re-emitting a redundant declaration (`if
        // td.descriptor.is_none() { continue; }`).
        let type_def = TypeDefinition {
            name: full.clone(),
            descriptor: None,
            type_params: vec![],
            description: format!("Enum metadata for {full}"),
            metadata: meta.build(),
        };
        let enum_def = EnumDescriptorProto {
            name: Some(full),
            value: values,
            ..Default::default()
        };
        (type_def, enum_def)
    }

    // ════════════════════════════════════════════════════════════
    // trait
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_item_trait(
        &mut self,
        item: &syn::ItemTrait,
    ) -> (TypeDefinition, Vec<FunctionDefinition>) {
        let short = item.ident.to_string();
        let full = qualified_type_name(&short);

        let mut members = Vec::new();
        for trait_item in &item.items {
            let syn::TraitItem::Fn(trait_fn) = trait_item else {
                panic!(
                    "ball-encoder: only method signatures are supported inside a `trait` block \
                     (associated consts/types are a documented gap): `trait {short}`"
                );
            };
            if !has_self_receiver(&trait_fn.sig) {
                panic!(
                    "ball-encoder: an associated function with no `self` receiver inside a \
                     `trait` is not supported (see the module doc comment): \
                     `{short}::{}`",
                    trait_fn.sig.ident
                );
            }
            let method_short = trait_fn.sig.ident.to_string();
            let params = method_non_self_params(&trait_fn.sig);
            let is_default_bodied = trait_fn.default.is_some();
            let body = trait_fn
                .default
                .as_ref()
                .map(|block| Box::new(self.encode_block(block)));

            let mut meta = MetaBuilder::new();
            meta.set_string("kind", "method");
            meta.set_bool_if_true("is_abstract", !is_default_bodied);
            meta.set_params(&params);

            members.push(FunctionDefinition {
                name: format!("{full}.{method_short}"),
                input_type: String::new(),
                output_type: return_type_string(&trait_fn.sig),
                body,
                description: String::new(),
                is_base: false,
                metadata: meta.build(),
            });
        }

        let mut meta = MetaBuilder::new();
        meta.set_string("kind", "trait");
        meta.set_bool_if_true("is_abstract", true);
        meta.set_bool_if_true("is_public", is_pub(&item.vis));

        let type_def = TypeDefinition {
            name: full.clone(),
            // A present-but-fieldless descriptor — required so
            // `compile_module_types`'s `if td.descriptor.is_none() {
            // continue; }` guard (which exists to skip the *enum*
            // companion shape, see `encode_item_enum`) doesn't also
            // wrongly skip this trait's own `pub trait { ... }` emission.
            descriptor: Some(DescriptorProto {
                name: Some(full.clone()),
                ..Default::default()
            }),
            type_params: type_parameters(&item.generics),
            description: format!("Trait metadata for {full}"),
            metadata: meta.build(),
        };
        (type_def, members)
    }

    // ════════════════════════════════════════════════════════════
    // impl (instance methods only — see the module doc comment)
    // ════════════════════════════════════════════════════════════

    /// Pre-pass helper (called from [`crate::encode_main_module`]'s first
    /// pass): records every instance method's `(short name → non-`self`
    /// parameter names)` in [`Encoder::method_params`], so a **call** site
    /// that textually precedes the `impl` block (or targets a trait-object
    /// receiver whose concrete `impl` isn't known at the call site at all)
    /// can still pack its arguments under their real parameter names.
    /// Associated functions with no `self` receiver are skipped here, not
    /// panicked on — the loud panic happens only if [`Self::encode_item_impl`]
    /// (the second, encoding pass) actually reaches one.
    pub(crate) fn collect_impl_method_params(&mut self, item_impl: &syn::ItemImpl) {
        for impl_item in &item_impl.items {
            if let syn::ImplItem::Fn(impl_fn) = impl_item {
                if has_self_receiver(&impl_fn.sig) {
                    let short = impl_fn.sig.ident.to_string();
                    let params = method_non_self_params(&impl_fn.sig)
                        .into_iter()
                        .map(|(name, _)| name)
                        .collect();
                    self.method_params.insert(short, params);
                }
            }
        }
    }

    /// `impl Type { ... }` / `impl Trait for Type { ... }` → one
    /// `FunctionDefinition` per instance method, named `<module>:<Type>.
    /// <method>` (the `class_members_by_owner` convention
    /// `rust/compiler/src/type_emit.rs` groups by). The `for Trait` half of
    /// a trait impl is deliberately ignored — dispatch is by the receiver's
    /// *concrete* runtime `type_name`
    /// (`rust/compiler/src/lib.rs::compile_method_dispatchers`), never by
    /// Rust's own trait-resolution rules, so which trait (if any) a method
    /// satisfies has no Ball-level effect to preserve.
    pub(crate) fn encode_item_impl(&mut self, item: &syn::ItemImpl) -> Vec<FunctionDefinition> {
        let owner_short = type_short_name(&item.self_ty);
        let owner_full = qualified_type_name(&owner_short);

        let mut members = Vec::new();
        for impl_item in &item.items {
            let syn::ImplItem::Fn(impl_fn) = impl_item else {
                panic!(
                    "ball-encoder: only methods are supported inside an `impl` block \
                     (associated consts/types are a documented gap): `impl {owner_short}`"
                );
            };
            if !has_self_receiver(&impl_fn.sig) {
                panic!(
                    "ball-encoder: an associated function with no `self` receiver \
                     (`{owner_short}::{}`) is not supported — see the module doc comment; use \
                     a struct-literal expression (`{owner_short} {{ ... }}`) to construct \
                     `{owner_short}` instead",
                    impl_fn.sig.ident
                );
            }
            let method_short = impl_fn.sig.ident.to_string();
            let params = method_non_self_params(&impl_fn.sig);
            let body = self.encode_block(&impl_fn.block);

            let mut meta = MetaBuilder::new();
            meta.set_string("kind", "method");
            meta.set_bool_if_true("is_public", is_pub(&impl_fn.vis));
            meta.set_bool_if_true("is_async", impl_fn.sig.asyncness.is_some());
            meta.set_params(&params);

            members.push(FunctionDefinition {
                name: format!("{owner_full}.{method_short}"),
                input_type: String::new(),
                output_type: return_type_string(&impl_fn.sig),
                body: Some(Box::new(body)),
                description: String::new(),
                is_base: false,
                metadata: meta.build(),
            });
        }
        members
    }
}

// ════════════════════════════════════════════════════════════
// syn helpers
// ════════════════════════════════════════════════════════════

fn member_name(member: &syn::Member) -> String {
    match member {
        syn::Member::Named(ident) => ident.to_string(),
        syn::Member::Unnamed(index) => index.index.to_string(),
    }
}

fn has_self_receiver(sig: &syn::Signature) -> bool {
    matches!(sig.inputs.first(), Some(syn::FnArg::Receiver(_)))
}

/// Extract `(name, type-as-string)` for every parameter **after** the
/// leading `self` receiver — the caller is responsible for having already
/// checked [`has_self_receiver`]. Fails loud on a destructuring parameter
/// pattern, matching `param_names_and_types`'s own posture for free
/// functions.
fn method_non_self_params(sig: &syn::Signature) -> Vec<(String, String)> {
    sig.inputs
        .iter()
        .skip(1)
        .map(|arg| match arg {
            syn::FnArg::Typed(pat_type) => {
                let name = match pat_type.pat.as_ref() {
                    syn::Pat::Ident(syn::PatIdent {
                        ident,
                        subpat: None,
                        ..
                    }) => ident.to_string(),
                    other => panic!(
                        "ball-encoder: only a simple identifier method parameter is supported \
                         (destructuring parameters are a documented gap): {}",
                        quote::quote!(#other)
                    ),
                };
                (name, type_to_string(&pat_type.ty))
            }
            syn::FnArg::Receiver(_) => panic!(
                "ball-encoder: a method may only take one `self` receiver, as its first \
                 parameter"
            ),
        })
        .collect()
}

fn type_short_name(ty: &syn::Type) -> String {
    match ty {
        syn::Type::Path(type_path) => type_path
            .path
            .segments
            .last()
            .expect("a type path always has at least one segment")
            .ident
            .to_string(),
        other => panic!(
            "ball-encoder: unsupported `impl` self type (only a plain named type is \
             supported): {}",
            quote::quote!(#other)
        ),
    }
}

fn return_type_string(sig: &syn::Signature) -> String {
    match &sig.output {
        syn::ReturnType::Default => String::new(),
        syn::ReturnType::Type(_, ty) => type_to_string(ty),
    }
}

fn type_parameters(generics: &syn::Generics) -> Vec<TypeParameter> {
    generics
        .params
        .iter()
        .filter_map(|param| match param {
            syn::GenericParam::Type(type_param) => Some(TypeParameter {
                name: type_param.ident.to_string(),
                metadata: None,
            }),
            _ => None,
        })
        .collect()
}

// ════════════════════════════════════════════════════════════
// Rust field type → protobuf FieldDescriptorProto (best-effort, cosmetic)
// ════════════════════════════════════════════════════════════

/// Build one `DescriptorProto` field entry. Best-effort, like every other
/// reference encoder's field-type mapping (`ball-compiler`'s own inverse,
/// `type_emit::proto_field_rust_type`, falls back to the dynamic
/// `BallValue` for anything it doesn't recognize — the struct's *field
/// names* are the semantically load-bearing part; the declared scalar type
/// is a documentation-level nicety, never consulted for runtime dispatch,
/// since every actual instance stays a dynamic `BallValue::Message`
/// regardless — see `rust/compiler/src/type_emit.rs`'s crate-level doc
/// comment).
fn field_descriptor(name: &str, number: i32, ty: &syn::Type) -> FieldDescriptorProto {
    let (proto_type, repeated) = rust_type_to_proto(ty);
    FieldDescriptorProto {
        name: Some(name.to_string()),
        number: Some(number),
        r#type: proto_type.map(|t| t as i32),
        label: Some(if repeated {
            ProtoLabel::Repeated as i32
        } else {
            ProtoLabel::Optional as i32
        }),
        ..Default::default()
    }
}

/// `(scalar type, is `Vec<...>`)`. `Vec<u8>` is the one exception — it maps
/// to a *singular* `bytes` field, mirroring
/// `type_emit::proto_field_rust_type`'s own `TYPE_BYTES -> "Vec<u8>"` half
/// of this same mapping.
fn rust_type_to_proto(ty: &syn::Type) -> (Option<ProtoType>, bool) {
    let syn::Type::Path(type_path) = ty else {
        return (None, false);
    };
    let Some(segment) = type_path.path.segments.last() else {
        return (None, false);
    };
    let name = segment.ident.to_string();
    if name == "Vec" {
        let inner = angle_bracketed_first_type(segment);
        if inner.is_some_and(is_u8_type) {
            return (Some(ProtoType::Bytes), false);
        }
        let inner_scalar = inner.and_then(|t| rust_type_to_proto(t).0);
        return (inner_scalar, true);
    }
    let scalar = match name.as_str() {
        "i32" => Some(ProtoType::Int32),
        "i64" => Some(ProtoType::Int64),
        "u32" => Some(ProtoType::Uint32),
        "u64" => Some(ProtoType::Uint64),
        "f64" => Some(ProtoType::Double),
        "f32" => Some(ProtoType::Float),
        "bool" => Some(ProtoType::Bool),
        "String" => Some(ProtoType::String),
        _ => None,
    };
    (scalar, false)
}

fn angle_bracketed_first_type(segment: &syn::PathSegment) -> Option<&syn::Type> {
    let syn::PathArguments::AngleBracketed(args) = &segment.arguments else {
        return None;
    };
    args.args.iter().find_map(|arg| match arg {
        syn::GenericArgument::Type(ty) => Some(ty),
        _ => None,
    })
}

fn is_u8_type(ty: &syn::Type) -> bool {
    matches!(ty, syn::Type::Path(type_path) if type_path
        .path
        .segments
        .last()
        .is_some_and(|segment| segment.ident == "u8"))
}
