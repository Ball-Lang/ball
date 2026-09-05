//! Tuple structs (`struct Pair(i64, i64);`) and unit structs
//! (`struct Marker;`) — issue #491.
//!
//! ## Why this bucket matters
//!
//! `rust/encoder/src/types.rs::encode_item_struct` used to `panic!` the
//! instant `item.fields` was anything but `syn::Fields::Named` — so a single
//! newtype wrapper killed the whole file even when every other declaration in
//! it encoded perfectly. That is 14 of the 110 scored files in the live Tier A
//! funnel (`tools/coverage-study/packages/rust.json` pin set), the largest
//! *declaration-shape* bucket: `heck`'s six case-conversion files, `itertools`'
//! `intersperse.rs`/`merge_join.rs`/`multi_product.rs`/`all_equal_value_err.rs`,
//! `smallvec`'s `rayon.rs`/`taggedlen.rs`, and more.
//!
//! ## Why this is a compile-and-run proof, not a shape assertion
//!
//! Three separate call sites have to agree for a tuple struct to survive the
//! round trip — the *declaration* (`types.rs::encode_item_struct`), the
//! *construction* (`lib.rs::encode_call`, since `Pair(1, 2)` is syntactically
//! indistinguishable from a same-file function call) and the *read*
//! (`lib.rs::encode_field`, already correct before this slice). Getting only
//! the first one right is exactly the failure mode that produces a
//! structurally-valid program that then fails to build, so the assertion that
//! matters is that a real Rust file travels encoder -> compiler ->
//! `cargo build` -> execution and prints the right number. The expected stdout
//! is hand-computed from the semantics of the original Rust source
//! (`Pair(3, 4)`, `p.0 + p.1 == 7`), not read off a run.
//!
//! ## Deliberately avoided here
//!
//! Destructuring a tuple struct (`let Pair(a, b) = p;`, or a
//! `fn f(Pair(a, b): Pair)` parameter) is a *separate*, pre-existing
//! documented gap (`lib.rs`'s destructuring-pattern panic, 4 more first-blocked
//! Tier A files) that this slice does not close — so the fixtures read fields
//! positionally (`p.0`), the same way `static_methods.rs`/`mixed_impl_items.rs`
//! each steered around their own adjacent gaps.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;

/// A tuple struct built positionally and read positionally, plus a unit
/// struct bound as a bare value — the two shapes that used to abort the
/// whole file at `types.rs`'s unconditional `Fields::Named` panic.
const TUPLE_AND_UNIT_SOURCE: &str = r#"
struct Pair(i64, i64);

struct Marker;

