//! Codex doctor probes: `codex --version`, `codex login status`, and an
//! unchecked warning per configured `codex/...` model. No model turn or
//! experimental protocol is run for membership: local help exposes no bounded
//! per-model command, so every configured row is reported as unchecked.

use super::resolve_bin;
use crate::cli_info::status_line;
use crate::doctor::{AgentCommandResult, RunDoctorOpts, command_err};
use crate::types::{DoctorBackendSection, DoctorReport};

/// Where the missing binary was looked up, in order.
pub(crate) const LOOKUP_ORDER: &str =
    "override, $CODEX_BIN, PATH `which codex`, ~/.local/bin/codex";

pub(crate) fn fill(report: &mut DoctorReport, opts: &RunDoctorOpts<'_>) {
    let path = match opts.resolve_bin {
        Some(f) => f(None),
        None => resolve_bin(None),
    };
    let bin_exists = |p: &str| match opts.bin_exists {
        Some(f) => f(p),
        None => std::path::Path::new(p).exists(),
    };
    let injected = opts.run_command;
    let run_command = move |bin: &str, args: &[String]| match injected {
        Some(f) => f(bin, args),
        None => crate::doctor::default_run_agent_command(bin, args),
    };

    // Only this backend's models are checked. Others are skip lines in the CLI.
    let mut configured_ids: Vec<String> = opts
        .config
        .models
        .iter()
        .filter(|(_, e)| e.backend == "codex")
        .map(|(id, _)| id.clone())
        .collect();
    configured_ids.sort();

    // No codex rows in the table: nothing to say, and no command to run, so
    // configs without codex rows never need a fake codex binary.
    if configured_ids.is_empty() {
        return;
    }

    if !bin_exists(&path) {
        report.failures.push(format!(
            "codex not found at {path} (checked {LOOKUP_ORDER})"
        ));
        report.sections.push(DoctorBackendSection {
            backend: "codex".into(),
            found: false,
            path: Some(path),
            ..Default::default()
        });
        return;
    }

    let (ver, ver_err) = probe_version(&path, &run_command);
    if let Some(e) = &ver_err {
        report.failures.push(format!("codex --version failed: {e}"));
    }
    let (logged_in, login_err) = probe_login(&path, &run_command);
    let mut model_failures: Vec<String> = Vec::new();
    if !logged_in {
        model_failures.push(format!(
            "login check failed: {}",
            login_err.unwrap_or_else(|| "codex login status failed".into())
        ));
    }
    // No bounded per-model membership command exists, so every configured row
    // is an unchecked warning, sorted by full row id.
    for id in &configured_ids {
        model_failures.push(format!(
            "model {id} not checked: no supported codex membership probe"
        ));
    }
    report.sections.push(DoctorBackendSection {
        backend: "codex".into(),
        found: true,
        path: Some(path),
        version: ver,
        version_error: ver_err,
        model_failures,
    });
}

pub(crate) fn lines(report: &DoctorReport) -> (String, bool) {
    // No section means no codex models in the table: nothing to say.
    let Some(sec) = report.sections.iter().find(|s| s.backend == "codex") else {
        return (String::new(), false);
    };
    let mut text = String::new();
    let mut failed = false;
    if !sec.found {
        let path = sec.path.as_deref().unwrap_or("?");
        text += &status_line(
            "fail",
            &format!("codex: codex not found at {path} (checked {LOOKUP_ORDER})"),
        );
        return (text, true);
    }
    let path = sec.path.as_deref().unwrap_or("?");
    match sec.version.as_deref() {
        Some(v) => {
            text += &status_line("ok", &format!("codex: codex {v} ({path})"));
        }
        None => {
            let e = sec.version_error.as_deref().unwrap_or("unknown error");
            text += &status_line("fail", &format!("codex: codex --version failed: {e}"));
            failed = true;
        }
    }
    let login_failed = sec
        .model_failures
        .iter()
        .any(|m| m.starts_with("login check failed"));
    if !login_failed {
        text += &status_line("ok", "codex: logged in");
    }
    for m in &sec.model_failures {
        text += &status_line("warn", &format!("codex: {m}"));
    }
    (text, failed)
}

