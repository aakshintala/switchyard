//! Drives `delegate` against a fake `claude` that replays a recorded fixture.

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const FAKE: &str = r#"#!/bin/sh
dir=$(dirname "$0")
n=$(cat "$dir/count" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s' "$n" > "$dir/count"
{
  printf '%s\n' "$@"
  printf '\n'
} > "$dir/argv.$n"
if [ -p "$dir/release" ]; then
  echo $$ > "$dir/agent.pid"
  cat "$dir/release" >/dev/null
fi
cat "$dir/fixture.stdout"
exit "$(cat "$dir/fixture.exit")"
"#;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("cdm-claude-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let claude = dir.join("claude.sh");
        std::fs::write(&claude, FAKE).unwrap();
        std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
        let src = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/contract/claude/plan-plain-answer.stdout");
        std::fs::copy(src, dir.join("fixture.stdout")).unwrap();
        std::fs::write(dir.join("fixture.exit"), "0\n").unwrap();
        Env { dir }
    }

    /// Cancel holds the fake here. A fifo blocks `cat` with no sleep.
    fn hold(&self) {
        let status = Command::new("mkfifo")
            .arg(self.dir.join("release"))
            .status()
            .unwrap();
        assert!(status.success());
    }

    /// The argv text of every run, in order (one `argv.<n>` file per run).
    fn invocations(&self) -> Vec<String> {
        let mut runs = Vec::new();
        let mut n = 1u32;
        while let Ok(text) = std::fs::read_to_string(self.dir.join(format!("argv.{n}"))) {
            runs.push(text);
            n += 1;
        }
        runs
    }

    /// The argv text of the latest run.
    fn last_argv(&self) -> String {
        self.invocations().pop().expect("no argv record yet")
    }

    fn delegate(&self, args: &[&str], stdin: Option<&str>) -> Output {
        let mut child = Command::new(env!("CARGO_BIN_EXE_delegate"))
            .args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("CLAUDE_BIN", self.dir.join("claude.sh"))
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

    fn ok(&self, args: &[&str], prompt: &str) -> String {
        let out = self.delegate(args, Some(prompt));
        assert!(
            out.status.success(),
            "exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    fn record(&self, id: &str) -> Value {
        let p = self.dir.join("delegate-jobs").join(format!("{id}.json"));
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn wait_terminal(&self, id: &str) -> Value {
        let out = self.delegate(&["watch", id, "--timeout", "10"], None);
        assert_eq!(
            out.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        if let Ok(s) = std::fs::read_to_string(self.dir.join("agent.pid"))
            && let Ok(pid) = s.trim().parse::<i32>()
            && pid > 0
        {
            let _ = Command::new("kill")
                .args(["-9", &pid.to_string()])
                .stderr(Stdio::null())
                .status();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn until(what: &str, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < Duration::from_secs(10), "timed out: {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn run_watch_resume_and_auto_argv() {
    let e = Env::new("run");
    let id = e.ok(&["run", "--model", "claude-sonnet-5-5"], "What is 17 * 23?");
    assert_eq!(id.len(), 36);
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["text"], "391\n\nSTATUS: DONE");
    assert_eq!(done["result"]["costEstimated"], false);
    assert_eq!(
        done["resume"]["sessionId"],
        "25dddfc3-4271-4019-9de0-6795bd6483fa"
    );
    let argv = e.last_argv();
    assert!(argv.contains("\n--permission-mode\nauto\n"), "{argv}");
    assert!(!argv.contains("--resume"), "{argv}");

    let next = e.ok(&["resume", &id], "and plus one?");
    let resumed = e.wait_terminal(&next);
    assert_eq!(resumed["status"], "DONE");
    let argv = e.last_argv();
    assert!(
        argv.contains("\n--resume\n25dddfc3-4271-4019-9de0-6795bd6483fa\n"),
        "{argv}"
    );
}

#[test]
fn stale_argv_record_does_not_leak_into_run_assertion() {
    let e = Env::new("stale");
    // A stale per-run record left by an earlier `--resume` run.
    // Count 1 makes the fake write run 2 to `argv.2`, so the stale record survives.
    std::fs::write(e.dir.join("argv.1"), "--resume\nstale-session\n").unwrap();
    std::fs::write(e.dir.join("count"), "1").unwrap();
    let id = e.ok(&["run", "--model", "claude-sonnet-5-5"], "hi");
    e.wait_terminal(&id);
    // The assertion reads this run's record, not the seeded file.
    let argv = e.last_argv();
    assert!(!argv.contains("--resume"), "{argv}");
}

#[test]
fn cancel_then_resume_reuses_the_launch_session() {
    let e = Env::new("cancel");
    e.hold();
    let id = e.ok(&["run", "--model", "claude-sonnet-5-5"], "hold");
    until("agent.pid", || e.dir.join("agent.pid").exists());
    assert_eq!(e.record(&id)["status"], "RUNNING");
    let sid = argv_flag(&e.last_argv(), "--session-id");
    assert_eq!(e.record(&id)["resume"]["sessionId"], sid.as_str());
    let out = e.delegate(&["cancel", &id], None);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let rec: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(rec["status"], "CANCELLED");
    assert_eq!(rec["result"]["status"], "CANCELLED");
    assert_eq!(rec["resume"]["sessionId"], sid.as_str());
    assert_eq!(e.record(&id)["status"], "CANCELLED");

    // The fifo would hold the resumed fake too. The cancelled agent is already dead.
    let _ = std::fs::remove_file(e.dir.join("release"));
    let next = e.ok(&["resume", &id], "continue");
    let done = e.wait_terminal(&next);
    assert_eq!(done["status"], "DONE");
    assert_eq!(argv_flag(&e.last_argv(), "--resume"), sid);
}

/// Flag values are one argv element per line (`printf '%s\n'`).
fn argv_flag(argv: &str, flag: &str) -> String {
    let lines: Vec<&str> = argv.lines().collect();
    lines
        .windows(2)
        .find(|w| w[0] == flag)
        .unwrap_or_else(|| panic!("no {flag} in {argv}"))[1]
        .to_string()
}

#[test]
fn effort_suffix_runs_and_plain_resume_keeps_it() {
    let e = Env::new("effort-run");
    let id = e.ok(&["run", "--model", "claude-fable-5-1:low"], "hi");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resume"]["model"], "claude-fable-5-1:low");
    let argv = e.last_argv();
    assert_eq!(argv_flag(&argv, "--model"), "claude-fable-5-1", "{argv}");
    assert_eq!(argv_flag(&argv, "--effort"), "low", "{argv}");

    // A plain resume carries the stored suffixed id, so the effort survives.
    let next = e.ok(&["resume", &id], "again");
    assert_eq!(e.wait_terminal(&next)["status"], "DONE");
    assert_eq!(e.record(&next)["resume"]["model"], "claude-fable-5-1:low");
    let tail = e.last_argv();
    assert!(tail.contains("\n--resume\n"), "{tail}");
    assert_eq!(argv_flag(&tail, "--model"), "claude-fable-5-1", "{tail}");
    assert_eq!(argv_flag(&tail, "--effort"), "low", "{tail}");
}

#[test]
fn resume_override_can_add_or_change_effort() {
    let e = Env::new("effort-resume");
    let id = e.ok(&["run", "--model", "claude-sonnet-5-5"], "hi");
    e.wait_terminal(&id);
    let next = e.ok(
        &["resume", &id, "--model", "claude-sonnet-5-5:high"],
        "again",
    );
    assert_eq!(e.wait_terminal(&next)["status"], "DONE");
    assert_eq!(e.record(&next)["resume"]["model"], "claude-sonnet-5-5:high");
    let tail = e.last_argv();
    assert_eq!(argv_flag(&tail, "--model"), "claude-sonnet-5-5", "{tail}");
    assert_eq!(argv_flag(&tail, "--effort"), "high", "{tail}");
}

#[test]
fn bad_effort_level_is_rejected_with_usage() {
    let e = Env::new("effort-bad");
    let out = e.delegate(&["run", "--model", "claude-fable-5-1:bogus"], Some("hi"));
    assert_eq!(out.status.code(), Some(2));
    assert!(
        out.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("claude-fable-5-1:bogus"), "{err}");
    assert!(err.contains("unknown effort level \"bogus\""), "{err}");
    assert!(err.contains("low, medium, high, xhigh, max"), "{err}");

    // A bad level on resume override takes the same shape.
    let id = e.ok(&["run", "--model", "claude-sonnet-5-5"], "hi");
    e.wait_terminal(&id);
    let out = e.delegate(
        &["resume", &id, "--model", "claude-sonnet-5-5:bogus"],
        Some("hi"),
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(
        out.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("claude-sonnet-5-5:bogus"), "{err}");
    assert!(err.contains("unknown effort level \"bogus\""), "{err}");
    assert!(err.contains("low, medium, high, xhigh, max"), "{err}");
}
