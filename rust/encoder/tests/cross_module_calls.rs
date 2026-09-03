//! Cross-file / cross-module call targets (issue #491, slice 3): a call whose
//! callee is not declared in the file being encoded — 15 of 196 files in
//! #491's study, per that issue's `unsupported call target (only same-file
//! functions)` row.
//!
//! ## The design decision this pins
//!
//! Before this slice, `lib.rs::encode_call` **panicked** on any path call it
//! could not resolve to a same-file function. That is a loud, honest failure,
//! but it makes the encoder unusable for any multi-file crate. The convention
//! adopted here — and shared verbatim with the Go encoder
//! (`go/encoder/encoder.go`'s unconditional `ModuleImport{Name: name}`) — is
//! to emit an **unresolved `ModuleImport`** (`source: None`) naming the
//! callee's leading path segment, and target the call at
//! `FunctionCall{module: <alias>, function: <last segment>}`.
//!
//! ## The verified contract of an unresolved import (not assumed — measured)
//!
//! A `ModuleImport` with no `source` is the proto's own "reference only"
//! shape, and the reference (Dart) tooling treats it as *structurally legal,
//! deliberately unresolved*, not as an error:
//! - `dart/shared/lib/cli_core.dart`'s `validationErrors` (the self-hosted
//!   `ball validate`) never inspects `module_imports` at all, and its
//!   `treeReport`/`_importSource` renders exactly this shape as `ref only`.
//! - `dart/cli/lib/src/runner.dart`'s `ball build` counts an import as
//!   "unresolved, needs the resolver" only when `whichSource() !=
//!   ModuleImport_Source.notSet` — a source-less import is left alone.
//! - `rust/cli/src/commands/check.rs`'s `validate_structure` mirrors that: it
//!   checks entry points, module names and bodiless non-base functions, never
//!   imports.
//!
//! So the honest statement — asserted below rather than assumed — is: the
//! encoded `Program` is **structurally valid** and `ball check` accepts it,
//! and it is **deliberately not runnable** until the referenced module is
//! supplied, the same boundary library mode established for an empty
//! `entry_function` (`library_mode.rs`'s "Deliberately non-runnable"). The
//! CLI-level half of this contract is pinned end to end by
//! `rust/cli/tests/cli_check.rs::encoded_cross_file_call_is_structurally_valid_but_unresolved`.
use ball_lang_shared::proto::ball::v1::expression::Expr;

const CROSS_FILE_SOURCE: &str = r#"
fn main() {
    println!("{}", other_file::helper(1));
}
"#;

/// Two arguments, so the positional packing convention is actually exercised
/// (a 1-argument call passes its argument bare and could not distinguish
/// positional from named packing).
const CROSS_FILE_MULTI_ARG_SOURCE: &str = r#"
fn main() {
    println!("{}", other_file::combine(1, 2));
}
"#;