pub(crate) fn probe_version(
    bin: &str,
    run_command: &dyn Fn(&str, &[String]) -> AgentCommandResult,
) -> (Option<String>, Option<String>) {
    let r = run_command(bin, &["--version".into()]);
    if !r.ok {
        return (None, Some(command_err("codex", &r, "--version")));
    }
    let version = r.stdout.trim();
    (
        if version.is_empty() {
            None
        } else {
            Some(version.to_string())
        },
        None,
    )
}

pub(crate) fn probe_login(
    bin: &str,
    run_command: &dyn Fn(&str, &[String]) -> AgentCommandResult,
) -> (bool, Option<String>) {
    let r = run_command(bin, &["login".into(), "status".into()]);
    if !r.ok {
        return (false, Some(command_err("codex", &r, "login status")));
    }
    (true, None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Config, HostProfile, ModelEntry, Price};
    use std::collections::HashMap;

    fn config_with_codex_ids(ids: &[&str]) -> Config {
        let mut models: HashMap<String, ModelEntry> = HashMap::new();
        for id in ids {
            models.insert(
                (*id).into(),
                ModelEntry {
                    label: (*id).into(),
                    backend: "codex".into(),
                    price: Price {
                        input: 1.0,
                        output: 2.0,
                        cache_read: 0.0,
                        cache_write: 0.0,
                    },
                    tiers: vec![],
                },
            );
        }
        let default = ids.first().unwrap_or(&"codex/gpt-6-luna").to_string();
        Config {
            default,
            price_map: models.iter().map(|(k, v)| (k.clone(), v.price)).collect(),
            models,
            profile: HostProfile::default(),
        }
    }

    #[test]
    fn fill_missing_binary_fails_and_names_the_lookup_order() {
        let config = config_with_codex_ids(&["codex/gpt-6-luna"]);
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/nowhere/codex".into()),
            bin_exists: Some(&|_| false),
            run_command: Some(&|_, _| panic!("must not run when the binary is missing")),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        assert_eq!(report.failures.len(), 1);
        assert!(
            report.failures[0].contains("codex"),
            "{}",
            report.failures[0]
        );
        assert!(
            report.failures[0].contains("$CODEX_BIN"),
            "{}",
            report.failures[0]
        );
        assert!(
            report.failures[0].contains("which codex"),
            "{}",
            report.failures[0]
        );
        let (text, failed) = lines(&report);
        assert!(failed);
        assert!(text.contains("fail  codex: codex not found"), "{text}");
        assert!(text.contains("$CODEX_BIN"), "{text}");
    }

    fn ok_result(stdout: &str) -> AgentCommandResult {
        AgentCommandResult {
            ok: true,
            stdout: stdout.into(),
            stderr: String::new(),
            error: None,
        }
    }

    fn err_result() -> AgentCommandResult {
        AgentCommandResult {
            ok: false,
            stdout: String::new(),
            stderr: String::new(),
            error: Some("exit 1".into()),
        }
    }

    #[test]
    fn fill_without_codex_rows_reports_no_section_and_runs_nothing() {
        let mut models: HashMap<String, ModelEntry> = HashMap::new();
        models.insert(
            "openai/gpt-6-luna".into(),
            ModelEntry {
                label: "GPT-6 Luna".into(),
                backend: "pi".into(),
                price: Price {
                    input: 1.0,
                    output: 2.0,
                    cache_read: 0.0,
                    cache_write: 0.0,
                },
                tiers: vec![],
            },
        );
        let config = Config {
            default: "openai/gpt-6-luna".into(),
            price_map: models.iter().map(|(k, v)| (k.clone(), v.price)).collect(),
            models,
            profile: HostProfile::default(),
        };
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/codex".into()),
            bin_exists: Some(&|_| true),
            run_command: Some(&|_, _| panic!("no codex rows: no command may run")),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        assert!(report.failures.is_empty());
        assert!(report.sections.iter().all(|s| s.backend != "codex"));
        let (text, failed) = lines(&report);
        assert_eq!((text, failed), (String::new(), false));
    }

    #[test]
    fn fill_healthy_probes_report_version_login_and_unchecked_rows() {
        let config = config_with_codex_ids(&[
            "codex/gpt-6-luna:xhigh",
            "codex/gpt-6-astra",
            "codex/gpt-6-luna",
        ]);
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/codex".into()),
            bin_exists: Some(&|_| true),
            run_command: Some(&|_: &str, args: &[String]| {
                if args == ["--version"] {
                    ok_result("codex-cli 0.160.0\n")
                } else {
                    assert_eq!(args, &["login".to_string(), "status".to_string()]);
                    ok_result("Logged in using ChatGPT\n")
                }
            }),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        assert!(report.failures.is_empty());
        let section = report
            .sections
            .iter()
            .find(|s| s.backend == "codex")
            .expect("codex section");
        assert_eq!(section.version.as_deref(), Some("codex-cli 0.160.0"));
        // Every configured row is an unchecked warning, sorted by full row id.
        assert_eq!(
            section.model_failures,
            vec![
                "model codex/gpt-6-astra not checked: no supported codex membership probe",
                "model codex/gpt-6-luna not checked: no supported codex membership probe",
                "model codex/gpt-6-luna:xhigh not checked: no supported codex membership probe",
            ]
        );
        let (text, failed) = lines(&report);
        assert!(!failed);
        assert!(
            text.contains("ok    codex: codex codex-cli 0.160.0 (/bin/codex)"),
            "{text}"
        );
        assert!(text.contains("ok    codex: logged in"), "{text}");
        assert!(
            text.contains("warn  codex: model codex/gpt-6-astra not checked"),
            "{text}"
        );
    }

    #[test]
    fn fill_failed_version_is_a_failure_and_failed_login_is_a_warning() {
        let config = config_with_codex_ids(&["codex/gpt-6-luna"]);
        // Failed version.
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/codex".into()),
            bin_exists: Some(&|_| true),
            run_command: Some(&|_: &str, args: &[String]| {
                if args == ["--version"] {
                    err_result()
                } else {
                    ok_result("Logged in using ChatGPT\n")
                }
            }),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        assert!(
            report
                .failures
                .iter()
                .any(|f| f.contains("codex --version failed"))
        );
        let (text, failed) = lines(&report);
        assert!(failed);
        assert!(
            text.contains("fail  codex: codex --version failed"),
            "{text}"
        );
        // Empty version output fails the same way.
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/codex".into()),
            bin_exists: Some(&|_| true),
            run_command: Some(&|_: &str, args: &[String]| {
                if args == ["--version"] {
                    ok_result("\n")
                } else {
                    ok_result("Logged in using ChatGPT\n")
                }
            }),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        let (text, failed) = lines(&report);
        assert!(failed);
        assert!(
            text.contains("fail  codex: codex --version failed"),
            "{text}"
        );
        // Failed login warns but does not fail; the login line stays silent.
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/codex".into()),
            bin_exists: Some(&|_| true),
            run_command: Some(&|_: &str, args: &[String]| {
                if args == ["--version"] {
                    ok_result("codex-cli 0.160.0\n")
                } else {
                    err_result()
                }
            }),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        assert!(report.failures.is_empty());
        let (text, failed) = lines(&report);
        assert!(!failed);
        assert!(!text.contains("ok    codex: logged in"), "{text}");
        assert!(text.contains("warn  codex: login check failed"), "{text}");
    }

    #[test]
    fn lines_empty_without_a_codex_section() {
        let report = DoctorReport::default();
        assert_eq!(lines(&report), (String::new(), false));
    }
}
