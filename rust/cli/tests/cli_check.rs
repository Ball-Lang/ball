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
