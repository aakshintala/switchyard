//! Drives the real `delegate` binary as a process against a fake fiber
//! that replays `tests/fixtures/recorded/fiber/echo.jsonl`.

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

const MODEL: &str = "fiber/opencode-go/muse-spark-1.3-contributor";
const REFERENCE: &str = "opencode-go/muse-spark-1.3-contributor";

const FAKE_FIBER: &str = r#"#!/bin/sh
# Replays a recorded `fiber ask` stream. Every invocation appends its
# argv, so assertions can read it.
{
  printf '%s\n' "$@"
  printf '%s\n' '---'
} >> "$(dirname "$0")/argv.txt"
cat "$DELEGATE_TEST_FIBER_FIXTURE"
exit "$DELEGATE_TEST_FIBER_EXIT"
"#;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str, fixture: &str, exit: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("cdm-fiber-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let agent = dir.join("fiber.sh");
        std::fs::write(&agent, FAKE_FIBER).unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(dir.join("fixture"), fixture).unwrap();
        std::fs::write(dir.join("exit"), exit).unwrap();
        Env { dir }
    }

    fn fixture_path(&self, name: &str) -> PathBuf {
        let base = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
        if name.contains('/') {
            base.join(name)
        } else {
            base.join(format!("recorded/fiber/{name}"))
        }
    }

    /// The appended argv log, split into one invocation per leading `ask` line.
    /// (The prompt itself spans several lines and contains its own `---`, so the
    /// fake's `---` separator cannot delimit invocations.)
    fn invocations(&self) -> Vec<Vec<String>> {
        let mut calls: Vec<Vec<String>> = Vec::new();
        for line in std::fs::read_to_string(self.dir.join("argv.txt"))
            .unwrap()
            .lines()
        {
            if line == "ask" {
                calls.push(Vec::new());
            }
            if let Some(last) = calls.last_mut() {
                last.push(line.to_string());
            }
        }
        calls
    }

    /// Every recorded argv line across all invocations.
    fn argv(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.join("argv.txt"))
            .unwrap()
            .lines()
            .map(String::from)
            .collect()
    }

    /// Like [`delegate`](Self::delegate), but without `FIBER_BIN` and without
    /// `PATH`, and with an isolated `HOME`: resolution falls through to
    /// `$HOME/.local/bin/fiber`, which does not exist under the temp `HOME`.
    /// The jobs dir stays under the temp dir via `TMPDIR`, never the real
    /// `HOME` or `/tmp/delegate-jobs`.
    fn delegate_nobin(&self, args: &[&str], stdin: Option<&str>) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env_remove("CLAUDECODE")
            .env("HOME", &self.dir)
            .env_remove("FIBER_BIN")
            .env_remove("PATH")
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

    fn delegate(&self, args: &[&str], stdin: Option<&str>, fixture: &str, exit: &str) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env_remove("CLAUDECODE")
            .env("FIBER_BIN", self.dir.join("fiber.sh"))
            .env("DELEGATE_TEST_FIBER_FIXTURE", self.fixture_path(fixture))
            .env("DELEGATE_TEST_FIBER_EXIT", exit)
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

    fn run_write(&self, prompt: &str, fixture: &str, exit: &str) -> String {
        let out = self.delegate(&["run", "--model", MODEL], Some(prompt), fixture, exit);
        assert!(
            out.status.success(),
            "exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    fn wait_terminal(&self, id: &str, fixture: &str, exit: &str) -> Value {
        let out = self.delegate(&["watch", id, "--timeout", "10"], None, fixture, exit);
        assert_eq!(out.status.code(), Some(0));
        serde_json::from_slice(&out.stdout).unwrap()
    }

    fn record(&self, id: &str) -> Value {
        let p = self.dir.join("delegate-jobs").join(format!("{id}.json"));
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn resume_ok(
        &self,
        id: &str,
        extra: &[&str],
        stdin: &str,
        fixture: &str,
        exit: &str,
    ) -> String {
        let mut args: Vec<&str> = vec!["resume", id];
        args.extend(extra);
        let out = self.delegate(&args, Some(stdin), fixture, exit);
        assert!(
            out.status.success(),
            "exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn fiber_run_finishes_with_fiber_reported_cost() {
    let e = Env::new("run", "echo.jsonl", "0");
    let id = e.run_write("Reply with the word DONE.", "echo.jsonl", "0");
    assert_eq!(id.len(), 36);
    let done = e.wait_terminal(&id, "echo.jsonl", "0");
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["text"], "DONE");
    assert_eq!(done["result"]["backend"], "fiber");
    assert_eq!(done["result"]["model"], MODEL);
    // Cost is fiber's own reported sum, not a table estimate.
    let cost = done["result"]["costUsd"].as_f64().unwrap();
    assert!((cost - 0.000603378).abs() < 1e-12, "{cost}");
    assert_eq!(done["result"]["costEstimated"], false);

    // Fiber mints the session id; the stream's id is what the record carries.
    assert_eq!(done["resume"]["sessionId"], "s_36e63d22c39750e1");

    let argv = e.argv();
    assert!(argv.contains(&"ask".to_string()), "{argv:?}");
    assert!(
        argv.windows(2).any(|w| w == ["--model", REFERENCE]),
        "{argv:?}"
    );
    // The prompt goes after a `--` separator so a leading `-` never parses as a flag.
    let dash = argv.iter().position(|a| a == "--").expect("separator");
    assert!(
        argv[dash + 1..]
            .iter()
            .any(|a| a.contains("Reply with the word DONE.")),
        "{argv:?}"
    );
    assert!(!argv.iter().any(|a| a == "--resume"), "{argv:?}");
    assert!(!argv.iter().any(|a| a.starts_with("fiber/")), "{argv:?}");
}

#[test]
fn fiber_missing_binary_is_an_error_record_naming_every_source() {
    let e = Env::new("nobin", "echo.jsonl", "0");
    assert!(
        !e.dir.join(".local/bin/fiber").exists(),
        "no binary at the fallback under the isolated HOME"
    );
    let out = e.delegate_nobin(&["run", "--model", MODEL], Some("Reply with DONE."));
    assert!(
        out.status.success(),
        "exit {:?}\nstderr: {}\nstdout: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    assert_eq!(id.len(), 36);

    // A failed job still exits 0 on `watch`; the error lives in the record.
    let out = e.delegate_nobin(&["watch", &id, "--timeout", "10"], None);
    assert_eq!(out.status.code(), Some(0));
    assert!(
        out.stderr.is_empty(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let rec: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(rec["status"], "ERROR");
    assert_eq!(rec["result"]["backend"], "fiber");
    let text = rec["result"]["text"].as_str().unwrap_or("");
    assert!(text.contains("fiber binary not found"), "{text}");
    assert!(text.contains("FIBER_BIN"), "{text}");
    assert!(text.contains("PATH"), "{text}");
    assert!(text.contains("~/.local/bin/fiber"), "{text}");
    let selected = e
        .dir
        .join(".local/bin/fiber")
        .to_string_lossy()
        .into_owned();
    assert!(text.contains(&selected), "{text}");
}

#[test]
fn fiber_badmodel_is_an_error() {
    let e = Env::new("badmodel", "badmodel.jsonl", "1");
    let id = e.run_write("anything", "badmodel.jsonl", "1");
    let done = e.wait_terminal(&id, "badmodel.jsonl", "1");
    assert_eq!(done["status"], "ERROR");
    assert_eq!(done["result"]["backend"], "fiber");
    assert_eq!(done["result"]["model"], MODEL);
    let text = done["result"]["text"].as_str().unwrap_or("");
    assert!(text.contains("nope"), "{text}");
}

#[test]
fn fiber_needs_context_resume_continues_the_session() {
    let nc = "contract/fiber/needs-context.jsonl";
    let e = Env::new("nc-resume", nc, "0");
    let id = e.run_write("Which codeword should I use?", nc, "0");
    let first = e.wait_terminal(&id, nc, "0");
    assert_eq!(first["status"], "NEEDS_CONTEXT");
    assert_eq!(first["resume"]["sessionId"], "s_36e63d22c39750e1");

    let b = e.resume_ok(&id, &[], "the answer", "resume.jsonl", "0");
    assert_eq!(b.len(), 36);
    let done = e.wait_terminal(&b, "resume.jsonl", "0");
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resume"]["sessionId"], first["resume"]["sessionId"]);
    assert_eq!(done["resumedFrom"], id.as_str());

    let calls = e.invocations();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(!calls[0].iter().any(|a| a == "--resume"), "{calls:?}");
    assert!(
        calls[1]
            .windows(2)
            .any(|w| w == ["--resume", "s_36e63d22c39750e1"]),
        "{calls:?}"
    );
    let dash = calls[1].iter().position(|a| a == "--").expect("separator");
    assert!(
        calls[1][dash + 1..]
            .iter()
            .any(|a| a.contains("the answer")),
        "{calls:?}"
    );
}

#[test]
fn fiber_gate_failure_resume_repairs_in_the_session() {
    let e = Env::new("gate-resume", "echo.jsonl", "0");
    let gate = "grep -q -- --resume argv.txt";
    let out = e.delegate(
        &["run", "--model", MODEL, "--gate", gate],
        Some("Reply with the word DONE."),
        "echo.jsonl",
        "0",
    );
    assert!(
        out.status.success(),
        "exit {:?}\nstderr: {}\nstdout: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let first = e.wait_terminal(&id, "echo.jsonl", "0");
    assert_eq!(first["status"], "DONE_WITH_CONCERNS");
    assert_eq!(first["result"]["gateResult"]["passed"], false);

    // No `--gate` flag: resume inherits the stored gate and reruns it.
    let b = e.resume_ok(&id, &[], "Reply with the word AGAIN.", "resume.jsonl", "0");
    let done = e.wait_terminal(&b, "resume.jsonl", "0");
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["gateResult"]["passed"], true);
    assert_eq!(done["result"]["gateResult"]["command"], gate);
    assert_eq!(done["resume"]["sessionId"], first["resume"]["sessionId"]);
    assert_eq!(done["resumedFrom"], id.as_str());

    let calls = e.invocations();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(
        calls[1]
            .windows(2)
            .any(|w| w == ["--resume", "s_36e63d22c39750e1"]),
        "{calls:?}"
    );
}

/// Rewrite one record file in place; the job is terminal so nobody else
/// writes it.
fn rewrite_record(e: &Env, id: &str, f: impl FnOnce(&mut Value)) {
    let p = e.dir.join("delegate-jobs").join(format!("{id}.json"));
    let mut rec: Value = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
    f(&mut rec);
    std::fs::write(&p, serde_json::to_string(&rec).unwrap()).unwrap();
}

/// A Fiber job killed before Fiber's first output line has no session id;
/// an explicit resume runs it fresh instead of refusing it.
#[test]
fn fiber_resume_without_a_session_id_runs_fresh() {
    let e = Env::new("nors-fresh", "/dev/null", "1");
    let id = e.run_write("Reply with the word DONE.", "/dev/null", "1");
    let first = e.wait_terminal(&id, "/dev/null", "1");
    assert_eq!(first["status"], "ERROR");
    assert!(
        first["resume"]["sessionId"].is_null(),
        "{}",
        first["resume"]["sessionId"]
    );

    let b = e.resume_ok(&id, &[], "try again", "resume.jsonl", "0");
    assert_eq!(b.len(), 36);
    let done = e.wait_terminal(&b, "resume.jsonl", "0");
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resumedFrom"], id.as_str());
    assert_eq!(done["resume"]["model"], MODEL);
    assert_eq!(done["resume"]["cwd"], first["resume"]["cwd"]);
    assert_eq!(done["resume"]["gate"], first["resume"]["gate"]);
    assert_eq!(e.record(&id)["supersededBy"], b.as_str());

    let calls = e.invocations();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(
        !calls.iter().any(|c| c.iter().any(|a| a == "--resume")),
        "{calls:?}"
    );
    let dash = calls[1].iter().position(|a| a == "--").expect("separator");
    assert!(
        calls[1][dash + 1..].iter().any(|a| a.contains("try again")),
        "{calls:?}"
    );
}

/// A cancelled record with no session id stays refused on explicit resume.
#[test]
fn fiber_resume_of_a_cancelled_record_without_a_session_id_stays_refused() {
    let e = Env::new("nors-cancel", "/dev/null", "1");
    let id = e.run_write("Reply with the word DONE.", "/dev/null", "1");
    let first = e.wait_terminal(&id, "/dev/null", "1");
    assert_eq!(first["status"], "ERROR");
    assert!(
        first["resume"]["sessionId"].is_null(),
        "{}",
        first["resume"]["sessionId"]
    );
    rewrite_record(&e, &id, |rec| {
        rec["status"] = Value::String("CANCELLED".into());
    });

    let out = e.delegate(&["resume", &id], Some("try again"), "resume.jsonl", "0");
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("no session id"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(e.invocations().len(), 1);
    assert!(
        e.record(&id).get("supersededBy").is_none(),
        "{}",
        e.record(&id)
    );
}

/// An empty session id counts as absent: the explicit resume runs fresh.
#[test]
fn fiber_resume_with_an_empty_session_id_runs_fresh() {
    let e = Env::new("nors-empty", "/dev/null", "1");
    let id = e.run_write("Reply with the word DONE.", "/dev/null", "1");
    let first = e.wait_terminal(&id, "/dev/null", "1");
    assert_eq!(first["status"], "ERROR");
    rewrite_record(&e, &id, |rec| {
        rec["resume"]["sessionId"] = Value::String(String::new());
    });

    let b = e.resume_ok(&id, &[], "try again", "resume.jsonl", "0");
    assert_eq!(b.len(), 36);
    let done = e.wait_terminal(&b, "resume.jsonl", "0");
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resumedFrom"], id.as_str());

    let calls = e.invocations();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(
        !calls.iter().any(|c| c.iter().any(|a| a == "--resume")),
        "{calls:?}"
    );
}

/// A whitespace-only session id counts as absent: the resume runs fresh.
#[test]
fn fiber_resume_with_a_whitespace_session_id_runs_fresh() {
    let e = Env::new("nors-blank", "/dev/null", "1");
    let id = e.run_write("Reply with the word DONE.", "/dev/null", "1");
    let first = e.wait_terminal(&id, "/dev/null", "1");
    assert_eq!(first["status"], "ERROR");
    rewrite_record(&e, &id, |rec| {
        rec["resume"]["sessionId"] = Value::String("   ".into());
    });

    let b = e.resume_ok(&id, &[], "try again", "resume.jsonl", "0");
    assert_eq!(b.len(), 36);
    let done = e.wait_terminal(&b, "resume.jsonl", "0");
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resumedFrom"], id.as_str());

    let calls = e.invocations();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(
        !calls.iter().any(|c| c.iter().any(|a| a == "--resume")),
        "{calls:?}"
    );
}
