//! `ball check` integration tests (issue #41).
mod common;

use common::{ball, exit_code, repo_path, stderr, stdout, write_scratch_file};

#[test]
fn missing_file_exits_3() {
    let output = ball(&["check", "does/not/exist.ball.json"]);
    assert_eq!(exit_code(&output), 3, "stderr: {}", stderr(&output));
}

#[test]
fn malformed_json_exits_2() {
    let path = write_scratch_file("check_malformed_json", "bad.ball.json", "{ not json");
    let output = ball(&["check", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 2, "stderr: {}", stderr(&output));
}

#[test]
fn hello_world_is_valid() {
    let program = repo_path("examples/hello_world/hello_world.ball.json");
    let output = ball(&["check", program.to_str().unwrap()]);

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    assert!(stdout(&output).starts_with("Valid:"));
}

#[test]
fn hello_world_passes_the_stricter_compile_check_too() {
    let program = repo_path("examples/hello_world/hello_world.ball.json");
    let output = ball(&["check", "--compile", program.to_str().unwrap()]);

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
}

#[test]
fn fibonacci_is_valid() {
    let program = repo_path("examples/fibonacci/fibonacci.ball.json");
    let output = ball(&["check", program.to_str().unwrap()]);

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
}

#[test]
fn a_program_with_a_missing_entry_function_is_reported_invalid() {
    let json = r#"{
        "name": "broken", "version": "1.0.0",
        "entryModule": "main", "entryFunction": "does_not_exist",
        "modules": [ { "name": "main", "functions": [
            { "name": "main", "metadata": { "kind": "function" } }
        ] } ]
    }"#;
    let path = write_scratch_file("check_missing_entry_function", "broken.ball.json", json);

    let output = ball(&["check", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 2, "stderr: {}", stderr(&output));
    assert!(stderr(&output).contains("entry function"));
    assert!(stdout(&output).is_empty());
}

/// Issue #491, slice 3: `ball encode` now emits a **source-less
/// `ModuleImport`** for a call into a module the encoded file does not declare
/// (`other_file::helper(1)`), where it used to panic. This pins what `ball
/// check` actually does with that program — verified, not assumed, and the
/// analogue of library mode's own "deliberately not runnable" boundary.
///
/// The contract: a source-less import is the proto's "reference only" shape —
/// structurally legal and deliberately unresolved. Neither this CLI's
/// `validate_structure` nor the reference Dart tooling
/// (`dart/shared/lib/cli_core.dart`'s `validationErrors`, which the
/// self-hosted `ball validate` runs, and `dart/cli/lib/src/runner.dart`'s
/// `ball build`, which counts an import as needing the resolver only when
/// `whichSource() != notSet`) treats it as an error. So `check` accepts it:
/// the program is well-formed, and only *running* it can discover that
/// `other_file` was never supplied.
#[test]
fn encoded_cross_file_call_is_structurally_valid_but_unresolved() {
    let source = write_scratch_file(
        "check_cross_file_import",
        "source.rs",
        "fn main() { println!(\"{}\", other_file::helper(1)); }",
    );
    let dir = source.parent().expect("scratch file has a parent");
    let encoded = dir.join("program.ball.json");

    let encode = ball(&[
        "encode",
        source.to_str().unwrap(),
        "--output",
        encoded.to_str().unwrap(),
    ]);
    assert_eq!(exit_code(&encode), 0, "stderr: {}", stderr(&encode));

    let json = std::fs::read_to_string(&encoded).expect("the encoded program must be written");
    let output = ball(&["check", encoded.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(dir);

    assert!(
        json.contains("\"other_file\""),
        "the encoded program must carry the unresolved import:\n{json}"
    );
    assert_eq!(
        exit_code(&output),
        0,
        "an unresolved (source-less) ModuleImport is structurally legal — `check` must \
         accept it, exactly as the Dart reference tooling does. stderr: {}",
        stderr(&output)
    );
    assert!(stdout(&output).starts_with("Valid:"));
}

#[test]
fn a_bodiless_non_base_function_with_no_metadata_is_reported_invalid() {
    let json = r#"{
        "name": "broken", "version": "1.0.0",
        "entryModule": "main", "entryFunction": "main",
        "modules": [ { "name": "main", "functions": [
            { "name": "main" },
            { "name": "helper" }
        ] } ]
    }"#;
    let path = write_scratch_file("check_bodiless_function", "broken.ball.json", json);

    let output = ball(&["check", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 2, "stderr: {}", stderr(&output));
    assert!(stderr(&output).contains("no body or metadata"));
}
