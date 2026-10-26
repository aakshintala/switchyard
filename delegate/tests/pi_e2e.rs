//! Drives the real `delegate` binary as a process against a fake pi
//! that replays `tests/fixtures/contract/pi/plain-answer.stdout`.

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const MODEL: &str = "opencode-go/muse-spark-1.3-contributor";

const FAKE_PI: &str = r#"#!/bin/sh
# Replays a recorded `pi -p --mode json` stream. Every invocation writes its
# own argv record, so run + resume assertions can read each run separately.
d="$(dirname "$0")"
n=$(cat "$d/count" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s' "$n" > "$d/count"
{
  printf '%s\n' "$@"
  printf '%s\n' '---'
} > "$d/argv.$n"
rel="$d/go"
# SLOW jobs wait for the release file, so the test can assert RUNNING first.
case "$*" in
  *SLOW*)
    i=0
    while [ ! -e "$rel" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    ;;
esac
# Replay the fixture as this session, like the real pi echoes the id back.
sid=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--session-id" ]; then sid="$a"; fi
  prev="$a"
done
# A fail-once file is the first call's stream; the call consumes it.
fail="$d/fail-once"
if [ -e "$fail" ]; then
  sed "s/a86b4f04-f9fe-4fe2-88f2-9c07c39dda68/$sid/g" "$fail"
  rm "$fail"
  exit 0
fi
sed "s/afcd8926-430b-4d9a-a552-d7c6d1b900ba/$sid/g" "$DELEGATE_TEST_PI_FIXTURE"
"#;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("cdm-pi-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let agent = dir.join("pi.sh");
        std::fs::write(&agent, FAKE_PI).unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
        Env { dir }
    }

    fn fixture(&self) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/contract/pi/plain-answer.stdout")
    }

    /// Lets SLOW jobs finish; until then they stay RUNNING (10s cap).
    fn release(&self) {
        std::fs::write(self.dir.join("go"), "").unwrap();
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
        let fixture = self.fixture();
        self.delegate_with_fixture(args, stdin, &fixture)
    }

    fn delegate_with_fixture(
        &self,
        args: &[&str],
        stdin: Option<&str>,
        fixture: &std::path::Path,
    ) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("PI_BIN", self.dir.join("pi.sh"))
            .env("DELEGATE_TEST_PI_FIXTURE", fixture)
            .env("DELEGATE_HEARTBEAT_MS", "100")
            .env("DELEGATE_RETRY_DELAYS_MS", "0")
            // Isolate from the developer machine's real host profile.
            .env(
                "DELEGATE_HOST_PROFILE",
                self.dir.join("nonexistent-profile.json"),
            );
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

    fn run_write(&self, prompt: &str) -> String {
        let out = self.delegate(&["run", "--model", MODEL], Some(prompt));
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
        let p: PathBuf = self.dir.join("delegate-jobs").join(format!("{id}.json"));
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn wait_terminal(&self, id: &str) -> Value {
        let out = self.delegate(&["watch", id, "--timeout", "10"], None);
        assert_eq!(out.status.code(), Some(0));
        serde_json::from_slice(&out.stdout).unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
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

/// The `--flag` value from one run's argv text (one argv element per line).
fn argv_flag(argv: &str, flag: &str) -> String {
    argv.lines()
        .collect::<Vec<_>>()
        .windows(2)
        .find(|w| w[0] == flag)
        .unwrap_or_else(|| panic!("no {flag} in {argv}"))[1]
        .to_string()
}

#[test]
fn pi_run_finishes_with_pi_reported_cost() {
    let e = Env::new("run");
    let id = e.run_write("What is 17 * 23?");
    assert_eq!(id.len(), 36);
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["text"], "391\nSTATUS: DONE");
    assert_eq!(done["result"]["backend"], "pi");
    assert_eq!(done["result"]["model"], MODEL);
    // Cost is pi's own reported sum, not a table estimate.
    let cost = done["result"]["costUsd"].as_f64().unwrap();
    assert!((cost - 0.0005365).abs() < 1e-12, "{cost}");
    assert_eq!(done["result"]["costEstimated"], false);

    // The session id was chosen before launch: argv's fresh uuid is what the
    // record carries.
    let argv: Vec<String> = e.last_argv().lines().map(String::from).collect();
    let sid = argv
        .windows(2)
        .filter(|w| w[0] == "--session-id")
        .map(|w| w[1].as_str())
        .collect::<Vec<_>>();
    assert_eq!(sid.len(), 1, "{argv:?}");
    assert_eq!(sid[0].len(), 36, "{argv:?}");
    assert!(
        sid[0]
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
        "{argv:?}"
    );
    assert_eq!(done["resume"]["sessionId"], sid[0]);
    assert!(argv.contains(&"-p".to_string()), "{argv:?}");
    assert!(argv.windows(2).any(|w| w == ["--mode", "json"]), "{argv:?}");
    assert!(argv.windows(2).any(|w| w == ["--model", MODEL]), "{argv:?}");
    assert!(
        argv.iter().any(|a| a.contains("What is 17 * 23?")),
        "{argv:?}"
    );
}

#[test]
fn pi_empty_final_message_is_done_with_concerns() {
    // #318: a job whose final message is empty is DONE_WITH_CONCERNS, not DONE.
    let e = Env::new("empty-final");
    let base = std::fs::read_to_string(e.fixture()).unwrap();
    assert!(base.contains("391\\nSTATUS: DONE"));
    let fixture = e.dir.join("empty-final.stdout");
    std::fs::write(&fixture, base.replace("391\\nSTATUS: DONE", "")).unwrap();
    let out = e.delegate_with_fixture(
        &["run", "--model", MODEL],
        Some("What is 17 * 23?"),
        &fixture,
    );
    assert!(
        out.status.success(),
        "exit {:?}\nstderr: {}\nstdout: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE_WITH_CONCERNS");
    assert_eq!(done["result"]["text"], "");
    let concerns = done["result"]["concerns"].as_array().unwrap();
    assert!(
        concerns
            .iter()
            .any(|c| c.as_str().unwrap().contains("empty final message")),
        "{concerns:?}"
    );
}

#[test]
fn pi_empty_final_after_tool_call_on_resume_is_done_with_concerns() {
    // #318: a resume that ends on a tool call with no assistant text is
    // DONE_WITH_CONCERNS, not DONE.
    let e = Env::new("empty-final-resume");
    let a = e.run_write("first brief");
    let first = e.wait_terminal(&a);
    assert_eq!(first["status"], "DONE");
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/pi-tool-call-empty-final.stdout");
    let out = e.delegate_with_fixture(&["resume", &a], Some("follow up"), &fixture);
    assert!(
        out.status.success(),
        "exit {:?}\nstderr: {}\nstdout: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let b = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let done = e.wait_terminal(&b);
    assert_eq!(done["status"], "DONE_WITH_CONCERNS");
    assert_eq!(done["result"]["text"], "");
    let concerns = done["result"]["concerns"].as_array().unwrap();
    assert!(
        concerns
            .iter()
            .any(|c| c.as_str().unwrap().contains("empty final message")),
        "{concerns:?}"
    );
}

#[test]
fn pi_run_stays_running_until_released() {
    let e = Env::new("slow");
    let id = e.run_write("SLOW do it");
    until("RUNNING", || e.record(&id)["status"] == "RUNNING");
    // The fake pi writes argv one line at a time; `---` ends the block.
    until("argv", || {
        std::fs::read_to_string(e.dir.join("argv.1")).is_ok_and(|s| s.lines().any(|l| l == "---"))
    });
    let argv: Vec<String> = e.last_argv().lines().map(String::from).collect();
    let sid = argv.windows(2).find(|w| w[0] == "--session-id").unwrap()[1].clone();
    assert_eq!(e.record(&id)["resume"]["sessionId"], sid.as_str());
    e.release();
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
}

#[test]
fn pi_resume_reuses_the_session_id() {
    let e = Env::new("resume");
    let a = e.run_write("first brief");
    let first = e.wait_terminal(&a);
    assert_eq!(first["status"], "DONE");
    let first_sid = first["resume"]["sessionId"].as_str().unwrap().to_string();

    let out = e.delegate(&["resume", &a], Some("follow up"));
    assert!(out.status.success());
    let b = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let done = e.wait_terminal(&b);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resume"]["sessionId"], first_sid.as_str());
    // Both invocations passed the same --session-id.
    let calls = e.invocations();
    assert_eq!(calls.len(), 2, "{calls:?}");
    let ids: Vec<String> = calls.iter().map(|c| argv_flag(c, "--session-id")).collect();
    assert_eq!(ids[0], ids[1]);
    assert_eq!(ids[1].as_str(), first_sid.as_str());
}

#[test]
fn pi_cancel_kills_the_agent() {
    let e = Env::new("cancel");
    let id = e.run_write("SLOW do it");
    until("RUNNING", || e.record(&id)["status"] == "RUNNING");
    let out = e.delegate(&["cancel", &id], None);
    assert_eq!(out.status.code(), Some(0));
    let final_rec: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(final_rec["status"], "CANCELLED");
    assert_eq!(e.record(&id)["status"], "CANCELLED");
}

#[test]
fn pi_503_is_resumed_on_the_same_session_and_recorded() {
    let e = Env::new("retry");
    // The contract bad-model stream, with its error rewritten to a provider 503.
    let stream = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/contract/pi/error-bad-model.stdout"),
    )
    .unwrap()
    .replace(
        "Codex error: The 'no-such-model' model is not supported when using Codex with a ChatGPT account.",
        "opencode-go API error (503): upstream",
    );
    assert!(stream.contains("opencode-go API error (503): upstream"));
    std::fs::write(e.dir.join("fail-once"), stream).unwrap();

    let id = e.run_write("first brief");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    let retries = done["result"]["retries"].as_array().unwrap();
    assert_eq!(retries.len(), 1, "{done}");
    assert_eq!(retries[0]["attempt"], 1);
    assert_eq!(retries[0]["providerStatus"], 503);
    assert_eq!(retries[0]["error"], "opencode-go API error (503): upstream");

    let calls = e.invocations();
    assert_eq!(calls.len(), 2, "{calls:?}");
    let ids: Vec<String> = calls.iter().map(|c| argv_flag(c, "--session-id")).collect();
    assert_eq!(ids[0], ids[1]);
    assert_eq!(retries[0]["sessionId"], ids[0].as_str());
    assert!(
        calls[1].lines().any(|a| a
            .starts_with("Your previous turn stopped on a transient provider error (HTTP 503).")),
        "{calls:?}"
    );
    // The original brief ran once; the retry resumed instead of rerunning it.
    assert_eq!(
        calls
            .iter()
            .flat_map(|c| c.lines())
            .filter(|a| a.contains("first brief"))
            .count(),
        1,
        "{calls:?}"
    );
}
