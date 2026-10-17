use super::*;
use crate::doctor::run_doctor;
use crate::types::{Config, HostProfile, ModelEntry, Price};
use std::collections::HashMap;

const ABOUT_FIXTURE: &str = "\
About Cursor CLI\n\
\n\
CLI Version         2026.06.01-abc\n\
Model               Composer 2.5\n\
Subscription Tier   Pro\n\
OS                  darwin (arm64)\n\
User Email          alice@example.com";

const MODELS_FIXTURE: &str = "\
Available models:\n\
composer-2.5 - Composer 2.5\n\
grok-4.7-high - Grok 4.7 High\n\
grok-4.7-xhigh - Grok 4.7 Extra High";

fn stub_run(
    table: HashMap<String, AgentCommandResult>,
) -> impl Fn(&str, &[String]) -> AgentCommandResult {
    move |_bin, args| {
        let key = args.join(" ");
        table.get(&key).cloned().unwrap_or_else(|| AgentCommandResult {
            ok: false,
            stdout: String::new(),
            stderr: String::new(),
            error: Some(format!("unexpected args: {key}")),
        })
    }
}

fn ok_cmd(stdout: &str) -> AgentCommandResult {
    AgentCommandResult {
        ok: true,
        stdout: stdout.to_string(),
        stderr: String::new(),
        error: None,
    }
}
fn fail_cmd(err: &str) -> AgentCommandResult {
    AgentCommandResult {
        ok: false,
        stdout: String::new(),
        stderr: String::new(),
        error: Some(err.into()),
    }
}

fn models_config() -> Config {
    let mut models: HashMap<String, ModelEntry> = HashMap::new();
    models.insert(
        "composer-2.5".into(),
        ModelEntry {
            label: "Composer 2.5".into(),
            backend: "cursor".into(),
            price: Price {
                input: 0.5,
                output: 2.5,
                cache_read: 0.2,
                cache_write: 0.0,
            },
            tiers: vec![],
        },
    );
    models.insert(
        "stale-id".into(),
        ModelEntry {
            label: "Stale".into(),
            backend: "cursor".into(),
            price: Price {
                input: 1.0,
                output: 1.0,
                cache_read: 0.0,
                cache_write: 0.0,
            },
            tiers: vec![],
        },
    );
    models.insert(
        "openai/gpt-6-luna".into(),
        ModelEntry {
            label: "GPT-6 Luna".into(),
            backend: "pi".into(),
            price: Price {
                input: 0.1,
                output: 0.5,
                cache_read: 0.01,
                cache_write: 0.125,
            },
            tiers: vec![],
        },
    );
    models.insert(
        "claude-sonnet-5-5".into(),
        ModelEntry {
            label: "Claude Sonnet 5.5".into(),
            backend: "claude".into(),
            price: Price {
                input: 2.0,
                output: 10.0,
                cache_read: 0.2,
                cache_write: 2.5,
            },
            tiers: vec![],
        },
    );
    Config {
        default: "composer-2.5".into(),
        price_map: models.iter().map(|(k, v)| (k.clone(), v.price)).collect(),
        models,
        profile: HostProfile::default(),
    }
}

#[test]
fn parse_about_extracts() {
    let (email, sub, model) = parse_about(ABOUT_FIXTURE);
    assert_eq!(email.as_deref(), Some("alice@example.com"));
    assert_eq!(sub.as_deref(), Some("Pro"));
    assert_eq!(model.as_deref(), Some("Composer 2.5"));
}

#[test]
fn parse_about_plan_current_model() {
    let (email, sub, model) = parse_about(
        "User Email          bob@corp.io\nPlan                Ultra\nCurrent Model       Grok 4.7 High\n",
    );
    assert_eq!(email.as_deref(), Some("bob@corp.io"));
    assert_eq!(sub.as_deref(), Some("Ultra"));
    assert_eq!(model.as_deref(), Some("Grok 4.7 High"));
}

#[test]
fn parse_about_missing() {
    let (email, sub, model) = parse_about("not logged in\n");
    assert!(email.is_none() && sub.is_none() && model.is_none());
}

#[test]
fn parse_models_list_skips_headers() {
    assert_eq!(
        parse_models_list(MODELS_FIXTURE),
        ["composer-2.5", "grok-4.7-high", "grok-4.7-xhigh"]
    );
}

