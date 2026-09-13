//! `macro_rules!` expansion in the Rust encoder (issue #629).
//!
//! ## What this file is for
//!
//! `rust/encoder/src/lib.rs` refuses an item-level macro **loudly** — a macro
//! at item position can be the very thing that DEFINES a type the rest of the
//! file calls into, so skipping it would orphan those references into a
//! downstream panic naming a type that looks like it should exist. Closing
//! that needs real expansion, not a per-macro desugaring, and #629's owner
//! decision (2026-09-14) is to do it the way rust-analyzer does: its own
//! macro-by-example engine, quarantined behind the `ball-lang-macro-expand`
//! crate.
//!
//! Every fixture-based test here runs against `tests/fixtures/macro_crate` — a
//! real, hermetic two-crate fixture whose crate root invokes a LOCAL
//! `macro_rules!` at item position and whose `flags` module invokes a
//! DEPENDENCY-defined, `#[macro_export]`ed one reached through `cargo
//! metadata`. Nothing in the encoder knows the name `bitflags` (or
//! `mini_bitflags`); the fixture is a stand-in for the general mechanism, never
//! a special case.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::{Module, Program};

use ball_lang_encoder::{encode, encode_crate, encode_library};

/// Makes every scratch directory this file creates unique, so the test harness
/// can keep running them in parallel.
static SCRATCH_COUNTER: AtomicU64 = AtomicU64::new(0);

/// `rust/encoder/tests/fixtures/macro_crate` — the crate root directory, the
/// spelling `encode_crate` documents as its entry point.
fn macro_crate_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/macro_crate")
}

fn read_fixture(relative: &str) -> String {
    let path = macro_crate_dir().join(relative);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read fixture {}: {err}", path.display()))
}

fn module<'a>(program: &'a Program, name: &str) -> &'a Module {
    program
        .modules
        .iter()
        .find(|m| m.name == name)
        .unwrap_or_else(|| {
            panic!(
                "no module `{name}` in the encoded program (modules: {:?})",
                program.modules.iter().map(|m| &m.name).collect::<Vec<_>>()
            )
        })
}

/// Declared type names, with the `main:` module qualifier `types.rs`'s
/// `qualified_type_name` adds stripped back off.
fn type_names(module: &Module) -> Vec<String> {
    module
        .type_defs
        .iter()
        .map(|def| def.name.rsplit(':').next().unwrap_or(&def.name).to_owned())
        .collect()
}

/// A struct's declared FIELDS, read off its protobuf descriptor.
fn field_names(module: &Module, type_name: &str) -> Vec<String> {
    module
        .type_defs
        .iter()
        .find(|def| def.name.ends_with(type_name))
        .unwrap_or_else(|| {
            panic!(
                "no type `{type_name}` in module `{}` (types: {:?})",
                module.name,
                type_names(module)
            )
        })
        .descriptor
        .as_ref()
        .unwrap_or_else(|| panic!("type `{type_name}` has no descriptor"))
        .field
        .iter()
        .map(|field| field.name.clone().unwrap_or_default())
        .collect()
}

/// Every function the module declares, by name (a method is
/// `<qualified type>.<method>`).
fn function_names(module: &Module) -> Vec<String> {
    module.functions.iter().map(|f| f.name.clone()).collect()
}

// ════════════════════════════════════════════════════════════
// rustc/cargo execution harness (mirrors crate_encoding.rs's)
// ════════════════════════════════════════════════════════════

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

