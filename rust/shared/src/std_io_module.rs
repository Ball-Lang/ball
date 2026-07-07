//! `std_io` base module builder (issue #35).
//!
//! Ports `dart/shared/lib/std_io.dart` to Rust. Import explicitly — not
//! available in browser JS, WASM sandboxes, embedded targets, or serverless
//! functions without a TTY. Depends on `std`.

use crate::descriptor_builders::{base_fn, int_field, string_field, type_def};
use crate::{FunctionDefinition, Module, TypeDefinition};

/// Build the `std_io` base module.
pub fn build_std_io_module() -> Module {
    Module {
        name: "std_io".to_string(),
        description: "Standard I/O module. Console, process, time, random, environment. \
            Not available in all runtimes (browser, WASM, embedded)."
            .to_string(),
        type_defs: type_defs(),
        functions: functions(),
        ..Default::default()
    }
}

fn type_defs() -> Vec<TypeDefinition> {
    vec![
        type_def("PrintErrorInput", vec![string_field("message", 1)]),
        type_def("ExitInput", vec![int_field("code", 1)]),
        type_def("PanicInput", vec![string_field("message", 1)]),
        type_def("SleepInput", vec![int_field("milliseconds", 1)]),
        type_def(
            "RandomIntInput",
            vec![int_field("min", 1), int_field("max", 2)],
        ),
        type_def("EnvGetInput", vec![string_field("name", 1)]),
    ]
}

fn functions() -> Vec<FunctionDefinition> {
    vec![
        // --- Console ---
        base_fn(
            "print_error",
            "PrintErrorInput",
            "",
            "Write to stderr: stderr.writeln(message)",
        ),
        // --- Standard input ---
        base_fn("read_line", "", "", "Read one line from stdin"),
        // --- Process control ---
        base_fn("exit", "ExitInput", "", "Terminate with exit code"),
        base_fn(
            "panic",
            "PanicInput",
            "",
            "Hard abort with message (Rust panic!, C++ terminate, Java RuntimeException)",
        ),
        // --- Time ---
        base_fn(
            "sleep_ms",
            "SleepInput",
            "",
            "Pause execution N milliseconds",
        ),
        base_fn(
            "timestamp_ms",
            "",
            "",
            "Wall clock milliseconds since epoch",
        ),
        // --- Randomness ---
        base_fn(
            "random_int",
            "RandomIntInput",
            "",
            "Random integer in range [min, max]",
        ),
        base_fn("random_double", "", "", "Random double in [0.0, 1.0)"),
        // --- Environment ---
        base_fn(
            "env_get",
            "EnvGetInput",
            "",
            "Read environment variable by name",
        ),
        base_fn(
            "args_get",
            "",
            "",
            "Command-line arguments as list of strings",
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_function_is_base_with_no_body() {
        let module = build_std_io_module();
        assert_eq!(module.name, "std_io");
        for function in &module.functions {
            assert!(function.is_base, "{} must be is_base", function.name);
            assert!(
                function.body.is_none(),
                "{} must have no body",
                function.name
            );
        }
    }

    #[test]
    fn function_count_matches_std_json() {
        let module = build_std_io_module();
        assert_eq!(module.functions.len(), 10);
    }
}
