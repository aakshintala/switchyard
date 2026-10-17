//! pi doctor probes: `pi --version`, `pi auth check --model <id>`,
//! and `pi --list-models <model>` (exact provider/model match) for
//! each configured pi model. `auth check` exits 0 for any id, so the
//! list-models probe is what catches models pi does not have.

use super::resolve_bin;
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
        .filter(|(_, e)| e.backend == "pi")
        .map(|(id, _)| id.clone())
        .collect();
    configured_ids.sort();

    if !bin_exists(&path) {
        report.failures.push(format!("pi not found at {path}"));
        report.sections.push(DoctorBackendSection {
            backend: "pi".into(),
            found: false,
            path: Some(path),
            ..Default::default()
        });
        return;
    }

    let (ver, ver_err) = probe_version(&path, &run_command);
    if let Some(e) = &ver_err {
        report.failures.push(format!("pi --version failed: {e}"));
    }
    // Each check is a ~130ms pi start-up; run them together, keep the sorted order.
    let model_failures: Vec<String> = std::thread::scope(|s| {
        let checks: Vec<_> = configured_ids
            .iter()
            .map(|id| {
                let (path, run_command) = (&path, &run_command);
                s.spawn(move || {
                    let mut failures = Vec::new();
                    let r = run_command(
                        path,
                        &["auth".into(), "check".into(), "--model".into(), id.clone()],
                    );
                    if !r.ok {
                        let err = command_err("pi", &r, &format!("auth check --model {id}"));
                        failures.push(format!("model {id} auth check failed: {err}"));
                    }
                    if let Some(e) = probe_membership(path, id, &run_command) {
                        failures.push(e);
                    }
                    failures
                })
            })
            .collect();
        checks.into_iter().flat_map(|h| h.join().unwrap()).collect()
    });
    report.sections.push(DoctorBackendSection {
        backend: "pi".into(),
        found: true,
        path: Some(path),
        version: ver,
        version_error: ver_err,
        model_failures,
    });
}

pub(crate) fn lines(report: &DoctorReport) -> (String, bool) {
    // No section means no pi models in the table: nothing to say.
    let Some(sec) = report.sections.iter().find(|s| s.backend == "pi") else {
        return (String::new(), false);
    };
    let mut text = String::new();
    let mut failed = false;
    if !sec.found {
        text += &status_line("fail", "pi: pi not found");
        return (text, true);
    }
    let path = sec.path.as_deref().unwrap_or("?");
    match sec.version.as_deref() {
        Some(v) => {
            text += &status_line("ok", &format!("pi: pi {v} ({path})"));
        }
        None => {
            let e = sec.version_error.as_deref().unwrap_or("unknown error");
            text += &status_line("fail", &format!("pi: pi --version failed: {e}"));
            failed = true;
        }
    }
    for m in &sec.model_failures {
        text += &status_line("warn", &format!("pi: {m}"));
    }
    (text, failed)
}

/// Check that `id` names a model pi actually has. `pi auth check --model`
/// exits 0 for any id, so query `pi --list-models <model>` and require a
/// row whose provider and model columns equal the configured id exactly
/// (the search is fuzzy: `gpt-5.6-luna` rows also match a `gpt-6-luna`
/// query). A trailing `:<thinking>` suffix is stripped before matching and
/// additionally requires the row's thinking column to be `yes`; any other
/// colon belongs to the model itself (`vendor/model:free`) and is matched
/// whole. Returns the model failure, if any.
///
/// Only the text after the LAST `:` counts, and only when it is a pi
/// thinking level.
const THINKING_LEVELS: &[&str] = &["off", "minimal", "low", "medium", "high", "xhigh"];

/// Split a configured id into (model id, wants thinking). Only a trailing
/// `:<thinking level>` is stripped; any other colon is part of the model
/// id itself (e.g. `vendor/model:free`).
fn split_thinking_suffix(id: &str) -> (&str, bool) {
    match id.rsplit_once(':') {
        Some((base, level)) if THINKING_LEVELS.contains(&level) => (base, true),
        _ => (id, false),
    }
}