/// Build `rust_src` as a one-file cargo package against the workspace's own
/// `ball-lang-shared`, run it, and return its stdout AS BYTES.
///
/// Bytes, not a `String`: the golden comparison must not go through a text
/// decode that could normalise a line ending. The package/bin name carries a
/// pid + counter suffix because every fixture in this workspace shares one
/// `target/` and the harness runs them in parallel — see `end_to_end.rs`'s own
/// note on why a constant bin name raced.
fn compile_and_run(fixture_name: &str, rust_src: &str) -> Vec<u8> {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = SCRATCH_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_macro_rustc_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_macro_fixture_{slug}");
    let manifest = format!(
        "[package]\nname = \"{bin_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"{bin_name}\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-lang-shared = {{ path = {shared_path:?} }}\n"
    );
    fs::write(fixture_dir.join("Cargo.toml"), manifest)
        .expect("failed to write fixture Cargo.toml");
    fs::write(fixture_dir.join("main.rs"), rust_src).expect("failed to write fixture main.rs");

    let build = Command::new("cargo")
        .args(["build", "--quiet"])
        .arg("--manifest-path")
        .arg(fixture_dir.join("Cargo.toml"))
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo build` — is cargo on PATH?");
    if !build.status.success() {
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
    output.stdout
}

// ── The closed gap: a local item-level `macro_rules!` ────────────────────────

/// **CLOSED** by #629. Both halves used to be refused: `macro_rules! make_one
/// { … }` is itself a `syn::Item::Macro`, so the DEFINITION landed on the same
/// panic as the invocation. Expansion removes definitions from the item list
/// and replaces invocations with what they produce.
#[test]
fn a_local_item_level_macro_expands_into_real_declarations() {
    let program = encode(
        "macro_rules! make_one { ($f:ident) => { struct One { $f: i64 } }; }\n\
         make_one!(v);\n\
         fn main() { let o = One { v: 1 }; println!(\"{}\", o.v); }",
    );
    let main = module(&program, "main");
    assert_eq!(type_names(main), vec!["One".to_string()]);
    assert_eq!(field_names(main, "One"), vec!["v".to_string()]);
}

/// A definition is removed from the item list rather than left to reach the
/// unsupported-item panic — and a file that is NOTHING BUT a definition still
/// encodes.
#[test]
fn a_macro_rules_definition_alone_leaves_no_declaration_behind() {
    let program = encode_library("macro_rules! unused { () => { struct Never; }; }");
    let main = module(&program, "main");
    assert!(
        main.type_defs.is_empty() && main.functions.is_empty(),
        "a definition declares nothing Ball models: {main:?}"
    );
}

// ── The driver: fixed point, depth limit, nesting ────────────────────────────

/// Expansion must run to a FIXED POINT. One pass leaves an invocation a
/// transcriber produced still in place — `ball-lang-macro-expand`'s
/// `a_self_recursive_macro_is_not_fully_expanded_in_one_pass` pins that at the
/// engine level; this is the driver's half.
#[test]
fn expansion_runs_to_a_fixed_point() {
    let program = encode_library(
        "macro_rules! inner { ($n:ident) => { struct $n { a: i64 } }; }\n\
         macro_rules! outer { () => { inner!(Made); }; }\n\
         outer!();",
    );
    assert_eq!(
        type_names(module(&program, "main")),
        vec!["Made".to_string()]
    );
}

/// rustc's own default `recursion_limit` is 128 (the Rust Reference, *Limits*).
/// A macro that never stops expanding must hit that limit loudly, naming the
/// chain — never a partial expansion, and never a hang.
#[test]
#[should_panic(expected = "exceeded the recursion limit of 128")]
fn runaway_recursion_hits_the_depth_limit() {
    encode_library("macro_rules! forever { () => { forever!(); }; }\nforever!();");
}

/// 21 of `bitflags`' definitions live inside inline `mod` blocks, so the
/// collector has to descend into them.
#[test]
fn a_macro_defined_inside_an_inline_mod_is_in_scope_for_the_file() {
    let program = encode_library(
        "mod internal { macro_rules! shared { ($n:ident) => { struct $n { a: i64 } }; } }\n\
         shared!(FromInside);",
    );
    assert_eq!(
        type_names(module(&program, "main")),
        vec!["FromInside".to_string()]
    );
}

/// A macro invoked inside an `impl` block expands into impl items — the shape
/// `bitflags`' internal `__impl_public_bitflags*!` family has.
#[test]
fn a_macro_invoked_inside_an_impl_block_expands_into_methods() {
    let program = encode_library(
        "struct Holder { a: i64 }\n\
         macro_rules! accessors { () => { fn get(&self) -> i64 { self.a } }; }\n\
         impl Holder { accessors!(); }",
    );
    let main = module(&program, "main");
    assert_eq!(field_names(main, "Holder"), vec!["a".to_string()]);
    assert!(
        function_names(main)
            .iter()
            .any(|n| n.ends_with("Holder.get")),
        "the macro-produced method must be declared: {:?}",
        function_names(main)
    );
}

/// Statement position, for a locally defined macro.
#[test]
fn a_statement_position_local_macro_expands() {
    let program = encode(
        "macro_rules! shout { ($v:expr) => { println!(\"{}\", $v); }; }\n\
         fn main() { shout!(7); }",
    );
    let main = module(&program, "main");
    let body = main
        .functions
        .iter()
        .find(|f| f.name == "main")
        .and_then(|f| f.body.as_ref())
        .expect("`main` must have a body");
    let rendered = format!("{body:?}");
    assert!(
        rendered.contains("print"),
        "the expanded `println!` must have been lowered by the encoder: {rendered}"
    );
}

// ── What stays loud ──────────────────────────────────────────────────────────

/// A name no `macro_rules!` in scope defines — every proc-macro, `#[derive]`
/// helper and attribute macro — keeps the encoder's own loud refusal. That
/// boundary is deliberate: this crate expands DECLARATIVE macros and nothing
/// else.
#[test]
#[should_panic(expected = "unsupported top-level item")]
fn a_proc_macro_style_item_invocation_is_still_loud() {
    encode("some_derive_helper!();\nfn main() { println!(\"{}\", 1); }");
}

/// Statement position, for a name nothing defines: routed to the encoder's own
/// `encode_macro`, which is what keeps the builtin-macro gap (issue #630)
/// separately trackable.
#[test]
#[should_panic(expected = "unsupported macro invocation")]
fn an_unresolvable_statement_position_macro_is_loud() {
    encode("fn main() { shout!(1); }");
}

/// A DEPENDENCY-defined macro reached from a SINGLE-FILE encode is a named
/// failure, not a generic "unsupported item": there is no manifest to resolve
/// the dependency against, and saying so is the actionable diagnostic.
#[test]
#[should_panic(expected = "no crate manifest to resolve dependencies against")]
fn a_dependency_macro_in_single_file_mode_names_the_missing_manifest() {
    encode_library(&read_fixture("src/flags.rs"));
}

/// A crate whose root has no `Cargo.toml` above it — which is exactly what the
/// Tier A coverage harness points at, since it names `<pkg>/src` rather than
/// `<pkg>` — cannot have a dependency graph read for it. That is recorded and
/// raised at the first invocation that needs one, naming the missing manifest;
/// it is never a silent skip, and it never stops the rest of the crate being
/// measured.
#[test]
#[should_panic(expected = "no `Cargo.toml` was found at or above")]
fn a_crate_with_no_manifest_names_the_missing_cargo_toml() {
    let scratch = std::env::temp_dir().join(format!(
        "ball_macro_no_manifest_{}_{}",
        std::process::id(),
        SCRATCH_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let src = scratch.join("src");
    std::fs::create_dir_all(&src).expect("scratch dir");
    for name in ["main.rs", "flags.rs"] {
        std::fs::write(src.join(name), read_fixture(&format!("src/{name}")))
            .expect("copy fixture source");
    }
    // NOT copied: Cargo.toml. `encode_crate` on the `src` directory is a
    // documented entry point, so the walk succeeds and only the dependency
    // macro fails.
    let result = std::panic::catch_unwind(|| encode_crate(&scratch));
    let _ = std::fs::remove_dir_all(&scratch);
    match result {
        Ok(_) => panic!("a dependency macro with no manifest must not silently resolve"),
        Err(payload) => std::panic::resume_unwind(payload),
    }
}

// ── The dependency-defined macro, end to end ─────────────────────────────────

/// The whole fixture crate: a LOCAL `macro_rules!` at item position in the
/// crate root, and a DEPENDENCY-defined `#[macro_export]`ed one in `flags.rs`
/// reached by a two-segment path and resolved through `cargo metadata`.
///
/// Nothing in the encoder knows the name `mini_bitflags` (or `bitflags`) — the
/// resolution is by path segment against the package the dependency graph
/// names, so this is the general mechanism, exercised.
#[test]
fn the_macro_crate_fixture_expands_both_its_local_and_dependency_macros() {
    let program = encode_crate(&macro_crate_dir());

    let main = module(&program, "main");
    assert_eq!(type_names(main), vec!["Point".to_string()]);
    assert_eq!(
        field_names(main, "Point"),
        vec!["x".to_string(), "y".to_string()],
        "the local `make_point!`'s repetition must declare BOTH fields"
    );
    assert!(
        function_names(main)
            .iter()
            .any(|n| n.ends_with("Point.total")),
        "{:?}",
        function_names(main)
    );

    let flags = module(&program, "flags");
    assert_eq!(type_names(flags), vec!["Perms".to_string()]);
    assert_eq!(field_names(flags, "Perms"), vec!["bits".to_string()]);
    let flag_fns = function_names(flags);
    for method in ["Perms.read_bit", "Perms.write_bit", "Perms.sum_bits"] {
        assert!(
            flag_fns.iter().any(|n| n.ends_with(method)),
            "the dependency macro's `{method}` must be declared: {flag_fns:?}"
        );
    }
}

// ── The round trip: encode -> compile -> BUILD -> RUN -> diff bytes ──────────

/// The proof that matters. A structural assertion about a `TypeDefinition`
/// would pass just as well against a program that does not link, and a hygiene
/// approximation can produce a tree that round-trips syntactically clean and
/// computes something different — the #488 class, which Tier A is structural
/// and cannot see. So this encodes the fixture crate, compiles the Ball program
/// back to Rust with `ball-lang-compiler`, builds it with cargo, RUNS it, and
/// diffs stdout against the committed golden **as bytes**.
///
/// Bytes, not text: reading a golden as text collapses a semantic lone `\r` and
/// corrupts the comparison in both directions. Only `\r\n` -> `\n` is
/// normalised, because the two checkouts differ in line endings and nothing
/// else.
#[test]
fn the_macro_crate_fixture_round_trips_through_the_compiler() {
    let program = encode_crate(&macro_crate_dir());
    assert_eq!(
        program.entry_function, "main",
        "the fixture's crate root declares `fn main`, so the encoded program is runnable"
    );
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("macro_crate", &compiled);

    let golden = std::fs::read(macro_crate_dir().join("expected_stdout.txt"))
        .expect("the fixture golden must exist");
    assert_eq!(
        normalise_newlines(&stdout),
        normalise_newlines(&golden),
        "the compiled-back crate's stdout must match the fixture's own \
         `cargo run` output byte for byte.\n--- generated main.rs ---\n{compiled}"
    );
}

/// `\r\n` -> `\n`, and nothing else. A lone `\r` is left exactly as it is.
fn normalise_newlines(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\r' && bytes.get(index + 1) == Some(&b'\n') {
            index += 1;
            continue;
        }
        out.push(bytes[index]);
        index += 1;
    }
    out
}

// ── The fixture's golden ─────────────────────────────────────────────────────

/// The golden the round-trip diffs against, and the value an ordinary `cargo
/// run` of the fixture produces (verified: `42\n7\n`). Pinned so the golden
/// cannot drift silently ahead of the fixture.
#[test]
fn the_fixture_golden_matches_the_hand_computed_values() {
    // Point { x: 20, y: 22 }.total() == 0 + 20 + 22, and
    // Perms { bits: 4 }.sum_bits() == 4 + 1 + 2.
    let golden = std::fs::read(macro_crate_dir().join("expected_stdout.txt"))
        .expect("the fixture golden must exist");
    let golden = String::from_utf8(golden).expect("the golden must be UTF-8");
    assert_eq!(golden.replace("\r\n", "\n"), "42\n7\n");
}