#[test]
fn parse_models_list_bare_ids() {
    assert_eq!(
        parse_models_list("composer-2.5\ngrok-4.7-high\ngrok-4.7-xhigh\n"),
        ["composer-2.5", "grok-4.7-high", "grok-4.7-xhigh"]
    );
}

#[test]
fn parse_models_list_skips_tip() {
    assert_eq!(
        parse_models_list(
            "Available models\n\ncomposer-2.5 - Composer 2.5\ngrok-4.7-xhigh - Grok 4.7 Extra High\n\nTip: use --model <id> (or /model <id> in interactive mode) to switch.\n",
        ),
        ["composer-2.5", "grok-4.7-xhigh"]
    );
}

#[test]
fn diff_configured() {
    assert_eq!(
        diff_configured_models(
            &[
                "composer-2.5".into(),
                "stale-model".into(),
                "grok-4.7-high".into()
            ],
            &[
                "composer-2.5".into(),
                "grok-4.7-high".into(),
                "extra-account-only".into()
            ],
        ),
        ["stale-model"]
    );
}

#[test]
fn probe_version_ok() {
    let mut t = HashMap::new();
    t.insert("--version".into(), ok_cmd("2026.06.01-abc\n"));
    let run = stub_run(t);
    let (v, e) = probe_agent_version("/fake/cursor-agent", &run);
    assert_eq!(v.as_deref(), Some("2026.06.01-abc"));
    assert!(e.is_none());
}

#[test]
fn probe_version_fail() {
    let mut t = HashMap::new();
    t.insert(
        "--version".into(),
        AgentCommandResult {
            ok: false,
            stdout: String::new(),
            stderr: "boom".into(),
            error: Some("exit 1".into()),
        },
    );
    let run = stub_run(t);
    let (v, e) = probe_agent_version("/fake/cursor-agent", &run);
    assert!(v.is_none());
    let err = e.unwrap();
    assert!(err.contains("exit 1") || err.contains("boom"));
}

#[test]
fn probe_account_ok() {
    let mut t = HashMap::new();
    t.insert("about".into(), ok_cmd(&format!("{ABOUT_FIXTURE}\n")));
    let run = stub_run(t);
    let r = probe_account("/fake/cursor-agent", &run);
    assert!(r.logged_in);
    assert_eq!(r.email.as_deref(), Some("alice@example.com"));
    assert_eq!(r.subscription.as_deref(), Some("Pro"));
    assert_eq!(r.current_model.as_deref(), Some("Composer 2.5"));
    assert!(r.error.is_none());
}

#[test]
fn probe_account_not_logged_in() {
    let mut t = HashMap::new();
    t.insert(
        "about".into(),
        AgentCommandResult {
            ok: false,
            stdout: String::new(),
            stderr: "auth required".into(),
            error: Some("exit 1".into()),
        },
    );
    let run = stub_run(t);
    let fail = probe_account("/fake/cursor-agent", &run);
    assert!(!fail.logged_in);
    assert!(fail.error.is_some());

    let mut t = HashMap::new();
    t.insert("about".into(), ok_cmd("Subscription Tier   Hobby\n"));
    let run = stub_run(t);
    let no_email = probe_account("/fake/cursor-agent", &run);
    assert!(!no_email.logged_in);
    assert!(no_email.email.is_none());
    assert_eq!(no_email.subscription.as_deref(), Some("Hobby"));
}

#[test]
fn probe_model_menu_warns() {
    let mut t = HashMap::new();
    t.insert("models".into(), ok_cmd(&format!("{MODELS_FIXTURE}\n")));
    let run = stub_run(t);
    let r = probe_model_menu(
        "/fake/cursor-agent",
        &[
            "composer-2.5".into(),
            "stale-id".into(),
            "grok-4.7-high".into(),
        ],
        &run,
    );
    assert_eq!(
        r.account_ids.as_ref().unwrap(),
        &[
            "composer-2.5".to_string(),
            "grok-4.7-high".into(),
            "grok-4.7-xhigh".into()
        ]
    );
    assert_eq!(r.missing_from_account, ["stale-id"]);
    assert!(!r.prices_checkable);
    assert!(r.note.to_lowercase().contains("not checkable"));
    assert!(r.error.is_none());
}

