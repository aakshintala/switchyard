//! `delegate models` and `delegate doctor` against a fake cursor-agent script.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

const ABOUT: &str = "\
About Cursor CLI

CLI Version         2026.09.28-64d2043
Model               Composer 2.5
Subscription Tier   Pro
User Email          alice@example.com";

fn agent_script(listed: &str) -> String {
    format!(
        r#"#!/bin/sh
case "$1" in
  --version) echo "2026.09.28-64d2043" ;;
  about) printf '%s\n' "{ABOUT}" ;;
  models|--list-models) printf '%s\n' {listed} ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#
    )
}

const FULL_LIST: &str = "composer-2.5 grok-4.7-high grok-4.7-xhigh";
const MISSING_XHIGH: &str = "composer-2.5 grok-4.7-high";

fn pi_script(fail_model: Option<&str>) -> String {
    let auth = match fail_model {
        None => "exit 0".to_string(),
        Some(m) => {
            format!("case \"$*\" in *{m}*) echo \"no such model\" >&2; exit 1 ;; esac\nexit 0")
        }
    };
    // --list-models answers every query with the full bundled pi table; the
    // doctor matches provider/model exactly (and thinking yes for :suffixed
    // ids), so every bundled model resolves.
    let list = "provider model context max-out thinking images\nopenai gpt-6-astra 272K 128K yes yes\nopenai gpt-6-luna 272K 128K yes yes\nopenai gpt-6.1-sol 272K 128K yes yes\nopencode-go muse-spark-1.3-contributor 1.1M 128K yes yes\nopencode-go glm-5.3-flash 1.1M 128K yes yes\nopencode-go deepseek-v4.1-flash 1.1M 128K yes yes";
    format!(
        r#"#!/bin/sh
case "$1" in
  --version) echo "0.99.2" ;;
  auth) {auth} ;;
  --list-models) printf '%s\n' "{list}" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#
    )
}

const CLAUDE_FAKE: &str = include_str!("support/claude_fake.sh");

fn fiber_script() -> String {
    r#"#!/bin/sh
case "$1" in
  version) echo "0.0.0" ;;
  models) printf '%s\n' '{"model":"codex/gpt-6-astra","context_window":272000,"input":10,"output":50,"default":false}' '{"model":"codex/gpt-6.1-sol","context_window":272000,"input":2,"output":10,"default":false}' '{"model":"codex/gpt-6-luna","context_window":272000,"input":0.1,"output":0.5,"default":false}' '{"model":"opencode-go/muse-spark-1.3-contributor","context_window":1048576,"input":0.1,"output":0.2,"default":false}' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#
    .into()
}

