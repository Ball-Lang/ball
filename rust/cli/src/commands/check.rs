//! `ball check <program>` — parse/validate a Ball program without running it
//! (issue #41).
use std::collections::HashSet;
use std::path::Path;

use ball_compiler::Compiler;
use ball_shared::proto::ball::v1::Program;

use crate::error::CliError;
use crate::loader::load_engine;
use crate::panic_guard::catch_panic_message;

/// Load `path` (a [`CliError::Io`]/[`CliError::Parse`] failure here is the
/// same as every other subcommand's — see [`crate::loader`]), then run a
/// battery of structural checks against the loaded `Program` — mirrors
/// `dart/cli/lib/src/runner.dart`'s `_validate`:
/// - `entry_module`/`entry_function` are set and resolve to a real module and
///   function.
/// - Every module has a non-empty, unique name.
/// - Every non-base function carries a `body` or `metadata` (a bodiless,
///   non-base function is a malformed program — base functions are the only
///   ones allowed to omit a body).
///
/// When `also_compile` is set (`ball check --compile`), additionally
/// attempts a dry-run `ball-compiler` compile (output discarded) — a
/// stronger, Rust-target-specific check that catches shapes the structural
/// checks above don't (an unregistered base call, an unsupported construct),
/// at the cost of false positives for a program that is valid Ball but hits
/// one of `ball-compiler`'s documented scope gaps (see
/// `rust/compiler/src/lib.rs`) — hence opt-in rather than the default.
///
/// Any finding is reported as a single [`CliError::Parse`] (exit `2`)
/// listing every problem found, never a partial/silent failure. Success
/// prints a one-line summary to stdout and returns `Ok(())` (exit `0`).
pub fn check(path: &Path, also_compile: bool) -> Result<(), CliError> {
    let engine = load_engine(path)?;
    let program = engine.program();

    let mut errors = validate_structure(program);

    if also_compile && errors.is_empty() {
        if let Err(e) = catch_panic_message(|| Compiler::new(program).compile()) {
            errors.push(format!("does not compile to Rust: {e}"));
        }
    }

    if !errors.is_empty() {
        let mut message = format!("invalid program: {} error(s) found", errors.len());
        for err in &errors {
            message.push_str(&format!("\n  - {err}"));
        }
        return Err(CliError::Parse(message));
    }

    let function_count: usize = program.modules.iter().map(|m| m.functions.len()).sum();
    println!("Valid: \"{}\" v{}", program.name, program.version);
    println!(
        "  {} module(s), {function_count} function(s)",
        program.modules.len()
    );
    Ok(())
}

/// The structural checks proper (issue #41) — a plain `Vec<String>` of
/// human-readable findings, empty when the program is structurally sound.
/// Split out from [`check`] so it stays trivially unit-testable without a
/// filesystem round trip.
fn validate_structure(program: &Program) -> Vec<String> {
    let mut errors = Vec::new();

    if program.entry_module.is_empty() {
        errors.push("missing entry_module".to_string());
    }
    if program.entry_function.is_empty() {
        errors.push("missing entry_function".to_string());
    }
    if !program.entry_module.is_empty() && !program.entry_function.is_empty() {
        match program
            .modules
            .iter()
            .find(|m| m.name == program.entry_module)
        {
            None => errors.push(format!(
                "entry module \"{}\" not found in modules",
                program.entry_module
            )),
            Some(entry_module) => {
                if !entry_module
                    .functions
                    .iter()
                    .any(|f| f.name == program.entry_function)
                {
                    errors.push(format!(
                        "entry function \"{}\" not found in module \"{}\"",
                        program.entry_function, program.entry_module
                    ));
                }
            }
        }
    }

    for (index, module) in program.modules.iter().enumerate() {
        if module.name.is_empty() {
            errors.push(format!("module at index {index} has no name"));
        }
    }

    let mut seen_names = HashSet::new();
    for module in &program.modules {
        if !module.name.is_empty() && !seen_names.insert(module.name.as_str()) {
            errors.push(format!("duplicate module name: \"{}\"", module.name));
        }
    }

    for module in &program.modules {
        for func in &module.functions {
            if !func.is_base && func.body.is_none() && func.metadata.is_none() {
                errors.push(format!(
                    "{}.{}: non-base function with no body or metadata",
                    module.name, func.name
                ));
            }
        }
    }

    errors
}

#[cfg(test)]
mod tests {
    use ball_shared::proto::ball::v1::{FunctionDefinition, Module};

    use super::*;

    fn base_program() -> Program {
        Program {
            name: "t".to_string(),
            version: "1.0.0".to_string(),
            entry_module: "main".to_string(),
            entry_function: "main".to_string(),
            modules: vec![Module {
                name: "main".to_string(),
                functions: vec![FunctionDefinition {
                    name: "main".to_string(),
                    metadata: Some(Default::default()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    #[test]
    fn a_well_formed_program_has_no_errors() {
        assert!(validate_structure(&base_program()).is_empty());
    }

    #[test]
    fn missing_entry_module_is_an_error() {
        let mut program = base_program();
        program.entry_module.clear();
        let errors = validate_structure(&program);
        assert!(errors.iter().any(|e| e.contains("missing entry_module")));
    }

    #[test]
    fn entry_function_not_found_is_an_error() {
        let mut program = base_program();
        program.entry_function = "does_not_exist".to_string();
        let errors = validate_structure(&program);
        assert!(errors.iter().any(|e| e.contains("entry function")));
    }

    #[test]
    fn duplicate_module_names_are_an_error() {
        let mut program = base_program();
        program.modules.push(program.modules[0].clone());
        let errors = validate_structure(&program);
        assert!(errors.iter().any(|e| e.contains("duplicate module name")));
    }

    #[test]
    fn a_bodiless_non_base_function_with_no_metadata_is_an_error() {
        let mut program = base_program();
        program.modules[0].functions[0].metadata = None;
        let errors = validate_structure(&program);
        assert!(
            errors
                .iter()
                .any(|e| e.contains("non-base function with no body or metadata"))
        );
    }
}
