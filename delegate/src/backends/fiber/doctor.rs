//! fiber doctor probes: `fiber version` and `fiber models --json`
//! membership for each configured `fiber/...` model. Fiber has no auth-check
//! command yet, so these two checks are the whole probe.

use super::{model_reference, resolve_bin};
use crate::cli_info::status_line;
use crate::doctor::{AgentCommandResult, RunDoctorOpts, command_err};
use crate::types::{DoctorBackendSection, DoctorReport};

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
        .filter(|(_, e)| e.backend == "fiber")
        .map(|(id, _)| id.clone())
        .collect();
    configured_ids.sort();

    if !bin_exists(&path) {
        report.sections.push(DoctorBackendSection {
            backend: "fiber".into(),
            found: false,
            path: Some(path),
            ..Default::default()
        });
        return;
    }

    let (ver, ver_err) = probe_version(&path, &run_command);
    if let Some(e) = &ver_err {
        report.failures.push(format!("fiber version failed: {e}"));
    }
    let model_failures = probe_memberships(&path, &configured_ids, &run_command);
    report.sections.push(DoctorBackendSection {
        backend: "fiber".into(),
        found: true,
        path: Some(path),
        version: ver,
        version_error: ver_err,
        model_failures,
    });
}

pub(crate) fn lines(report: &DoctorReport) -> (String, bool) {
    // No section means no fiber models in the table: nothing to say.
    let Some(sec) = report.sections.iter().find(|s| s.backend == "fiber") else {
        return (String::new(), false);
    };
    let mut text = String::new();
    let mut failed = false;
    if !sec.found {
        text += &status_line(
            "warn",
            "fiber: fiber not found (optional; set FIBER_BIN or put fiber on PATH)",
        );
        return (text, false);
    }
    let path = sec.path.as_deref().unwrap_or("?");
    match sec.version.as_deref() {
        Some(v) => {
            text += &status_line("ok", &format!("fiber: fiber {v} ({path})"));
        }
        None => {
            let e = sec.version_error.as_deref().unwrap_or("unknown error");
            text += &status_line("fail", &format!("fiber: fiber version failed: {e}"));
            failed = true;
        }
    }
    for m in &sec.model_failures {
        text += &status_line("warn", &format!("fiber: {m}"));
    }
    (text, failed)
}

/// Check that each configured id's reference appears in `fiber models --json`.
fn probe_memberships(
    bin: &str,
    configured_ids: &[String],
    run_command: &dyn Fn(&str, &[String]) -> AgentCommandResult,
) -> Vec<String> {
    if configured_ids.is_empty() {
        return Vec::new();
    }
    let r = run_command(bin, &["models".into(), "--json".into()]);
    if !r.ok {
        let err = command_err("fiber", &r, "models --json");
        return configured_ids
            .iter()
            .map(|id| format!("model {id} models check failed: {err}"))
            .collect();
    }
    let available = parse_models_json(&r.stdout);
    configured_ids
        .iter()
        .filter(|id| !available.contains(&without_level(model_reference(id)).to_string()))
        .map(|id| format!("model {id} not found in fiber models --json"))
        .collect()
}

/// Drop a trailing `:<level>` from a reference. `fiber models --json` lists
/// ids without a level, so `codex/gpt-6-luna:medium` is checked as
/// `codex/gpt-6-luna`.
fn without_level(reference: &str) -> &str {
    match reference.rsplit_once(':') {
        Some((base, "low" | "medium" | "high" | "xhigh" | "max" | "off" | "minimal")) => base,
        _ => reference,
    }
}

/// Parse `fiber models --json` output: one JSON object per line with a
/// `model` field holding the `provider/model` reference.
pub(crate) fn parse_models_json(stdout: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(line)
            && let Some(m) = model_of(&v)
        {
            out.push(m);
        }
    }
    out
}