fn codex_script() -> String {
    r#"#!/bin/sh
case "$1" in
  --version) echo "codex-cli 0.160.0" ;;
  login)
    if [ "$2" = "status" ]; then echo "Logged in using ChatGPT"; else echo "unexpected: $*" >&2; exit 1; fi ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#
    .into()
}

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str, script: &str) -> Self {
        Self::new_with_pi(name, script, &pi_script(None))
    }

    fn new_with_pi(name: &str, script: &str, pi: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("cdm-info-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let agent = dir.join("agent.sh");
        std::fs::write(&agent, script).unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
        let pi_bin = dir.join("pi.sh");
        std::fs::write(&pi_bin, pi).unwrap();
        std::fs::set_permissions(&pi_bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        let claude = dir.join("claude.sh");
        std::fs::write(&claude, CLAUDE_FAKE).unwrap();
        std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
        let fiber = dir.join("fiber.sh");
        std::fs::write(&fiber, fiber_script()).unwrap();
        std::fs::set_permissions(&fiber, std::fs::Permissions::from_mode(0o755)).unwrap();
        let codex = dir.join("codex.sh");
        std::fs::write(&codex, codex_script()).unwrap();
        std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
        Env { dir }
    }

    fn delegate(&self, args: &[&str], stdin: Option<&str>) -> Output {
        self.delegate_with_bin(args, stdin, &self.dir.join("agent.sh").to_string_lossy())
    }

    fn delegate_with_bin(&self, args: &[&str], stdin: Option<&str>, bin: &str) -> Output {
        self.delegate_with_bins(
            args,
            stdin,
            bin,
            &self.dir.join("codex.sh").to_string_lossy(),
        )
    }

    fn delegate_with_bins(
        &self,
        args: &[&str],
        stdin: Option<&str>,
        cursor_bin: &str,
        codex_bin: &str,
    ) -> Output {
        let mut child = Command::new(env!("CARGO_BIN_EXE_delegate"))
            .args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("CURSOR_AGENT_BIN", cursor_bin)
            .env("PI_BIN", self.dir.join("pi.sh"))
            .env("CLAUDE_BIN", self.dir.join("claude.sh"))
            .env("FIBER_BIN", self.dir.join("fiber.sh"))
            .env("CODEX_BIN", codex_bin)
            // Isolate from the developer machine's real host profile: exact
            // table assertions need the bundled models only.
            .env(
                "DELEGATE_HOST_PROFILE",
                self.dir.join("nonexistent-profile.json"),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut si = child.stdin.take().unwrap();
        if let Some(s) = stdin {
            let _ = si.write_all(s.as_bytes());
        }
        drop(si);
        child.wait_with_output().unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

const SORTED_IDS: [&str; 24] = [
    "claude-fable-5-1",
    "claude-haiku-5-5",
    "claude-opus-5-5",
    "claude-sonnet-5-5",
    "codex/gpt-6-astra",
    "codex/gpt-6-luna",
    "codex/gpt-6-luna:medium",
    "codex/gpt-6-luna:xhigh",
    "codex/gpt-6.1-sol",
    "composer-2.5",
    "grok-4.7-high",
    "grok-4.7-xhigh",
    "fiber/codex/gpt-6-astra",
    "fiber/codex/gpt-6-luna",
    "fiber/codex/gpt-6-luna:medium",
    "fiber/codex/gpt-6.1-sol",
    "fiber/opencode-go/muse-spark-1.3-contributor",
    "openai/gpt-6-astra",
    "openai/gpt-6-luna:medium",
    "openai/gpt-6-luna:xhigh",
    "openai/gpt-6.1-sol",
    "opencode-go/deepseek-v4.1-flash",
    "opencode-go/glm-5.3-flash",
    "opencode-go/muse-spark-1.3-contributor",
];

#[test]
fn help_flags_print_usage_on_stdout_and_exit_0() {
    let e = Env::new("help", &agent_script(FULL_LIST));
    for args in [&["--help"][..], &["-h"][..], &["help"][..]] {
        let out = e.delegate(args, None);
        assert_eq!(
            out.status.code(),
            Some(0),
            "args {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let stdout = String::from_utf8(out.stdout).unwrap();
        assert!(
            stdout.contains("usage: delegate run"),
            "args {args:?}: {stdout:?}"
        );
        assert!(
            stdout.contains("delegate doctor"),
            "args {args:?}: {stdout:?}"
        );
        assert!(
            out.stderr.is_empty(),
            "args {args:?}: stderr {:?}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

#[test]
fn models_lists_every_row_with_default_marked() {
    let e = Env::new("models", &agent_script(FULL_LIST));
    let out = e.delegate(&["models"], None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).unwrap();
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 25, "{stdout}");
    // Compare with spaces shown as · so a width mismatch is debuggable.
    assert_eq!(
        lines[0].replace(' ', "·"),
        "··ID············································LABEL·······························BACKEND··$IN/1M··$OUT/1M··TIERS"
    );
    assert_eq!(
        lines[5].replace(' ', "·"),
        "··codex/gpt-6-astra·····························GPT-6·Astra·(codex)·················codex·····10.00····50.00"
    );
    assert_eq!(
        lines[7].replace(' ', "·"),
        "··codex/gpt-6-luna:medium·······················GPT-6·Luna·(medium,·codex)··········codex······0.10·····0.50"
    );
    assert_eq!(
        lines[10].replace(' ', "·"),
        "*·composer-2.5··································Composer·2.5························cursor·····0.50·····2.50··standard"
    );
    assert_eq!(
        lines[17].replace(' ', "·"),
        "··fiber/opencode-go/muse-spark-1.3-contributor··Muse·Spark·1.3·Contributor·(fiber)··fiber······0.10·····0.20"
    );
    assert_eq!(
        lines[24].replace(' ', "·"),
        "··opencode-go/muse-spark-1.3-contributor········Muse·Spark·1.3·Contributor··········pi·········0.10·····0.20··standard,strong"
    );
    // Rows sort by backend, then by id; only the default row is starred.
    let ids: Vec<&str> = lines[1..]
        .iter()
        .map(|l| l[2..].split_whitespace().next().unwrap())
        .collect();
    assert_eq!(ids, SORTED_IDS);
    assert_eq!(lines.iter().filter(|l| l.starts_with('*')).count(), 1);
}

#[test]
fn doctor_passes_against_full_fake() {
    let e = Env::new("doctor-ok", &agent_script(FULL_LIST));
    let out = e.delegate(&["doctor"], None);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(stdout.contains("ok    delegate 1.0.0"), "{stdout}");
    assert!(
        stdout.contains("ok    cursor: cursor-agent 2026.09.28-64d2043 ("),
        "{stdout}"
    );
    assert!(stdout.contains("ok    cursor: logged in"), "{stdout}");
    assert!(stdout.contains("ok    pi: pi 0.99.2 ("), "{stdout}");
    assert!(!stdout.contains("pi: backend not implemented"), "{stdout}");
    assert!(
        stdout.contains("ok    claude: claude 2.0.0-test ("),
        "{stdout}"
    );
    assert!(stdout.contains("ok    claude: logged in"), "{stdout}");
    assert!(stdout.contains("ok    fiber: fiber 0.0.0 ("), "{stdout}");
    assert!(
        stdout.contains("ok    codex: codex codex-cli 0.160.0 ("),
        "{stdout}"
    );
    assert!(stdout.contains("ok    codex: logged in"), "{stdout}");
    // Codex has no membership probe, so every configured row warns as
    // unchecked, sorted by full row id. Warnings do not fail the doctor.
    for id in [
        "codex/gpt-6-astra",
        "codex/gpt-6-luna",
        "codex/gpt-6-luna:medium",
        "codex/gpt-6-luna:xhigh",
        "codex/gpt-6.1-sol",
    ] {
        assert!(
            stdout.contains(&format!(
                "warn  codex: model {id} not checked: no supported codex membership probe"
            )),
            "{stdout}"
        );
    }
    let warns: Vec<&str> = stdout.lines().filter(|l| l.starts_with("warn")).collect();
    assert_eq!(warns.len(), 5, "{stdout}");
    assert!(!stdout.contains("skip  claude"), "{stdout}");
    assert!(!stdout.lines().any(|l| l.starts_with("fail")), "{stdout}");
}

#[test]
fn doctor_warns_on_missing_model_and_still_exits_0() {
    let e = Env::new("doctor-warn", &agent_script(MISSING_XHIGH));
    let out = e.delegate(&["doctor"], None);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(
        stdout
            .contains("warn  cursor: model grok-4.7-xhigh missing from cursor-agent --list-models"),
        "{stdout}"
    );
    assert!(!stdout.contains("fail"), "{stdout}");
}

#[test]
fn doctor_fails_when_binary_missing() {
    let e = Env::new("doctor-fail", &agent_script(FULL_LIST));
    let out = e.delegate_with_bin(&["doctor"], None, "/nonexistent/cursor-agent-xyz");
    assert_eq!(out.status.code(), Some(1));
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(
        stdout.contains("fail  cursor: cursor-agent not found"),
        "{stdout}"
    );
}

#[test]
fn doctor_fails_when_codex_binary_missing() {
    let e = Env::new("doctor-codex-fail", &agent_script(FULL_LIST));
    let cursor = e.dir.join("agent.sh").to_string_lossy().into_owned();
    let out = e.delegate_with_bins(&["doctor"], None, &cursor, "/nonexistent/codex-xyz");
    assert_eq!(out.status.code(), Some(1));
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(stdout.contains("fail  codex: codex not found"), "{stdout}");
    assert!(stdout.contains("checked override, $CODEX_BIN"), "{stdout}");
}

#[test]
fn doctor_warns_on_pi_model_auth_failure() {
    let e = Env::new_with_pi(
        "doctor-pi-warn",
        &agent_script(FULL_LIST),
        &pi_script(Some("openai/gpt-6.1-sol")),
    );
    let out = e.delegate(&["doctor"], None);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(
        stdout.contains("warn  pi: model openai/gpt-6.1-sol auth check failed"),
        "{stdout}"
    );
    assert!(!stdout.lines().any(|l| l.starts_with("fail")), "{stdout}");
}
