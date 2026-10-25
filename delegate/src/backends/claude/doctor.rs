//! Claude doctor probes: `--version` and `auth status` (`loggedIn`).

use super::resolve_bin;
use crate::cli_info::status_line;
use crate::doctor::{AgentCommandResult, RunDoctorOpts, default_run_agent_command};
use crate::types::{DoctorClaudeInfo, DoctorReport};

pub(crate) fn fill(report: &mut DoctorReport, opts: &RunDoctorOpts<'_>) {
    // `resolve_bin` is the cursor test seam: stubs ignore the argument and return one
    // path. Using it here would point claude at cursor-agent. Production leaves it unset.
    if opts.resolve_bin.is_some() {
        return;
    }
    let path = resolve_bin(None);
    let exists = match opts.bin_exists {
        Some(f) => f(&path),
        None => std::path::Path::new(&path).exists(),
    };
    let run = |args: &[String]| match opts.run_command {
        Some(f) => f(&path, args),
        None => default_run_agent_command(&path, args),
    };
    if !exists {
        let err = format!("claude not found at {path}");
        report.failures.push(err.clone());
        report.claude = Some(DoctorClaudeInfo {
            found: false,
            path: Some(path),
            version: None,
            version_error: Some(err),
            logged_in: false,
            login_error: None,
        });
        return;
    }

    let (version, version_error) = probe_version(&run);
    if let Some(e) = &version_error {
        report
            .failures
            .push(format!("claude --version failed: {e}"));
    }
    let (logged_in, login_error) = probe_login(&run);
    if !logged_in {
        report.failures.push(match &login_error {
            Some(e) => format!("not logged in to claude: {e}"),
            None => "not logged in to claude".into(),
        });
    }
    report.claude = Some(DoctorClaudeInfo {
        found: true,
        path: Some(path),
        version,
        version_error,
        logged_in,
        login_error,
    });
}

pub(crate) fn lines(report: &DoctorReport) -> (String, bool) {
    let Some(info) = &report.claude else {
        return (String::new(), false);
    };
    let mut text = String::new();
    let mut failed = false;
    if !info.found {
        text += &status_line("fail", "claude: claude not found");
        return (text, true);
    }
    let path = info.path.as_deref().unwrap_or("?");
    match info.version.as_deref() {
        Some(v) => {
            text += &status_line("ok", &format!("claude: claude {v} ({path})"));
        }
        None => {
            let e = info.version_error.as_deref().unwrap_or("unknown error");
            text += &status_line("fail", &format!("claude: claude --version failed: {e}"));
            failed = true;
        }
    }
    if info.logged_in {
        text += &status_line("ok", "claude: logged in");
    } else {
        let e = info.login_error.as_deref().unwrap_or("loggedIn is false");
        text += &status_line("fail", &format!("claude: not logged in: {e}"));
        failed = true;
    }
    (text, failed)
}

fn command_err(r: &AgentCommandResult, what: &str) -> String {
    r.error.clone().unwrap_or_else(|| {
        let t = r.stderr.trim();
        if t.is_empty() {
            format!("claude {what} failed")
        } else {
            t.to_string()
        }
    })
}

