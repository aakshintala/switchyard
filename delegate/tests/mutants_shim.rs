//! #435: every job's environment intercepts `cargo-mutants` with a refusing shim.

use delegate::gate::{GateOpts, run_gate};

#[test]
fn cargo_mutants_shim_refuses_through_the_job_seam() {
    let cwd = std::env::current_dir()
        .expect("cwd")
        .to_string_lossy()
        .into_owned();
    let result = run_gate(
        "cargo-mutants --version",
        &cwd,
        GateOpts {
            timeout_ms: Some(30_000),
            signal: None,
        },
    );
    assert_eq!(result.exit_code, 1, "{result:?}");
    assert!(!result.passed, "{result:?}");
    assert!(
        result
            .output_tail
            .contains("cargo mutants is CI-only; read the CI mutants log instead"),
        "{result:?}"
    );
}