#[test]
fn cross_file_call_target_encodes_as_unresolved_import() {
    let program = ball_lang_encoder::encode(CROSS_FILE_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");

    // ── The import: named, and genuinely unresolved ──
    let import = main_module
        .module_imports
        .iter()
        .find(|i| i.name == "other_file")
        .expect("a cross-file call must register a ModuleImport for its leading path segment");
    assert!(
        import.source.is_none(),
        "the import is deliberately UNRESOLVED — a syntax-only encoder has no way to \
         locate `other_file`'s Ball module, so it leaves the source unset (`ref only`) \
         for a resolver/engine to supply or report later"
    );
    assert_eq!(
        main_module
            .module_imports
            .iter()
            .filter(|i| i.name == "other_file")
            .count(),
        1,
        "repeated calls into the same module register exactly one import"
    );
    // The pre-existing `std` import is untouched.
    assert!(
        main_module.module_imports.iter().any(|i| i.name == "std"),
        "`std` must still be imported"
    );

    // ── The call: module-qualified, positional args ──
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("`fn main` must encode");
    let call = find_call(
        main_fn.body.as_ref().expect("`main` has a body"),
        "other_file",
        "helper",
    )
    .expect("the cross-file call must target module `other_file`, function `helper`");
    assert!(
        call.input.is_some(),
        "a 1-argument cross-file call passes its argument directly as the input"
    );

    // ── `std` accumulation must not pick the unresolved module up ──
    assert!(
        !program.modules.iter().any(|m| m.name == "other_file"),
        "an unresolved import must NOT be synthesised as a base module — that would \
         silently paper over the missing module"
    );
}

#[test]
fn cross_file_call_packs_multiple_arguments_positionally() {
    let program = ball_lang_encoder::encode(CROSS_FILE_MULTI_ARG_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("`fn main` must encode");
    let call = find_call(
        main_fn.body.as_ref().expect("`main` has a body"),
        "other_file",
        "combine",
    )
    .expect("the cross-file call must target module `other_file`, function `combine`");

    let Some(Expr::MessageCreation(input)) = call.input.as_ref().and_then(|i| i.expr.as_ref())
    else {
        panic!("a 2-argument call packs its arguments into a message_creation");
    };
    assert_eq!(
        input
            .fields
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>(),
        vec!["arg0", "arg1"],
        "an EXTERNAL callee's real parameter names are unknown to a single-file encoder, \
         so its arguments are packed positionally — never guessed"
    );
}

/// The fallback is scoped to MODULE-qualified paths, and Rust's own naming
/// convention is the discriminator. An associated function on a **foreign
/// type** is not a missing module — no `ModuleImport` could ever supply it —
/// so it must keep failing loud rather than degrading into an unresolved
/// import nothing can resolve. `Vec::new()` is the common shape this protects.
#[test]
#[should_panic(expected = "unsupported call target")]
fn foreign_type_associated_fn_is_still_a_loud_gap() {
    let _ = ball_lang_encoder::encode("fn main() { let v = Vec::new(); }");
}

/// The same guard for a foreign type reached through a longer module path
/// (`std::vec::Vec::new()`): the segment that decides is the one immediately
/// OWNING the function (`Vec`), so a `snake_case` LEADING segment must not
/// smuggle a foreign associated function through.
#[test]
#[should_panic(expected = "unsupported call target")]
fn foreign_type_associated_fn_through_a_module_path_is_still_a_loud_gap() {
    let _ = ball_lang_encoder::encode("fn main() { let v = std::vec::Vec::new(); }");
}

/// The positive counterpart of the two guards above: a genuinely
/// module-qualified call several segments deep still resolves to an
/// unresolved import named by its full leading path.
#[test]
fn a_deeper_module_path_encodes_under_its_full_alias() {
    let program = ball_lang_encoder::encode("fn main() { println!(\"{}\", util::math::two()); }");
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");
    assert!(
        main_module
            .module_imports
            .iter()
            .any(|i| i.name == "util::math" && i.source.is_none()),
        "the leading segments join into the import alias: {:?}",
        main_module
            .module_imports
            .iter()
            .map(|i| i.name.as_str())
            .collect::<Vec<_>>()
    );
}

/// Depth-first search for the first `call` node matching `(module, function)`.
fn find_call<'a>(
    expr: &'a ball_lang_shared::proto::ball::v1::Expression,
    module: &str,
    function: &str,
) -> Option<&'a ball_lang_shared::proto::ball::v1::FunctionCall> {
    use ball_lang_shared::proto::ball::v1::statement::Stmt;

    match expr.expr.as_ref()? {
        Expr::Call(call) => {
            if call.module == module && call.function == function {
                return Some(call);
            }
            call.input
                .as_ref()
                .and_then(|i| find_call(i, module, function))
        }
        Expr::MessageCreation(message) => message
            .fields
            .iter()
            .filter_map(|f| f.value.as_ref())
            .find_map(|v| find_call(v, module, function)),
        Expr::Block(block) => block
            .statements
            .iter()
            .find_map(|s| match s.stmt.as_ref() {
                Some(Stmt::Let(binding)) => binding
                    .value
                    .as_ref()
                    .and_then(|v| find_call(v, module, function)),
                Some(Stmt::Expression(inner)) => find_call(inner, module, function),
                None => None,
            })
            .or_else(|| {
                block
                    .result
                    .as_ref()
                    .and_then(|r| find_call(r, module, function))
            }),
        Expr::FieldAccess(field_access) => field_access
            .object
            .as_ref()
            .and_then(|o| find_call(o, module, function)),
        Expr::Lambda(lambda) => lambda
            .body
            .as_ref()
            .and_then(|b| find_call(b, module, function)),
        Expr::Literal(_) | Expr::Reference(_) => None,
    }
}
