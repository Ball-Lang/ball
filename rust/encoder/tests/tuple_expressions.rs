//! Rust TUPLE expressions — `(a, b)` and the unit value `()` (issue #767).
//!
//! ## Why this bucket matters
//!
//! `lib.rs::encode_expr` had no `syn::Expr::Tuple` arm at all, so a single
//! tuple anywhere in a file aborted the whole file at the catch-all
//! "unsupported Rust expression kind `tuple`" panic. Measured on the live
//! Tier A funnel (`tools/coverage-study/packages/rust.json`, the same five
//! pins `coverage-study.yml` runs), that is **6 of the 77 scored files**
//! first-blocked on exactly this: `itertools`'
//! `unziptuple.rs`/`zip_eq_impl.rs`/`zip_longest.rs`, `smallvec`'s `borsh.rs`
//! and `heck`'s `lower_camel.rs`/`upper_camel.rs`. It is the largest
//! *implementable* stage-1 bucket issue #767 enumerates.
//!
//! ## The representation, and why it is `"0"`/`"1"` and not `"$1"`/`"$2"`
//!
//! A Rust tuple is a positional record, so it lowers to `std.record` — the
//! universal base function `dart/shared/std.json` declares for exactly that
//! (`dart/encoder/lib/encoder.dart::_encodeRecordLiteral` is the reference
//! emitter). The component NAMES differ from Dart's, deliberately:
//!
//! - `dart/encoder` names a positional component `$1`/`$2` because that is
//!   Dart's own positional getter spelling (`record.$1`), and the C++ compiler
//!   lowers a `.$N` field access as an index (`cpp/compiler/src/compiler.cpp`,
//!   `stoi(substr(1)) - 1`) to match.
//! - This encoder names it `"0"`/`"1"` — Rust's own member spelling — because
//!   the READ side already produces exactly that: `lib.rs::encode_field` turns
//!   a `syn::Member::Unnamed` (`t.0`) into the decimal index, and
//!   `types.rs::encode_item_struct` declares a tuple STRUCT's elements under
//!   the very same names (issue #491's tuple/unit-struct slice, which
//!   `rust/AGENTS.md` records as load-bearing rather than cosmetic).
//!
//! Picking `$1` here would have meant re-spelling the tuple-struct field names
//! too — `p.0` on a tuple struct and `t.0` on a tuple are syntactically
//! indistinguishable, so the read side cannot tell them apart — which is a
//! separate representation decision, not this slice. `"0"`/`"1"` keeps
//! declaration and read in agreement with no translation table, and stays
//! portable: every target treats a component name that is neither `$N` nor
//! `argN` as an opaque key on BOTH the `record` build side and the
//! `field_access` read side (`cpp/compiler/src/compiler.cpp`'s `"record"` arm
//! classifies it as a named component; `dart/engine/lib/engine_std.dart`'s
//! `_stdRecord` hands the field map straight back).
//!
//! `()` is the unit value, and encodes as the Ball NULL literal rather than as
//! an empty record: it is Rust's "no value", the same thing a body-less `fn
//! f() {}` returns, and a zero-component record would compare unequal to the
//! `null` every other absent value in a Ball program already is.
//!
//! ## Why this is a compile-and-run proof, not a shape assertion
//!
//! Three things have to agree for a tuple to survive: the construction
//! (`encode_tuple`), the read (`encode_field`, untouched) and the compiler's
//! `std.record` lowering (`rust/compiler/src/base_call.rs::compile_record`,
//! which compiles the input `message_creation` into a `BallValue::Map`). A
//! shape assertion on the encoder alone would pass even if the compiled
//! program could not read a component back. The expected stdout is
//! hand-computed from the original Rust source, never read off a run.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::{Block, Expression, Literal};

/// Tuple construction, positional reads, a NESTED tuple (so the arm has to
/// recurse) and the unit value — the shapes that used to abort the whole file
/// at `encode_expr`'s catch-all panic.
const TUPLE_SOURCE: &str = r#"
fn main() {
    let p = (3, 4);
    let nested = ((1, 2), 5);
    let u = ();
    println!("{}", p.0 + p.1 + nested.1 + nested.0.1);
    println!("{}", u == ());
}
"#;

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