fn model_of(v: &serde_json::Value) -> Option<String> {
    v.get("model")
        .and_then(|m| m.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

pub(crate) fn probe_version(
    bin: &str,
    run_command: &dyn Fn(&str, &[String]) -> AgentCommandResult,
) -> (Option<String>, Option<String>) {
    let r = run_command(bin, &["version".into()]);
    if !r.ok {
        return (None, Some(command_err("fiber", &r, "version")));
    }
    let raw = r.stdout.trim();
    // `fiber version` prints `fiber 0.0.0 (hash)`: strip the leading
    // `fiber ` so the status line (`fiber: fiber <version> (<path)>`,
    // like pi's `pi: pi <version> (<path>)`) does not repeat it.
    let version = raw.strip_prefix("fiber ").unwrap_or(raw);
    (
        if version.is_empty() {
            None
        } else {
            Some(version.to_string())
        },
        None,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Config, HostProfile, ModelEntry, Price};
    use std::collections::HashMap;

    fn config_with_fiber_ids(ids: &[&str]) -> Config {
        let mut models: HashMap<String, ModelEntry> = HashMap::new();
        for id in ids {
            models.insert(
                (*id).into(),
                ModelEntry {
                    label: (*id).into(),
                    backend: "fiber".into(),
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
        let default = ids
            .first()
            .unwrap_or(&"fiber/opencode-go/muse-spark-1.3-contributor")
            .to_string();
        Config {
            default,
            price_map: models.iter().map(|(k, v)| (k.clone(), v.price)).collect(),
            models,
            profile: HostProfile::default(),
        }
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

    fn failures_for(
        ids: &[&str],
        run: &(dyn Fn(&str, &[String]) -> AgentCommandResult + Sync),
    ) -> (DoctorReport, Vec<String>) {
        let config = config_with_fiber_ids(ids);
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/fiber".into()),
            bin_exists: Some(&|_| true),
            run_command: Some(run),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        let failures = report
            .sections
            .iter()
            .find(|s| s.backend == "fiber")
            .expect("fiber section")
            .model_failures
            .clone();
        (report, failures)
    }

    #[test]
    fn parse_models_json_reads_json_lines() {
        let out = "{\"model\":\"opencode-go/muse-spark-1.3-contributor\",\"context_window\":1048576,\"input\":0.1,\"output\":0.2,\"default\":false}\n\
                   {\"model\":\"other/model\",\"context_window\":1,\"input\":1,\"output\":1,\"default\":false}\n";
        assert_eq!(
            parse_models_json(out),
            vec![
                "opencode-go/muse-spark-1.3-contributor".to_string(),
                "other/model".to_string()
            ]
        );
        assert!(parse_models_json("").is_empty());
    }

    #[test]
    fn fill_present_model_has_no_failures() {
        let run = |_: &str, args: &[String]| match args.join(" ").as_str() {
            "version" => ok_result("fiber 0.0.0 (a903fb6f)\n"),
            "models --json" => ok_result(
                "{\"model\":\"opencode-go/muse-spark-1.3-contributor\",\"context_window\":1048576,\"input\":0.1,\"output\":0.2,\"default\":false}\n",
            ),
            other => panic!("unexpected {other}"),
        };
        let (report, failures) =
            failures_for(&["fiber/opencode-go/muse-spark-1.3-contributor"], &run);
        assert!(failures.is_empty(), "{failures:?}");
        assert!(report.failures.is_empty());
        let (text, failed) = lines(&report);
        assert!(!failed);
        assert!(
            text.contains("ok    fiber: fiber 0.0.0 (a903fb6f) (/bin/fiber)"),
            "{text}"
        );
    }

    #[test]
    fn fill_missing_model_is_a_warning() {
        let run = |_: &str, args: &[String]| match args.join(" ").as_str() {
            "version" => ok_result("0.0.0\n"),
            "models --json" => ok_result("{\"model\":\"other/model\"}\n"),
            other => panic!("unexpected {other}"),
        };
        let (report, failures) =
            failures_for(&["fiber/opencode-go/muse-spark-1.3-contributor"], &run);
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert!(
            failures[0].contains("not found in fiber models --json"),
            "{}",
            failures[0]
        );
        let (text, failed) = lines(&report);
        assert!(!failed);
        assert!(
            text.contains(
                "warn  fiber: model fiber/opencode-go/muse-spark-1.3-contributor not found"
            ),
            "{text}"
        );
    }

    #[test]
    fn fill_models_failure_is_a_warning_per_model() {
        let run = |_: &str, args: &[String]| match args.join(" ").as_str() {
            "version" => ok_result("0.0.0\n"),
            "models --json" => err_result(),
            other => panic!("unexpected {other}"),
        };
        let (_, failures) = failures_for(&["fiber/opencode-go/muse-spark-1.3-contributor"], &run);
        assert_eq!(failures.len(), 1);
        assert!(
            failures[0].contains("models check failed"),
            "{}",
            failures[0]
        );
    }

    #[test]
    fn fill_version_failure_is_a_failure() {
        let run = |_: &str, args: &[String]| match args.join(" ").as_str() {
            "version" => err_result(),
            "models --json" => {
                ok_result("{\"model\":\"opencode-go/muse-spark-1.3-contributor\"}\n")
            }
            other => panic!("unexpected {other}"),
        };
        let (report, _) = failures_for(&["fiber/opencode-go/muse-spark-1.3-contributor"], &run);
        assert!(
            report
                .failures
                .iter()
                .any(|f| f.contains("fiber version failed"))
        );
        let (text, failed) = lines(&report);
        assert!(failed);
        assert!(text.contains("fail  fiber: fiber version failed"), "{text}");
    }

    #[test]
    fn fill_missing_binary_is_a_warning() {
        let config = config_with_fiber_ids(&["fiber/opencode-go/muse-spark-1.3-contributor"]);
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/fiber".into()),
            bin_exists: Some(&|_| false),
            run_command: Some(&|_, _| panic!("must not run when the binary is missing")),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        assert!(report.failures.is_empty(), "{:?}", report.failures);
        let (text, failed) = lines(&report);
        assert!(!failed);
        assert!(text.starts_with("warn  fiber: fiber not found"), "{text}");
    }

    #[test]
    fn fill_leveled_model_matches_its_unleveled_listing() {
        let run = |_: &str, args: &[String]| match args.join(" ").as_str() {
            "version" => ok_result("fiber 0.0.0 (a903fb6f)\n"),
            "models --json" => ok_result("{\"model\":\"codex/gpt-6-luna\"}\n"),
            other => panic!("unexpected {other}"),
        };
        for id in [
            "fiber/codex/gpt-6-luna:medium",
            "fiber/codex/gpt-6-luna:off",
            "fiber/codex/gpt-6-luna:minimal",
        ] {
            let (report, failures) = failures_for(&[id], &run);
            assert!(failures.is_empty(), "{id}: {failures:?}");
            assert!(report.failures.is_empty());
        }
    }

    #[test]
    fn fill_off_and_minimal_match_unleveled_listing() {
        let run = |_: &str, args: &[String]| match args.join(" ").as_str() {
            "version" => ok_result("fiber 0.0.0 (a903fb6f)\n"),
            "models --json" => ok_result("{\"model\":\"codex/gpt-6-luna\"}\n"),
            other => panic!("unexpected {other}"),
        };
        let (_, failures) = failures_for(
            &[
                "fiber/codex/gpt-6-luna:off",
                "fiber/codex/gpt-6-luna:minimal",
            ],
            &run,
        );
        assert!(failures.is_empty(), "{failures:?}");
    }

    #[test]
    fn without_level_strips_only_known_levels() {
        assert_eq!(without_level("codex/gpt-6-luna:medium"), "codex/gpt-6-luna");
        assert_eq!(without_level("codex/gpt-6-luna:xhigh"), "codex/gpt-6-luna");
        assert_eq!(without_level("codex/gpt-6-luna:off"), "codex/gpt-6-luna");
        assert_eq!(
            without_level("codex/gpt-6-luna:minimal"),
            "codex/gpt-6-luna"
        );
        assert_eq!(without_level("codex/gpt-6-luna"), "codex/gpt-6-luna");
        assert_eq!(without_level("org/model:beta"), "org/model:beta");
    }
}
