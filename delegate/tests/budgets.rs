//! Wall-clock and supervisor RSS budgets for the `delegate` CLI (debug test build).

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const FAKE_AGENT: &str = r#"#!/bin/sh
printf '%s\n' "$@" > "$(dirname "$0")/argv.txt"
rel="$(dirname "$0")/go"
case "$*" in
  *CANCELME*)
    sleep 300 &
    echo $! > "$(dirname "$0")/grandchild.pid"
    echo $$ > "$(dirname "$0")/agent.pid"
    i=0
    while [ ! -e "$rel" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"late\nSTATUS: DONE","session_id":"s-9"}'
    exit 0
    ;;
esac
case "$*" in
  *SLOW*)
    echo $$ > "$(dirname "$0")/agent.pid"
    i=0
    while [ ! -e "$rel" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    ;;
esac
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"391\nSTATUS: DONE","session_id":"s-1"}'
"#;

const ABOUT: &str = "\
About Cursor CLI

CLI Version         2026.09.28-64d2043
Model               Composer 2.5
Subscription Tier   Pro
User Email          alice@example.com";

const FULL_LIST: &str = "composer-2.5 grok-4.7-high grok-4.7-xhigh";

const CLAUDE_FAKE: &str = include_str!("support/claude_fake.sh");

fn info_agent_script() -> String {
    format!(
        r#"#!/bin/sh
case "$1" in
  --version) echo "2026.09.28-64d2043" ;;
  about) printf '%s\n' "{ABOUT}" ;;
  models|--list-models) printf '%s\n' {FULL_LIST} ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#
    )
}

const FAKE_PI: &str = r#"#!/bin/sh
case "$1" in
  --version) echo "0.99.2" ;;
  auth) exit 0 ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#;

const FAKE_FIBER: &str = r#"#!/bin/sh
case "$1" in
  version) echo "0.0.0" ;;
  models) echo '{"model":"opencode-go/muse-spark-1.3-contributor","context_window":1048576,"input":0.1,"output":0.2,"default":false}' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#;

const FAKE_CODEX: &str = r#"#!/bin/sh
case "$1" in
  --version) echo "codex-cli 0.160.0" ;;
  login)
    if [ "$2" = "status" ]; then echo "Logged in using ChatGPT"; else echo "unexpected: $*" >&2; exit 1; fi ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#;

const RUN_BUDGET_MS: u128 = 102; // measured: 34ms on M-series Mac, budget 3x
const RESUME_BUDGET_MS: u128 = 93; // measured: 31ms on M-series Mac, budget 3x
const CANCEL_BUDGET_MS: u128 = 192; // measured: 64ms on M-series Mac, budget 3x
const WATCH_BUDGET_MS: u128 = 50; // measured: 2ms on M-series Mac; 50ms floor, since 3x a spawn-dominated time flakes on CI
const DOCTOR_BUDGET_MS: u128 = 123; // measured: max 41ms over 10 warm runs, budget 3x (#596)
const MODELS_BUDGET_MS: u128 = 50; // measured: 2ms on M-series Mac; 50ms floor, since 3x a spawn-dominated time flakes on CI
const SUPERVISOR_RSS_BUDGET_KB: u64 = 8736; // measured: 2912KB on M-series Mac, budget 3x

/// Wall-clock and RSS samples are not meaningful when these tests run in parallel.
static BUDGET_SERIAL: Mutex<()> = Mutex::new(());

