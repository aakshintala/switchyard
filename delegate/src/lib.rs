// Test seams are injected as `dyn Fn` fields, and the poll/dispatch results are short-lived
// values returned once per call.
#![allow(clippy::type_complexity, clippy::large_enum_variant)]

pub mod backends;
pub mod cli;
pub mod cli_info;
pub mod config;
pub mod doctor;
pub mod finalize;
pub mod gate;
pub mod git;
pub mod job;
pub mod models;
pub mod output;
pub mod pricing;
pub mod prompt;
pub mod session;
pub mod status_record;
pub mod stream;
pub mod types;
pub mod util;
