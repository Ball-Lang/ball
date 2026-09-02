//! `ball encode` integration tests (issue #41).
mod common;

use common::{ball, exit_code, stderr, stdout, write_scratch_file};

#[test]
fn missing_file_exits_3() {
    let output = ball(&["encode", "does/not/exist.rs"]);
    assert_eq!(exit_code(&output), 3, "stderr: {}", stderr(&output));
}

#[test]
fn encodes_a_minimal_program_to_ball_type_enveloped_json_by_default() {
    let path = write_scratch_file(
        "encode_minimal_json",
        "source.rs",
        "fn main() { println!(\"hi from ball-lang-cli\"); }",
    );

    let output = ball(&["encode", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    let json = stdout(&output);
    assert!(json.contains("\"@type\": \"type.googleapis.com/ball.v1.Program\""));
    assert!(json.contains("hi from ball-lang-cli"));

    let parsed: serde_json::Value = serde_json::from_str(&json).expect("must be valid JSON");
    assert_eq!(parsed["entryModule"], "main");
    assert_eq!(parsed["entryFunction"], "main");
}

#[test]
fn encodes_to_binary_format() {
    let path = write_scratch_file(
        "encode_binary",
        "source.rs",
        "fn main() { println!(\"binary round trip\"); }",
    );

    let output = ball(&["encode", path.to_str().unwrap(), "--format", "binary"]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    assert!(!output.stdout.is_empty());
    // Binary protobuf is not itself parseable as the JSON envelope `encode`
    // emits by default — a cheap sanity check that `--format binary` really
    // took a different code path.
    assert!(serde_json::from_slice::<serde_json::Value>(&output.stdout).is_err());
}

/// The **default** (no `--lib`) contract: source without a `fn main()` is
/// rejected. Since issue #491's library-mode slice this is opt-out — see
/// [`encode_lib_flag_allows_missing_main`] for the `ball encode --lib` path
/// that deliberately accepts exactly this source.
#[test]
fn missing_fn_main_exits_2() {
    let path = write_scratch_file("encode_no_main", "source.rs", "fn not_main() {}");

    let output = ball(&["encode", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 2, "stderr: {}", stderr(&output));
    assert!(stderr(&output).contains("fn main"));
}

#[test]
fn unparsable_rust_source_exits_2() {
    let path = write_scratch_file(
        "encode_bad_syntax",
        "source.rs",
        "fn main( { not valid rust @#$",
    );

    let output = ball(&["encode", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 2, "stderr: {}", stderr(&output));
}

#[test]
fn encode_writes_to_an_output_file_instead_of_stdout() {
    let path = write_scratch_file(
        "encode_output_file",
        "source.rs",
        "fn main() { println!(\"to a file\"); }",
    );
    let out_path = path.parent().unwrap().join("out.ball.json");

    let output = ball(&[
        "encode",
        path.to_str().unwrap(),
        "--output",
        out_path.to_str().unwrap(),
    ]);
    let written = std::fs::read_to_string(&out_path).unwrap_or_default();
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    assert!(stdout(&output).is_empty(), "--output must suppress stdout");
    assert!(written.contains("to a file"));
}

/// A library-shaped Rust file: no `fn main()`, one `pub` and one private
/// top-level function. `ball encode` rejects it by default (see
/// [`missing_fn_main_exits_2`]); `--lib` is the opt-out (issue #491).
const LIBRARY_SOURCE: &str =
    "pub fn double(n: i64) -> i64 { n * 2 }\nfn triple(n: i64) -> i64 { n * 3 }\n";

#[test]
fn encode_lib_flag_allows_missing_main() {
    let path = write_scratch_file("encode_lib_flag", "source.rs", LIBRARY_SOURCE);

    let output = ball(&["encode", "--lib", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    let json = stdout(&output);
    assert!(json.contains("\"@type\": \"type.googleapis.com/ball.v1.Program\""));

    let parsed: serde_json::Value = serde_json::from_str(&json).expect("must be valid JSON");
    // `entryModule` still names the module `compile_library` inlines at the
    // crate root; `entryFunction` is deliberately empty (proto3 JSON omits an
    // empty string entirely), so the program is non-runnable by design.
    assert_eq!(parsed["entryModule"], "main");
    assert!(
        parsed.get("entryFunction").map(|v| v == "").unwrap_or(true),
        "library mode must leave entryFunction empty, got {:?}",
        parsed.get("entryFunction")
    );

    let modules = parsed["modules"]
        .as_array()
        .expect("modules must be an array");
    let main_module = modules
        .iter()
        .find(|m| m["name"] == "main")
        .expect("the encoded program must contain the `main` module");
    let functions = main_module["functions"]
        .as_array()
        .expect("functions must be an array");
    let fn_names: Vec<&str> = functions
        .iter()
        .map(|f| f["name"].as_str().expect("a function name"))
        .collect();
    assert_eq!(fn_names, ["double", "triple"]);

    let double = functions
        .iter()
        .find(|f| f["name"] == "double")
        .expect("`double` must be encoded");
    assert_eq!(
        double["metadata"]["is_public"], true,
        "a `pub fn` must round-trip metadata.is_public"
    );
}

#[test]
fn a_library_mode_program_is_rejected_by_check_as_non_runnable() {
    let path = write_scratch_file("encode_lib_then_check", "source.rs", LIBRARY_SOURCE);
    let out_path = path.parent().unwrap().join("lib.ball.json");

    let encoded = ball(&[
        "encode",
        "--lib",
        path.to_str().unwrap(),
        "--output",
        out_path.to_str().unwrap(),
    ]);
    assert_eq!(exit_code(&encoded), 0, "stderr: {}", stderr(&encoded));

    // The documented boundary: a library-mode program has no entry function,
    // so `ball check` must refuse it rather than any code path silently
    // synthesising a fake entry point. Mirrored exactly by the C# encoder's
    // `EncodeLibrary` + `ball check` ("missing entry_function").
    let checked = ball(&["check", out_path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&checked), 2, "stdout: {}", stdout(&checked));
    assert!(
        stderr(&checked).contains("missing entry_function"),
        "stderr: {}",
        stderr(&checked)
    );
}