fn probe_version(
    run: &dyn Fn(&[String]) -> AgentCommandResult,
) -> (Option<String>, Option<String>) {
    let r = run(&["--version".into()]);
    if !r.ok {
        return (None, Some(command_err(&r, "--version")));
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

/// `claude auth status` prints JSON. `loggedIn: true` is logged in.
fn probe_login(run: &dyn Fn(&[String]) -> AgentCommandResult) -> (bool, Option<String>) {
    let r = run(&["auth".into(), "status".into()]);
    if !r.ok {
        return (false, Some(command_err(&r, "auth status")));
    }
    match logged_in_flag(&r.stdout) {
        Ok(true) => (true, None),
        Ok(false) => (false, Some("loggedIn is false".into())),
        Err(e) => (false, Some(e)),
    }
}

#[derive(serde::Deserialize)]
struct AuthStatus {
    #[serde(rename = "loggedIn")]
    logged_in: bool,
}

fn logged_in_flag(stdout: &str) -> Result<bool, String> {
    serde_json::from_str::<AuthStatus>(stdout.trim())
        .map(|s| s.logged_in)
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Config, DoctorClaudeInfo, DoctorReport, HostProfile};

    fn cfg() -> Config {
        Config {
            default: "claude-sonnet-5-5".into(),
            models: std::collections::HashMap::new(),
            price_map: std::collections::HashMap::new(),
            profile: HostProfile::default(),
        }
    }

    fn ok(stdout: &str) -> AgentCommandResult {
        AgentCommandResult {
            ok: true,
            stdout: stdout.into(),
            stderr: String::new(),
            error: None,
        }
    }

    #[test]
    fn logged_in_false_is_a_fail_line() {
        let report = DoctorReport {
            claude: Some(DoctorClaudeInfo {
                found: true,
                path: Some("/fake/claude".into()),
                version: Some("1.2.3".into()),
                version_error: None,
                logged_in: false,
                login_error: Some("loggedIn is false".into()),
            }),
            ..Default::default()
        };
        let (text, failed) = lines(&report);
        assert!(failed);
        assert!(
            text.contains("ok    claude: claude 1.2.3 (/fake/claude)"),
            "{text}"
        );
        assert!(
            text.contains("fail  claude: not logged in: loggedIn is false"),
            "{text}"
        );
    }

    #[test]
    fn probes_version_login_and_a_missing_binary() {
        let _guard = crate::test_env::lock();
        let prev = std::env::var("CLAUDE_BIN").ok();
        unsafe { std::env::set_var("CLAUDE_BIN", "/fake/claude") };
        let config = cfg();

        let run = |bin: &str, args: &[String]| {
            assert_eq!(bin, "/fake/claude");
            match args.join(" ").as_str() {
                "--version" => ok("1.2.3\n"),
                "auth status" => ok("{\"loggedIn\": true}\n"),
                other => panic!("unexpected {other}"),
            }
        };
        let mut report = DoctorReport::default();
        fill(
            &mut report,
            &RunDoctorOpts {
                config: &config,
                resolve_bin: None,
                bin_exists: Some(&|p| p == "/fake/claude"),
                run_command: Some(&run),
                read_package_version: None,
            },
        );
        let info = report.claude.as_ref().unwrap();
        assert!(info.found && info.logged_in);
        assert_eq!(info.version.as_deref(), Some("1.2.3"));
        assert!(report.failures.is_empty());
        let (text, failed) = lines(&report);
        assert!(!failed);
        assert!(text.contains("ok    claude: logged in"), "{text}");

        let run_out = |bin: &str, args: &[String]| {
            assert_eq!(bin, "/fake/claude");
            match args.join(" ").as_str() {
                "--version" => ok("1.2.3\n"),
                "auth status" => ok("{\"loggedIn\": false}\n"),
                other => panic!("unexpected {other}"),
            }
        };
        let mut report = DoctorReport::default();
        fill(
            &mut report,
            &RunDoctorOpts {
                config: &config,
                resolve_bin: None,
                bin_exists: Some(&|_| true),
                run_command: Some(&run_out),
                read_package_version: None,
            },
        );
        assert!(!report.claude.as_ref().unwrap().logged_in);
        assert!(
            report
                .failures
                .iter()
                .any(|f| f.to_lowercase().contains("not logged in"))
        );

        let mut report = DoctorReport::default();
        fill(
            &mut report,
            &RunDoctorOpts {
                config: &config,
                resolve_bin: None,
                bin_exists: Some(&|_| false),
                run_command: Some(&|_, _| panic!("must not run when the binary is missing")),
                read_package_version: None,
            },
        );
        assert!(!report.claude.as_ref().unwrap().found);
        assert!(
            report
                .failures
                .iter()
                .any(|f| f.to_lowercase().contains("not found"))
        );
        let (text, failed) = lines(&report);
        assert!(failed);
        assert!(text.contains("fail  claude: claude not found"), "{text}");

        match prev {
            Some(v) => unsafe { std::env::set_var("CLAUDE_BIN", v) },
            None => unsafe { std::env::remove_var("CLAUDE_BIN") },
        }
    }
}