fn serial_budgets(f: impl FnOnce()) {
    let _guard = BUDGET_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    f();
}

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str, agent_script: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("cdm-budget-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let agent = dir.join("agent.sh");
        std::fs::write(&agent, agent_script).unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
        let pi = dir.join("pi.sh");
        std::fs::write(&pi, FAKE_PI).unwrap();
        std::fs::set_permissions(&pi, std::fs::Permissions::from_mode(0o755)).unwrap();
        let claude = dir.join("claude.sh");
        std::fs::write(&claude, CLAUDE_FAKE).unwrap();
        std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
        let fiber = dir.join("fiber.sh");
        std::fs::write(&fiber, FAKE_FIBER).unwrap();
        std::fs::set_permissions(&fiber, std::fs::Permissions::from_mode(0o755)).unwrap();
        let codex = dir.join("codex.sh");
        std::fs::write(&codex, FAKE_CODEX).unwrap();
        std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
        Env { dir }
    }

    fn release(&self) {
        std::fs::write(self.dir.join("go"), "").unwrap();
    }

    fn until_agent_spawned(&self) {
        let t = Instant::now();
        while !(self.dir.join("agent.pid").exists() && self.dir.join("grandchild.pid").exists()) {
            assert!(
                t.elapsed() < Duration::from_secs(10),
                "timed out waiting for CANCELME agent"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn until_agent_pid(&self) {
        until("agent.pid", || self.dir.join("agent.pid").exists());
    }

    fn cleanup_fake_children(&self) {
        for name in ["grandchild.pid", "agent.pid"] {
            let path = self.dir.join(name);
            if let Ok(s) = std::fs::read_to_string(&path)
                && let Ok(pid) = s.trim().parse::<i32>()
                && pid > 0
                && alive(pid)
            {
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
        }
    }

    fn delegate(&self, args: &[&str], stdin: Option<&str>) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("CURSOR_AGENT_BIN", self.dir.join("agent.sh"))
            .env("PI_BIN", self.dir.join("pi.sh"))
            .env("CLAUDE_BIN", self.dir.join("claude.sh"))
            .env("FIBER_BIN", self.dir.join("fiber.sh"))
            .env("CODEX_BIN", self.dir.join("codex.sh"))
            .env("DELEGATE_HEARTBEAT_MS", "100");
        if args.first() == Some(&"models") || args.first() == Some(&"doctor") {
            cmd.env(
                "DELEGATE_HOST_PROFILE",
                self.dir.join("nonexistent-profile.json"),
            );
        }
        let mut child = cmd
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

    fn wall_ms(&self, args: &[&str], stdin: Option<&str>) -> (u128, Output) {
        // One throwaway spawn so the timed sample is not paying a cold binary load.
        let _ = self.delegate(&["watch", "nope"], None);
        let start = Instant::now();
        let out = self.delegate(args, stdin);
        (start.elapsed().as_millis(), out)
    }

    fn run_id(&self, prompt: &str) -> String {
        let (ms, out) = self.wall_ms(&["run", "--model", "composer-2.5"], Some(prompt));
        assert!(
            out.status.success(),
            "run failed in {ms}ms: stderr={} stdout={}",
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    fn record(&self, id: &str) -> Value {
        let p = self.dir.join("delegate-jobs").join(format!("{id}.json"));
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn wait_terminal(&self, id: &str) {
        let out = self.delegate(&["watch", id, "--timeout", "15"], None);
        assert_eq!(out.status.code(), Some(0));
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

fn until(what: &str, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < Duration::from_secs(10), "timed out: {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn supervisor_rss_kb(pid: i32) -> u64 {
    let out = Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .expect("ps");
    assert!(
        out.status.success(),
        "ps failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse()
        .expect("rss parse")
}

/// Budgets are ~3x macOS medians; GitHub's Linux runners need 4x more headroom (#31).
/// Wall-clock budgets fail on a loaded machine, so they are asserted only when
/// `DELEGATE_WALL_BUDGETS` is set: CI sets it; set it locally on a quiet machine (#118).
fn assert_wall_ms(cmd: &str, ms: u128, budget: u128) {
    if std::env::var_os("DELEGATE_WALL_BUDGETS").is_none() {
        eprintln!("{cmd} took {ms}ms, budget {budget}ms (not asserted; set DELEGATE_WALL_BUDGETS)");
        return;
    }
    let budget = if std::env::var_os("CI").is_some() {
        budget * 4
    } else {
        budget
    };
    assert!(ms <= budget, "{cmd} took {ms}ms, budget {budget}ms");
}

#[test]
fn run_exits_within_wall_clock_budget() {
    serial_budgets(|| {
        let e = Env::new("run", FAKE_AGENT);
        let (ms, out) = e.wall_ms(&["run", "--model", "composer-2.5"], Some("SLOW brief"));
        assert!(
            out.status.success(),
            "stderr={} stdout={}",
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
        assert_eq!(e.record(&id)["status"], "RUNNING");
        assert_wall_ms("run", ms, RUN_BUDGET_MS);
        e.release();
        e.wait_terminal(&id);
    });
}

#[test]
fn resume_exits_within_wall_clock_budget() {
    serial_budgets(|| {
        let e = Env::new("resume", FAKE_AGENT);
        let a = e.run_id("quick");
        e.wait_terminal(&a);
        let (ms, out) = e.wall_ms(&["resume", &a], Some("SLOW follow"));
        assert!(
            out.status.success(),
            "stderr={} stdout={}",
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        let b = String::from_utf8(out.stdout).unwrap().trim().to_string();
        assert_eq!(e.record(&b)["status"], "RUNNING");
        assert_wall_ms("resume", ms, RESUME_BUDGET_MS);
        e.release();
        e.wait_terminal(&b);
    });
}

#[test]
fn cancel_exits_within_wall_clock_budget() {
    serial_budgets(|| {
        let e = Env::new("cancel", FAKE_AGENT);
        let id = e.run_id("CANCELME");
        e.until_agent_spawned();
        assert_eq!(e.record(&id)["status"], "RUNNING");
        let (ms, out) = e.wall_ms(&["cancel", &id], None);
        assert_eq!(
            out.status.code(),
            Some(0),
            "stderr={}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_wall_ms("cancel", ms, CANCEL_BUDGET_MS);
        e.cleanup_fake_children();
    });
}

#[test]
fn watch_terminal_job_within_wall_clock_budget() {
    serial_budgets(|| {
        let e = Env::new("watch", FAKE_AGENT);
        let id = e.run_id("quick");
        e.wait_terminal(&id);
        let (ms, out) = e.wall_ms(&["watch", &id], None);
        assert_eq!(
            out.status.code(),
            Some(0),
            "stderr={}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_wall_ms("watch", ms, WATCH_BUDGET_MS);
    });
}

#[test]
fn doctor_and_models_within_wall_clock_budgets() {
    let info = info_agent_script();
    serial_budgets(|| {
        for (cmd, budget) in [("doctor", DOCTOR_BUDGET_MS), ("models", MODELS_BUDGET_MS)] {
            let e = Env::new(cmd, &info);
            // macOS scans each freshly written fake script on its first exec; time a warm run.
            let _ = e.delegate(&[cmd], None);
            let (ms, out) = e.wall_ms(&[cmd], None);
            if cmd == "doctor" {
                assert_eq!(
                    out.status.code(),
                    Some(0),
                    "doctor: stderr={}",
                    String::from_utf8_lossy(&out.stderr)
                );
            } else {
                assert!(
                    out.status.success(),
                    "models: stderr={}",
                    String::from_utf8_lossy(&out.stderr)
                );
            }
            assert_wall_ms(cmd, ms, budget);
        }
    });
}

#[test]
fn supervisor_rss_while_running_within_budget() {
    serial_budgets(|| {
        let e = Env::new("rss", FAKE_AGENT);
        let id = e.run_id("SLOW");
        until("RUNNING", || e.record(&id)["status"] == "RUNNING");
        e.until_agent_pid();
        let pid = e.record(&id)["supervisorPid"].as_i64().unwrap() as i32;
        let kb = supervisor_rss_kb(pid);
        eprintln!("supervisor rss: {kb}KB");
        assert!(
            kb <= SUPERVISOR_RSS_BUDGET_KB,
            "supervisor rss {kb}KB, budget {SUPERVISOR_RSS_BUDGET_KB}KB"
        );
        e.release();
        e.wait_terminal(&id);
    });
}