#[test]
fn probe_model_menu_fallback() {
    let mut t = HashMap::new();
    t.insert("models".into(), fail_cmd("exit 1"));
    t.insert("--list-models".into(), ok_cmd("composer-2.5\ngrok-4.7-high\n"));
    let run = stub_run(t);
    let r = probe_model_menu(
        "/fake/cursor-agent",
        &["composer-2.5".into(), "missing-one".into()],
        &run,
    );
    assert_eq!(
        r.account_ids.as_ref().unwrap(),
        &["composer-2.5".to_string(), "grok-4.7-high".into()]
    );
    assert_eq!(r.missing_from_account, ["missing-one"]);
}

#[test]
fn probe_model_menu_both_fail() {
    let mut t = HashMap::new();
    t.insert("models".into(), fail_cmd("exit 1"));
    t.insert("--list-models".into(), fail_cmd("exit 2"));
    let run = stub_run(t);
    let r = probe_model_menu("/fake/cursor-agent", &["composer-2.5".into()], &run);
    assert!(r.account_ids.is_none());
    assert!(r.missing_from_account.is_empty());
    assert!(r.error.is_some());
}

fn composer_only() -> Config {
    let mut c = models_config();
    c.models.retain(|k, _| k == "composer-2.5");
    c
}

#[test]
fn run_doctor_happy_path() {
    let mut t = HashMap::new();
    t.insert("--version".into(), ok_cmd("2026.06.01-abc\n"));
    // The fiber backend joins the same full-doctor run and probes `version`.
    t.insert("version".into(), ok_cmd("0.0.0\n"));
    t.insert("about".into(), ok_cmd(&format!("{ABOUT_FIXTURE}\n")));
    t.insert("models".into(), ok_cmd(&format!("{MODELS_FIXTURE}\n")));
    t.insert(
        "auth check --model openai/gpt-6-luna".into(),
        ok_cmd("authenticated\n"),
    );
    // pi doctor also probes membership via `pi --list-models <model>`.
    t.insert(
        "--list-models gpt-6-luna".into(),
        ok_cmd("provider model context max-out thinking images\nopenai gpt-6-luna 272K 128K yes yes\n"),
    );
    let run = stub_run(t);
    let cfg = models_config();
    let report = run_doctor(RunDoctorOpts {
        config: &cfg,
        resolve_bin: Some(&|_| "/fake/cursor-agent".into()),
        bin_exists: Some(&|_| true),
        read_package_version: Some(&|| Ok("0.1.0".into())),
        run_command: Some(&run),
    });
    assert!(report.ok);
    assert_eq!(report.plugin.version, "0.1.0");
    assert!(report.agent.found);
    assert_eq!(report.agent.path.as_deref(), Some("/fake/cursor-agent"));
    assert_eq!(report.agent.version.as_deref(), Some("2026.06.01-abc"));
    assert!(report.account.logged_in);
    assert_eq!(report.account.email.as_deref(), Some("alice@example.com"));
    // Only cursor-backend models reach the cursor account list: stale-id warns,
    // while the claude model is never checked. The pi model gets its own
    // `auth check` and passes, so it warns nowhere.
    assert_eq!(report.model_menu.missing_from_account, ["stale-id"]);
    assert!(!report.model_menu.prices_checkable);
    assert!(report.failures.is_empty());
    assert!(report.warnings.iter().any(|w| w.contains("stale-id")));
    assert!(
        !report
            .warnings
            .iter()
            .any(|w| w.contains("gpt-6-luna") || w.contains("sonnet"))
    );
    let pi = report
        .sections
        .iter()
        .find(|s| s.backend == "pi")
        .expect("pi section");
    assert!(pi.found && pi.model_failures.is_empty());
}

#[test]
fn run_doctor_checks_pi_auth_and_ignores_claude() {
    let mut t = HashMap::new();
    t.insert("--version".into(), ok_cmd("2026.06.01-abc\n"));
    // The fiber backend joins the same full-doctor run and probes `version`.
    t.insert("version".into(), ok_cmd("0.0.0\n"));
    t.insert("about".into(), ok_cmd(&format!("{ABOUT_FIXTURE}\n")));
    t.insert("models".into(), ok_cmd("composer-2.5 - Composer 2.5\n"));
    t.insert(
        "auth check --model openai/gpt-6-luna".into(),
        ok_cmd("authenticated\n"),
    );
    // pi doctor also probes membership via `pi --list-models <model>`.
    t.insert(
        "--list-models gpt-6-luna".into(),
        ok_cmd("provider model context max-out thinking images\nopenai gpt-6-luna 272K 128K yes yes\n"),
    );
    let run = stub_run(t);
    let mut cfg = models_config();
    cfg.models.remove("stale-id");
    let report = run_doctor(RunDoctorOpts {
        config: &cfg,
        resolve_bin: Some(&|_| "/fake/cursor-agent".into()),
        bin_exists: Some(&|_| true),
        read_package_version: Some(&|| Ok("0.1.0".into())),
        run_command: Some(&run),
    });
    assert!(report.ok);
    assert!(report.model_menu.missing_from_account.is_empty());
    assert!(report.warnings.is_empty());
    // pi ran its per-model auth check. Claude skips this resolve_bin seam
    // (it would otherwise probe cursor-agent).
    assert!(report.sections.iter().any(|s| s.backend == "pi"));
    assert!(!report.sections.iter().any(|s| s.backend == "claude"));
}