pub(crate) fn probe_membership(
    bin: &str,
    id: &str,
    run_command: &dyn Fn(&str, &[String]) -> AgentCommandResult,
) -> Option<String> {
    let (base, wants_thinking) = split_thinking_suffix(id);
    let (provider, model) = match base.split_once('/') {
        Some((p, m)) => (Some(p), m),
        None => (None, base),
    };
    let r = run_command(bin, &["--list-models".into(), model.into()]);
    if !r.ok {
        let err = command_err("pi", &r, &format!("--list-models {model}"));
        return Some(format!("model {id} list-models check failed: {err}"));
    }
    let mut found_thinking: Option<String> = None;
    for line in r.stdout.lines() {
        let line = line.trim_end_matches('\r');
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 5 {
            continue;
        }
        if cols[0].eq_ignore_ascii_case("provider") {
            continue;
        }
        let provider_ok = provider.is_none_or(|p| cols[0] == p);
        if provider_ok && cols[1] == model {
            found_thinking = Some(cols[4].to_string());
            break;
        }
    }
    match found_thinking {
        None => Some(format!("model {id} not found in pi --list-models")),
        Some(t) if wants_thinking && !t.eq_ignore_ascii_case("yes") => Some(format!(
            "model {id} does not support thinking (pi --list-models reports thinking {t})"
        )),
        _ => None,
    }
}