fn main() {
    let p = Pair(3, 4);
    let _m = Marker;
    println!("{}", p.0 + p.1);
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
/// `end_to_end.rs`/`static_methods.rs`/`mixed_impl_items.rs` use (unique
/// package/bin name so parallel fixtures never collide; the shared workspace
/// `target/` so the already-built `ball-lang-shared` dependency tree is
/// reused; every artifact cleaned up, including on failure).
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir =
        std::env::temp_dir().join(format!("ball_encoder_tuple_struct_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_tuple_struct_fixture_{slug}");
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
fn tuple_and_unit_structs_encode_and_round_trip() {
    let program = ball_lang_encoder::encode(TUPLE_AND_UNIT_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");

    // ── The tuple struct declares its elements under NUMERIC names ──
    //
    // `"0"`/`"1"`, not `"field0"`/`"arg0"` — the convention
    // `types.rs::member_name` has always used for a `syn::Member::Unnamed`
    // field *read* (`p.0`), so declaration and read agree without either side
    // needing a translation table.
    let pair = main_module
        .type_defs
        .iter()
        .find(|t| t.name == "main:Pair")
        .expect("the tuple struct must encode as a TypeDefinition");
    let pair_fields: Vec<&str> = pair
        .descriptor
        .as_ref()
        .expect("a struct TypeDefinition always carries a descriptor")
        .field
        .iter()
        .map(|f| f.name())
        .collect();
    assert_eq!(
        pair_fields,
        vec!["0", "1"],
        "a tuple struct's elements must be declared under their positional index"
    );

    // ── The unit struct declares zero fields, not zero declaration ──
    let marker = main_module
        .type_defs
        .iter()
        .find(|t| t.name == "main:Marker")
        .expect("the unit struct must encode as a TypeDefinition");
    assert!(
        marker
            .descriptor
            .as_ref()
            .expect("a struct TypeDefinition always carries a descriptor")
            .field
            .is_empty(),
        "a unit struct declares no fields"
    );

    // ── `Pair(3, 4)` is a CONSTRUCTION, never a call to a function `Pair` ──
    //
    // The failure mode this guards is the silent one: a bare-identifier call
    // target is syntactically identical to a same-file function call, so
    // without the tuple-struct interception `Pair(3, 4)` would encode as a
    // `FunctionCall` naming a function that does not exist anywhere.
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("the encoded program must carry `main`");
    let body = main_fn.body.as_ref().expect("`main` must carry a body");
    let Some(Expr::Block(block)) = &body.expr else {
        panic!("`main`'s body is a block");
    };
    // Only this file's own declared types — `println!` wraps its argument in
    // its own `PrintInput` message, which is not what this assertion is about.
    let creations: Vec<String> = count_message_creations(&block.statements)
        .into_iter()
        .filter(|type_name| type_name.starts_with("main:"))
        .collect();
    assert_eq!(
        creations,
        vec!["main:Pair".to_string(), "main:Marker".to_string()],
        "`Pair(3, 4)` and the bare value `Marker` must both encode as \
         message_creation, never as a call/reference to a nonexistent name"
    );

    // ── The real round trip: it compiles to Rust and prints 7 ──
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("tuple_and_unit_structs", &compiled);
    assert_eq!(
        stdout.trim(),
        "7",
        "Pair(3, 4).0 + .1 == 7\n--- generated main.rs ---\n{compiled}"
    );
}

/// Every `message_creation` type name reachable from these statements, in
/// encounter order (deep enough for the `let x = <expr>;` shape the fixture
/// uses — a `LetBinding` whose `value` carries the constructed instance).
fn count_message_creations(
    statements: &[ball_lang_shared::proto::ball::v1::Statement],
) -> Vec<String> {
    use ball_lang_shared::proto::ball::v1::statement::Stmt;
    let mut found = Vec::new();
    for statement in statements {
        match &statement.stmt {
            Some(Stmt::Let(binding)) => {
                if let Some(value) = &binding.value {
                    walk(value, &mut found);
                }
            }
            Some(Stmt::Expression(expression)) => walk(expression, &mut found),
            None => {}
        }
    }
    found
}

fn walk(expression: &ball_lang_shared::proto::ball::v1::Expression, found: &mut Vec<String>) {
    match &expression.expr {
        Some(Expr::MessageCreation(mc)) => {
            if !mc.type_name.is_empty() {
                found.push(mc.type_name.clone());
            }
            for field in &mc.fields {
                if let Some(value) = &field.value {
                    walk(value, found);
                }
            }
        }
        Some(Expr::Call(call)) => {
            if let Some(input) = &call.input {
                walk(input, found);
            }
        }
        Some(Expr::Block(block)) => {
            found.extend(count_message_creations(&block.statements));
        }
        Some(Expr::FieldAccess(field_access)) => {
            if let Some(object) = &field_access.object {
                walk(object, found);
            }
        }
        _ => {}
    }
}

/// A tuple struct used as a **newtype wrapper** — the single most common
/// real-world shape in the Tier A pin set (`heck`'s `AsKebabCase<T>(pub T)`,
/// `smallvec`'s `TaggedLen(usize)`). One element, read back as `.0`.
#[test]
fn newtype_tuple_struct_round_trips() {
    let program = ball_lang_encoder::encode(
        "struct Wrapper(i64);\n\
         fn main() { let w = Wrapper(41); println!(\"{}\", w.0 + 1); }",
    );
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("newtype_tuple_struct", &compiled);
    assert_eq!(
        stdout.trim(),
        "42",
        "Wrapper(41).0 + 1 == 42\n--- generated main.rs ---\n{compiled}"
    );
}