#[test]
fn run_doctor_missing_bin() {
    let cfg = models_config();
    let report = run_doctor(RunDoctorOpts {
        config: &cfg,
        resolve_bin: Some(&|_| "/missing/cursor-agent".into()),
        bin_exists: Some(&|_| false),
        read_package_version: Some(&|| Ok("0.1.0".into())),
        run_command: Some(&|_, _| panic!("runCommand must not be called when bin is missing")),
    });
    assert!(!report.ok && !report.agent.found);
    assert!(
        report
            .failures
            .iter()
            .any(|f| f.to_lowercase().contains("not found"))
    );
    assert!(!report.account.logged_in);
    assert!(report.model_menu.account_ids.is_none());
}

#[test]
fn run_doctor_not_logged_in() {
    let mut t = HashMap::new();
    t.insert("--version".into(), ok_cmd("1.0.0\n"));
    t.insert("about".into(), ok_cmd("Subscription Tier   Hobby\n"));
    t.insert("models".into(), ok_cmd("composer-2.5 - Composer 2.5\n"));
    let run = stub_run(t);
    let cfg = composer_only();
    let report = run_doctor(RunDoctorOpts {
        config: &cfg,
        resolve_bin: Some(&|_| "/fake/cursor-agent".into()),
        bin_exists: Some(&|_| true),
        read_package_version: Some(&|| Ok("0.1.0".into())),
        run_command: Some(&run),
    });
    assert!(!report.ok && !report.account.logged_in);
    assert!(
        report
            .failures
            .iter()
            .any(|f| f.to_lowercase().contains("not logged in"))
    );
}

#[test]
fn run_doctor_model_list_warning() {
    let mut t = HashMap::new();
    t.insert("--version".into(), ok_cmd("1.0.0\n"));
    // The fiber backend joins the same full-doctor run and probes `version`.
    t.insert("version".into(), ok_cmd("0.0.0\n"));
    t.insert("about".into(), ok_cmd(&format!("{ABOUT_FIXTURE}\n")));
    t.insert("models".into(), fail_cmd("exit 1"));
    t.insert("--list-models".into(), fail_cmd("exit 2"));
    let run = stub_run(t);
    let cfg = composer_only();
    let report = run_doctor(RunDoctorOpts {
        config: &cfg,
        resolve_bin: Some(&|_| "/fake/cursor-agent".into()),
        bin_exists: Some(&|_| true),
        read_package_version: Some(&|| Ok("0.1.0".into())),
        run_command: Some(&run),
    });
    assert!(report.ok);
    assert!(report.failures.is_empty());
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.to_lowercase().contains("model"))
    );
}

#[test]
fn run_doctor_without_deep() {
    let mut t = HashMap::new();
    t.insert("--version".into(), ok_cmd("1.0.0\n"));
    // The fiber backend joins the same full-doctor run and probes `version`.
    t.insert("version".into(), ok_cmd("0.0.0\n"));
    t.insert("about".into(), ok_cmd(&format!("{ABOUT_FIXTURE}\n")));
    t.insert("models".into(), ok_cmd("composer-2.5 - Composer 2.5\n"));
    let run = stub_run(t);
    let cfg = composer_only();
    let report = run_doctor(RunDoctorOpts {
        config: &cfg,
        resolve_bin: Some(&|_| "/fake/cursor-agent".into()),
        bin_exists: Some(&|_| true),
        read_package_version: Some(&|| Ok("0.1.0".into())),
        run_command: Some(&run),
    });
    assert!(report.ok);
    assert!(report.model_menu.missing_from_account.is_empty());
}
