//! #435: every job's environment intercepts `cargo-mutants` with a refusing shim.

use delegate::gate::{GateOpts, run_gate};

#[test]
fn cargo_mutants_shim_refuses_through_the_job_seam() {
    let cwd = std::env::current_dir()
        .expect("cwd")
        .to_string_lossy()
        .into_owned();
    // Both spellings must refuse: the binary directly, and the
    // `cargo mutants` subcommand form agents actually type. Cargo resolves
    // the latter to `cargo-mutants` on PATH, so a change in that lookup
    // must not bypass the shim silently (#437).
    for command in ["cargo-mutants --version", "cargo mutants --version"] {
        let result = run_gate(
            command,
            &cwd,
            GateOpts {
                timeout_ms: Some(30_000),
                signal: None,
            },
        );
        assert_eq!(result.exit_code, 1, "{command}: {result:?}");
        assert!(!result.passed, "{command}: {result:?}");
        assert!(
            result
                .output_tail
                .contains("cargo mutants is CI-only; read the CI mutants log instead"),
            "{command}: {result:?}"
        );
    }
}