pub(crate) fn probe_version(
    bin: &str,
    run_command: &dyn Fn(&str, &[String]) -> AgentCommandResult,
) -> (Option<String>, Option<String>) {
    let r = run_command(bin, &["--version".into()]);
    if !r.ok {
        return (None, Some(command_err("pi", &r, "--version")));
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Config, HostProfile, ModelEntry, Price};
    use std::collections::HashMap;

    fn config_with_pi_ids(ids: &[&str]) -> Config {
        let mut models: HashMap<String, ModelEntry> = HashMap::new();
        for id in ids {
            models.insert(
                (*id).into(),
                ModelEntry {
                    label: (*id).into(),
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
        }
        let default = ids.first().unwrap_or(&"openai/gpt-6-luna").to_string();
        Config {
            default,
            price_map: models.iter().map(|(k, v)| (k.clone(), v.price)).collect(),
            models,
            profile: HostProfile::default(),
        }
    }

    fn config_with_pi() -> Config {
        config_with_pi_ids(&["openai/gpt-6-luna"])
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

    const LIST_HEADER: &str = "provider      model         context  max-out  thinking  images\n";
    const LUNA_ROW: &str = "openai        gpt-6-luna    272K     128K     yes       yes\n";
    const LUNA_PREV_ROW: &str = "openai        gpt-5.6-luna  272K     128K     yes       yes\n";
    const NO_THINK_ROW: &str = "openai        gpt-6-luna    272K     128K     no        yes\n";

    /// Injected `run_command`: auth checks always pass; list-models output
    /// is canned per query model.
    fn run_with_list(
        list: std::collections::HashMap<String, String>,
    ) -> impl Fn(&str, &[String]) -> AgentCommandResult {
        move |_: &str, args: &[String]| {
            if args == ["--version"] {
                return ok_result("1.0.0\n");
            }
            if args.len() == 4 && args[0] == "auth" {
                return ok_result("ready\n");
            }
            assert_eq!(args.len(), 2, "unexpected args: {args:?}");
            assert_eq!(args[0], "--list-models", "unexpected args: {args:?}");
            match list.get(&args[1]) {
                Some(out) => ok_result(out),
                None => panic!("unexpected --list-models query: {}", args[1]),
            }
        }
    }

    fn model_failures_for(
        ids: &[&str],
        run: &(dyn Fn(&str, &[String]) -> AgentCommandResult + Sync),
    ) -> Vec<String> {
        let config = config_with_pi_ids(ids);
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/pi".into()),
            bin_exists: Some(&|_| true),
            run_command: Some(run),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        report
            .sections
            .iter()
            .find(|s| s.backend == "pi")
            .expect("pi section")
            .model_failures
            .clone()
    }

    #[test]
    fn fill_present_model_has_no_failures() {
        let list = std::collections::HashMap::from([(
            "gpt-6-luna".to_string(),
            format!("{LIST_HEADER}{LUNA_PREV_ROW}{LUNA_ROW}"),
        )]);
        let run = run_with_list(list);
        let failures = model_failures_for(&["openai/gpt-6-luna"], &run);
        assert!(failures.is_empty(), "{failures:?}");
    }

    #[test]
    fn fill_missing_model_is_a_warning() {
        let list = std::collections::HashMap::from([(
            "no-such-model".to_string(),
            "No models matching \"no-such-model\"\n".to_string(),
        )]);
        let run = run_with_list(list);
        let failures = model_failures_for(&["openai/no-such-model"], &run);
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert!(
            failures[0].contains("model openai/no-such-model not found in pi --list-models"),
            "{}",
            failures[0]
        );
    }

    #[test]
    fn fill_fuzzy_near_miss_is_a_warning() {
        // The query is fuzzy: pi returns gpt-5.6-luna rows for a gpt-6-luna
        // query when the exact model is gone. No exact provider/model row.
        let list = std::collections::HashMap::from([(
            "gpt-6-luna".to_string(),
            format!("{LIST_HEADER}{LUNA_PREV_ROW}"),
        )]);
        let run = run_with_list(list);
        let failures = model_failures_for(&["openai/gpt-6-luna"], &run);
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert!(
            failures[0].contains("not found in pi --list-models"),
            "{}",
            failures[0]
        );
    }

    #[test]
    fn fill_suffixed_id_on_thinking_model_passes() {
        let list = std::collections::HashMap::from([(
            "gpt-6-luna".to_string(),
            format!("{LIST_HEADER}{LUNA_ROW}"),
        )]);
        let run = run_with_list(list);
        let failures = model_failures_for(&["openai/gpt-6-luna:xhigh"], &run);
        assert!(failures.is_empty(), "{failures:?}");
    }

    #[test]
    fn fill_suffixed_id_on_non_thinking_model_is_a_warning() {
        let list = std::collections::HashMap::from([(
            "gpt-6-luna".to_string(),
            format!("{LIST_HEADER}{NO_THINK_ROW}"),
        )]);
        let run = run_with_list(list);
        let failures = model_failures_for(&["openai/gpt-6-luna:xhigh"], &run);
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert!(
            failures[0].contains("does not support thinking"),
            "{}",
            failures[0]
        );
    }

    #[test]
    fn fill_native_colon_id_matches_whole() {
        // `openrouter/llama-4-maverick:free` is a native colon id, not a
        // thinking suffix: the whole id is matched and no thinking level
        // is required, even though the row reports thinking no.
        const ROW: &str = "openrouter  llama-4-maverick:free  1.1M  128K  no  yes\n";
        let list = std::collections::HashMap::from([(
            "llama-4-maverick:free".to_string(),
            format!("{LIST_HEADER}{ROW}"),
        )]);
        let run = run_with_list(list);
        let failures = model_failures_for(&["openrouter/llama-4-maverick:free"], &run);
        assert!(failures.is_empty(), "{failures:?}");
    }

    #[test]
    fn fill_native_colon_id_with_thinking_suffix_strips_last_segment_only() {
        // Only the trailing `:high` is a thinking level; the remainder
        // `llama-4-maverick:free` is the model, matched exactly with
        // thinking yes required.
        const ROW: &str = "openrouter  llama-4-maverick:free  1.1M  128K  yes  yes\n";
        let list = std::collections::HashMap::from([(
            "llama-4-maverick:free".to_string(),
            format!("{LIST_HEADER}{ROW}"),
        )]);
        let run = run_with_list(list);
        let failures = model_failures_for(&["openrouter/llama-4-maverick:free:high"], &run);
        assert!(failures.is_empty(), "{failures:?}");
    }

    #[test]
    fn fill_ok_and_auth_failure_is_a_warning() {
        let config = config_with_pi();
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/bin/pi".into()),
            bin_exists: Some(&|_| true),
            run_command: Some(&|_: &str, args: &[String]| {
                if args == ["--version"] {
                    ok_result("0.99.2\n")
                } else if args.len() == 2 && args[0] == "--list-models" {
                    assert_eq!(args[1], "gpt-6-luna");
                    ok_result(&format!("{LIST_HEADER}{LUNA_ROW}"))
                } else {
                    assert_eq!(args, &["auth", "check", "--model", "openai/gpt-6-luna"]);
                    err_result()
                }
            }),
            read_package_version: None,
        };
        fill(&mut report, &opts);
        assert!(report.failures.is_empty());
        assert!(report.warnings.is_empty());
        let section = report
            .sections
            .iter()
            .find(|s| s.backend == "pi")
            .expect("pi section");
        assert_eq!(section.model_failures.len(), 1);
        let (text, failed) = lines(&report);
        assert!(!failed);
        assert!(text.contains("ok    pi: pi 0.99.2 (/bin/pi)"), "{text}");
        assert!(
            text.contains("warn  pi: model openai/gpt-6-luna auth check failed: exit 1"),
            "{text}"
        );
    }

    #[test]
    fn fill_missing_binary_is_a_failure() {
        let config = config_with_pi();
        let mut report = DoctorReport::default();
        let opts = RunDoctorOpts {
            config: &config,
            resolve_bin: Some(&|_| "/nowhere/pi".into()),
            bin_exists: Some(&|_| false),
            run_command: None,
            read_package_version: None,
        };
        fill(&mut report, &opts);
        assert_eq!(report.failures.len(), 1);
        let (text, failed) = lines(&report);
        assert!(failed);
        assert!(text.contains("fail  pi: pi not found"), "{text}");
    }

    #[test]
    fn lines_empty_without_a_pi_section() {
        let report = DoctorReport::default();
        assert_eq!(lines(&report), (String::new(), false));
    }
}