/// Build and run `rust_src` in a scratch cargo package — the same harness
/// `end_to_end.rs`/`tuple_and_unit_structs.rs` use (unique package/bin name so
/// parallel fixtures never collide; the shared workspace `target/` so the
/// already-built `ball-lang-shared` dependency tree is reused; every artifact
/// cleaned up, including on failure).
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_tuple_expr_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_tuple_expr_fixture_{slug}");
    let manifest = format!(
        "[package]\nname = \"{bin_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"{bin_name}\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-lang-shared = {{ path = {:?} }}\n",
        shared_path
    );
    fs::write(fixture_dir.join("Cargo.toml"), manifest)
        .expect("failed to write fixture Cargo.toml");
    fs::write(fixture_dir.join("main.rs"), rust_src).expect("failed to write fixture main.rs");

    let manifest_path = fixture_dir.join("Cargo.toml");
    let build = Command::new("cargo")
        .args(["build", "--quiet"])
        .arg("--manifest-path")
        .arg(&manifest_path)
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo build` — is cargo on PATH?");

    if !build.status.success() {
        let _ = fs::remove_dir_all(&fixture_dir);
        panic!(
            "fixture '{fixture_name}' failed to COMPILE.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&build.stdout),
            String::from_utf8_lossy(&build.stderr),
        );
    }

    let exe = target_dir.join("debug").join(if cfg!(windows) {
        format!("{bin_name}.exe")
    } else {
        bin_name.clone()
    });
    let output = Command::new(&exe).output().unwrap_or_else(|err| {
        panic!(
            "fixture '{fixture_name}' built but its binary {} could not be run: {err}",
            exe.display()
        )
    });

    let _ = fs::remove_dir_all(&fixture_dir);
    let _ = fs::remove_file(&exe);
    for sidecar in ["d", "pdb"] {
        let _ = fs::remove_file(
            target_dir
                .join("debug")
                .join(format!("{bin_name}.{sidecar}")),
        );
    }

    if !output.status.success() {
        panic!(
            "fixture '{fixture_name}' failed to run.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    String::from_utf8(output.stdout).expect("fixture stdout must be valid UTF-8")
}

#[test]
fn tuple_expressions_encode_and_round_trip() {
    let program = ball_lang_encoder::encode(TUPLE_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("the encoded program must carry `main`");
    let body = main_fn.body.as_ref().expect("`main` must carry a body");
    let Some(Expr::Block(block)) = &body.expr else {
        panic!("`main`'s body is a block");
    };

    // ── `(3, 4)` is a `std.record` whose components are named "0"/"1" ──
    let p = let_value(block, "p");
    assert_eq!(
        record_component_names(p),
        Some(vec!["0".to_string(), "1".to_string()]),
        "a tuple must encode as `std.record` with Rust's own positional member \
         names — the very names `encode_field` produces for a `t.0` read"
    );

    // ── The arm recurses: `((1, 2), 5)`'s first component is a record too ──
    let nested = let_value(block, "nested");
    let nested_components = record_components(nested)
        .expect("a nested tuple's outer value must still be a `std.record`");
    assert_eq!(
        record_component_names(&nested_components[0]),
        Some(vec!["0".to_string(), "1".to_string()]),
        "the inner `(1, 2)` must encode as a record of its own, not be dropped"
    );

    // ── `()` is the NULL literal, never a zero-component record ──
    let u = let_value(block, "u");
    assert!(
        matches!(&u.expr, Some(Expr::Literal(Literal { value: None }))),
        "the unit value `()` must encode as Ball's null literal, got {u:?}"
    );

    // ── The real round trip: it compiles to Rust and prints 14 then true ──
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("tuple_expressions", &compiled);
    let lines: Vec<&str> = stdout.lines().map(str::trim).collect();
    assert_eq!(
        lines,
        vec!["14", "true"],
        "p.0 + p.1 + nested.1 + nested.0.1 == 3 + 4 + 5 + 2 == 14, and `()` equals \
         itself\n--- generated main.rs ---\n{compiled}"
    );
}

/// The `value` of the `let <name> = …;` statement in `block`.
fn let_value<'a>(block: &'a Block, name: &str) -> &'a Expression {
    use ball_lang_shared::proto::ball::v1::statement::Stmt;
    for statement in &block.statements {
        if let Some(Stmt::Let(binding)) = &statement.stmt {
            if binding.name == name {
                return binding
                    .value
                    .as_ref()
                    .unwrap_or_else(|| panic!("`let {name}` must carry a value"));
            }
        }
    }
    panic!("`main` must declare `let {name}`");
}

/// The component EXPRESSIONS of a `std.record` call, or `None` when `expr` is
/// any other node.
fn record_components(expr: &Expression) -> Option<Vec<Expression>> {
    let Some(Expr::Call(call)) = &expr.expr else {
        return None;
    };
    if call.module != "std" || call.function != "record" {
        return None;
    }
    let Some(Expr::MessageCreation(mc)) = call.input.as_ref().and_then(|i| i.expr.as_ref()) else {
        return None;
    };
    Some(
        mc.fields
            .iter()
            .map(|f| f.value.clone().expect("a record component carries a value"))
            .collect(),
    )
}

/// The component NAMES of a `std.record` call, or `None` when `expr` is any
/// other node.
fn record_component_names(expr: &Expression) -> Option<Vec<String>> {
    let Some(Expr::Call(call)) = &expr.expr else {
        return None;
    };
    if call.module != "std" || call.function != "record" {
        return None;
    }
    let Some(Expr::MessageCreation(mc)) = call.input.as_ref().and_then(|i| i.expr.as_ref()) else {
        return None;
    };
    Some(mc.fields.iter().map(|f| f.name.clone()).collect())
}
