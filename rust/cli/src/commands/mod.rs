//! The `ball` subcommands: `run`/`compile`/`encode`/`check` (issue #41) plus
//! the self-hosted cli-core verbs `info`/`validate`/`tree`/`audit`/`version`
//! (issue #365), one module each.
pub mod audit;
pub mod check;
pub mod compile;
pub mod encode;
pub mod info;
pub mod run;
pub mod tree;
pub mod validate;
pub mod version;
