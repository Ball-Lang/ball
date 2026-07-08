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
        "fn main() { println!(\"hi from ball-cli\"); }",
    );

    let output = ball(&["encode", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    let json = stdout(&output);
    assert!(json.contains("\"@type\": \"type.googleapis.com/ball.v1.Program\""));
    assert!(json.contains("hi from ball-cli"));

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
