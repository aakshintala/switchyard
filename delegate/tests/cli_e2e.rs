//! Drives the real `delegate` binary as a process against a fake cursor-agent.

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const FAKE_AGENT: &str = r#"#!/bin/sh
printf '%s\n' "$@" > "$(dirname "$0")/argv.txt"
printf '%s %s\n' "${FORCE_COLOR-unset}" "${CLICOLOR_FORCE-unset}" > "$(dirname "$0")/color.env"
rel="$(dirname "$0")/go"
# Stays RUNNING behind a grandchild: `sleep` inherits the agent's process group, so
# killing only the agent would leave it behind.
case "$*" in
  *CANCELME*)
    sleep 300 &
    echo $! > "$(dirname "$0")/grandchild.pid"
    echo $$ > "$(dirname "$0")/agent.pid"
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s-init"}'
    i=0
    while [ ! -e "$rel" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"late\nSTATUS: DONE","session_id":"s-9"}'
    exit 0
    ;;
esac
# Silent jobs emit nothing, so the model-idle window is what kills them.
case "$*" in
  *SILENT*)
    i=0
    while [ ! -e "$rel" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    exit 0
    ;;
esac
case "$*" in
  *SLOW*) printf '%s\n' '{"type":"system","subtype":"init","session_id":"s-init"}' ;;
esac
printf '%s\n' '{"type":"tool_call","subtype":"started","tool_call":{"shellToolCall":{"args":{"command":"ls"}}}}'
case "$*" in
  *SLOW*)
    i=0
    while [ ! -e "$rel" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    ;;
esac
case "$*" in
  *COMMIT*)
    printf 'x\n' >> calc.py
    git add calc.py && git commit -q -m "Fix add"
    ;;
esac
case "$*" in
  *DIRTY*)
    printf 'x\n' >> calc.py
    git add calc.py && git commit -q -m "Fix add"
    printf 'leftover\n' >> extra.py
    ;;
esac
case "$*" in
  *ASKME*) printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Which db?\nSTATUS: NEEDS_CONTEXT","session_id":"s-2"}' ;;
  *) printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"391\nSTATUS: DONE","session_id":"s-1"}' ;;
esac
"#;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("cdm-cli-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let agent = dir.join("agent.sh");
        std::fs::write(&agent, FAKE_AGENT).unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
        Env { dir }
    }

    /// Waits for the CANCELME fake to write its pids; on timeout, shows the job record.
    fn until_agent_spawned(&self, id: &str) {
        let t = Instant::now();
        while !(self.dir.join("agent.pid").exists() && self.dir.join("grandchild.pid").exists()) {
            assert!(
                t.elapsed() < Duration::from_secs(10),
                "timed out: agent spawn; record: {}",
                self.record(id)
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Lets SLOW jobs finish; until then they stay RUNNING (10s cap).
    fn release(&self) {
        std::fs::write(self.dir.join("go"), "").unwrap();
    }

    fn argv(&self) -> Vec<String> {
        let s = std::fs::read_to_string(self.dir.join("argv.txt")).unwrap();
        s.lines().map(String::from).collect()
    }

    /// What the fake agent saw in the colour-forcing environment variables.
    fn color_env(&self) -> String {
        std::fs::read_to_string(self.dir.join("color.env"))
            .unwrap()
            .trim()
            .to_string()
    }

    fn delegate(&self, args: &[&str], stdin: Option<&str>) -> Output {
        self.delegate_env(args, stdin, &[])
    }

    fn delegate_env(&self, args: &[&str], stdin: Option<&str>, env: &[(&str, &str)]) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("CURSOR_AGENT_BIN", self.dir.join("agent.sh"))
            .env("DELEGATE_HEARTBEAT_MS", "100")
            .env_remove("DELEGATE_JOBS_DIR");
        for (k, v) in env {
            cmd.env(k, v);
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

    fn run(&self, prompt: &str) -> String {
        self.ok(&["run", "--model", "composer-2.5"], prompt, &[])
    }

    fn ok(&self, args: &[&str], prompt: &str, env: &[(&str, &str)]) -> String {
        self.ok_output(&self.delegate_env(args, Some(prompt), env))
    }

    fn ok_output(&self, out: &Output) -> String {
        assert!(
            out.status.success(),
            "exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8(out.stdout.clone())
            .unwrap()
            .trim()
            .to_string()
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

fn alive(pid: i64) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

fn until(what: &str, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < Duration::from_secs(10), "timed out: {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn run_returns_id_while_job_runs_then_it_finishes() {
    let e = Env::new("run");
    let id = e.run("SLOW do it");
    assert_eq!(id.len(), 36);
    let r = e.record(&id);
    assert_eq!(r["status"], "RUNNING");
    assert_eq!(r["resume"]["model"], "composer-2.5");
    assert!(r["resume"].get("capability").is_none(), "{r}");
    // The SLOW fake prints its init line at once; the record picks up the id as soon as it arrives.
    until("session id in record", || {
        e.record(&id)["resume"]["sessionId"] == "s-init"
    });
    let pid = r["supervisorPid"].as_i64().unwrap();
    assert!(alive(pid), "supervisor must outlive `run`");
    e.release();

    let done = e.wait_terminal(&id);
    let argv = e.argv();
    assert!(
        argv.windows(2).any(|w| w == ["--sandbox", "disabled"]),
        "{argv:?}"
    );
    assert!(argv.contains(&"--force".to_string()), "{argv:?}");
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["text"], "391\nSTATUS: DONE");
    assert_eq!(done["result"]["jobId"], id.as_str());
    assert_eq!(done["resume"]["sessionId"], "s-1");
    until("supervisor exit", || !alive(pid));
}

#[test]
fn running_record_heartbeat_advances() {
    let e = Env::new("hb");
    let id = e.run("SLOW");
    let a = e.record(&id)["lastHeartbeatAt"].as_f64().unwrap();
    until("heartbeat", || {
        let r = e.record(&id);
        r["status"] != "RUNNING" || r["lastHeartbeatAt"].as_f64().unwrap() > a
    });
    assert_ne!(
        e.record(&id)["status"],
        "DONE",
        "heartbeat must advance while RUNNING"
    );
    e.release();
    e.wait_terminal(&id);
}

#[test]
fn needs_context_is_parsed() {
    let e = Env::new("nc");
    let id = e.run("ASKME");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "NEEDS_CONTEXT");
    assert_eq!(done["resume"]["sessionId"], "s-2");
}

#[test]
fn prompt_file_and_write_argv() {
    let e = Env::new("rw");
    std::fs::write(e.dir.join("p.txt"), "from file").unwrap();
    let out = e.delegate(
        &["run", "--model", "composer-2.5", "--prompt-file", "p.txt"],
        None,
    );
    assert!(out.status.success());
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    e.wait_terminal(&id);
    let argv = e.argv();
    assert!(
        argv.windows(2).any(|w| w == ["--sandbox", "disabled"]),
        "{argv:?}"
    );
    assert!(argv.contains(&"--force".to_string()), "{argv:?}");
}

#[test]
fn watch_prints_all_in_order_and_times_out_with_exit_1() {
    let e = Env::new("watch");
    let slow = e.run("SLOW");
    let fast = e.run("quick");
    let out = e.delegate(&["watch", &slow, &fast, "--timeout", "1"], None);
    assert_eq!(out.status.code(), Some(1));
    let lines: Vec<Value> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["status"], "RUNNING");
    let stderr = String::from_utf8(out.stderr).unwrap();
    let errors: Vec<&str> = stderr.lines().collect();
    let expected_ids: Vec<&String> = [(&slow, &lines[0]), (&fast, &lines[1])]
        .into_iter()
        .filter(|(_, record)| record["status"] == "RUNNING")
        .map(|(id, _)| id)
        .collect();
    assert_eq!(errors.len(), expected_ids.len(), "{stderr:?}");
    for (error, id) in errors.iter().zip(expected_ids) {
        assert!(
            error.starts_with(&format!(
                "delegate watch: timed out after 1s; {id} still RUNNING"
            )),
            "{error:?}"
        );
        assert!(
            error.contains("see its progress field; run watch again"),
            "{error:?}"
        );
    }

    e.release();
    let out = e.delegate(&["watch", &fast, &slow, "--timeout", "10"], None);
    assert_eq!(out.status.code(), Some(0));
    let lines: Vec<Value> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines[0]["result"]["jobId"], fast.as_str());
    assert_eq!(lines[1]["result"]["jobId"], slow.as_str());
}

#[test]
fn watch_unknown_job_exits_2() {
    let e = Env::new("unknown");
    let out = e.delegate(&["watch", "nope"], None);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("unknown job nope"));
}

#[test]
fn watch_unknown_job_hints_reboot_and_jobs_dir() {
    let e = Env::new("unknown-hint");
    let out = e.delegate(&["watch", "nope"], None);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unknown job nope"), "{stderr:?}");
    assert!(stderr.contains("reboot"), "{stderr:?}");
    assert!(stderr.contains("DELEGATE_JOBS_DIR"), "{stderr:?}");
}

#[test]
fn unknown_subcommands_explain_watch_and_exit_2() {
    let e = Env::new("unknown-subcommand");
    for name in ["status", "result"] {
        let out = e.delegate(&[name, "x"], None);
        assert_eq!(out.status.code(), Some(2), "{name}");
        assert!(out.stdout.is_empty(), "{name}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        let (message, usage) = stderr.split_once('\n').expect("message followed by usage");
        assert_eq!(
            message,
            format!(
                "unknown subcommand {name}; `delegate watch <jobId>` prints a job's state and result, and the id that superseded it"
            )
        );
        assert!(usage.starts_with("usage: delegate run "), "{usage}");
        assert!(usage.contains("delegate watch <jobId>"), "{usage}");
    }

    let out = e.delegate(&[], None);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.starts_with("usage: delegate run "), "{stderr}");
    assert!(!stderr.contains("unknown subcommand"), "{stderr}");
}

#[test]
fn positional_prompt_exits_2_without_reading_stdin() {
    let e = Env::new("positional");
    // stdin stays open: the old code read it to EOF and hung here.
    let mut child = Command::new(env!("CARGO_BIN_EXE_delegate"))
        .args(["run", "--model", "composer-2.5", "do X"])
        .current_dir(&e.dir)
        .env("TMPDIR", &e.dir)
        .env("CURSOR_AGENT_BIN", e.dir.join("agent.sh"))
        .env_remove("DELEGATE_JOBS_DIR")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdin = child.stdin.take().unwrap();
    let mut status = None;
    until("delegate run exits with stdin open", || {
        status = child.try_wait().unwrap();
        status.is_some()
    });
    drop(stdin);
    let out = child.wait_with_output().unwrap();
    assert_eq!(status.unwrap().code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains(
            "unexpected argument \"do X\": pass the prompt on stdin or with --prompt-file"
        ),
        "{err}"
    );
    assert!(!e.dir.join("delegate-jobs").exists());
}

#[test]
fn bad_run_input_exits_2() {
    let e = Env::new("bad");
    let out = e.delegate(&["run", "--model", "nope-9"], Some("hi"));
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("nope-9") && err.contains("composer-2.5"),
        "{err}"
    );

    let out = e.delegate(&["run", "--model", "composer-2.5"], Some("  \n"));
    assert_eq!(out.status.code(), Some(2));
    std::fs::write(e.dir.join("empty.txt"), "").unwrap();
    let out = e.delegate(
        &[
            "run",
            "--model",
            "composer-2.5",
            "--prompt-file",
            "empty.txt",
        ],
        None,
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(!Path::new(&e.dir.join("delegate-jobs")).exists());
    for bad in ["0", "-5"] {
        let out = e.delegate(
            &["run", "--model", "composer-2.5", "--tool-idle-ms", bad],
            Some("hi"),
        );
        assert_eq!(out.status.code(), Some(2), "{bad}");
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(
            err.contains(&format!("invalid --tool-idle-ms {bad}")),
            "{err}"
        );
    }
}

fn init_repo(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    let hooks = dir.with_file_name("githooks");
    std::fs::create_dir_all(&hooks).unwrap();
    let g = |args: &[&str]| {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    };
    g(&["init", "-q"]);
    g(&["config", "user.email", "t@t.com"]);
    g(&["config", "user.name", "t"]);
    g(&["config", "commit.gpgsign", "false"]);
    g(&["config", "core.hooksPath", hooks.to_str().unwrap()]);
    std::fs::write(dir.join("calc.py"), "def add(a, b):\n    return a - b\n").unwrap();
    g(&["add", "calc.py"]);
    g(&["commit", "-q", "-m", "init"]);
}

fn git_head(dir: &Path) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "HEAD"])
        .output()
        .unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

#[test]
fn gate_pass_keeps_done() {
    let e = Env::new("gate-ok");
    let id = e.ok(
        &["run", "--model", "composer-2.5", "--gate", "true"],
        "ship it",
        &[],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["gateResult"]["passed"], true);
    assert_eq!(done["result"]["gateResult"]["exitCode"], 0);
    assert_eq!(done["result"]["gateResult"]["command"], "true");
    assert_eq!(done["resume"]["gate"], "true");
    assert!(done["resume"]["toolIdleMs"].is_null());
}

#[test]
fn gate_fail_downgrades_and_records_output() {
    let e = Env::new("gate-bad");
    let id = e.ok(
        &[
            "run",
            "--model",
            "composer-2.5",
            "--gate",
            "echo AssertionError; exit 1",
            "--tool-idle-ms",
            "2500",
        ],
        "ship it",
        &[],
    );
    let watched = e.delegate(&["watch", &id, "--timeout", "10"], None);
    assert_eq!(watched.status.code(), Some(0));
    let printed = String::from_utf8(watched.stdout).unwrap();
    let done: Value = serde_json::from_str(&printed).unwrap();
    assert_eq!(done["status"], "DONE_WITH_CONCERNS");
    assert_eq!(done["result"]["gateResult"]["passed"], false);
    assert_eq!(done["result"]["gateResult"]["exitCode"], 1);
    assert_eq!(
        done["result"]["gateResult"]["command"],
        "echo AssertionError; exit 1"
    );
    assert!(
        done["result"]["gateResult"]["outputTail"]
            .as_str()
            .unwrap()
            .contains("AssertionError"),
        "{done}"
    );
    let output_path = done["result"]["gateResult"]["outputPath"].as_str().unwrap();
    let basename = Path::new(output_path)
        .file_name()
        .unwrap()
        .to_string_lossy();
    assert!(basename.starts_with(&format!("{id}-gate")), "{basename}");
    assert!(
        printed.contains(output_path),
        "watch output omitted {output_path}"
    );
    assert_eq!(
        std::fs::read_to_string(output_path).unwrap(),
        "AssertionError\n"
    );
    assert_eq!(done["resume"]["gate"], "echo AssertionError; exit 1");
    assert_eq!(done["resume"]["toolIdleMs"], serde_json::json!(2500));
}

/// Both colour-forcing variables must be unset in every child delegate captures: the
/// gate (this test) and the agent backend (`agent_child_sees_force_color_unset`).
#[test]
fn gate_child_sees_force_color_unset() {
    let e = Env::new("gate-color");
    let id = e.ok(
        &[
            "run",
            "--model",
            "composer-2.5",
            "--gate",
            r#"printf "%s %s" "${FORCE_COLOR-unset}" "${CLICOLOR_FORCE-unset}""#,
        ],
        "ship it",
        &[("FORCE_COLOR", "3"), ("CLICOLOR_FORCE", "1")],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["gateResult"]["outputTail"], "unset unset");
}

#[test]
fn agent_child_sees_force_color_unset() {
    let e = Env::new("agent-color");
    let id = e.ok(
        &["run", "--model", "composer-2.5"],
        "plain",
        &[("FORCE_COLOR", "3"), ("CLICOLOR_FORCE", "1")],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE", "{done}");
    assert_eq!(e.color_env(), "unset unset");
}

#[test]
fn gate_killed_after_tool_idle_window() {
    let e = Env::new("gate-timeout");
    let id = e.ok(
        &[
            "run",
            "--model",
            "composer-2.5",
            "--tool-idle-ms",
            "400",
            "--gate",
            "sleep 30",
        ],
        "ship it",
        &[],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE_WITH_CONCERNS");
    assert_eq!(done["result"]["gateResult"]["passed"], false);
    assert!(
        done["result"]["gateResult"]["error"]
            .as_str()
            .unwrap_or("")
            .contains("timeout"),
        "{done}"
    );
}

#[test]
fn change_set_lists_the_commit() {
    let e = Env::new("cset");
    let repo = e.dir.join("repo");
    init_repo(&repo);
    let before = git_head(&repo);
    let id = e.ok(
        &[
            "run",
            "--model",
            "composer-2.5",
            "--cwd",
            repo.to_str().unwrap(),
        ],
        "COMMIT the fix",
        &[],
    );
    let done = e.wait_terminal(&id);
    let head = git_head(&repo);
    assert_ne!(head, before);
    assert_eq!(done["status"], "DONE");
    let commits = done["result"]["changeSet"]["newCommits"]
        .as_array()
        .unwrap();
    assert!(
        commits.iter().any(|c| c.as_str() == Some(head.as_str())),
        "{commits:?} head {head}"
    );
    let files = done["result"]["changeSet"]["filesChanged"]
        .as_array()
        .unwrap();
    assert!(files.iter().any(|f| f.as_str() == Some("calc.py")));
    assert_eq!(done["result"]["changeSet"]["dirtyAfter"], false);
    assert!(done["result"]["concerns"].is_null());
}

#[test]
fn dirty_tree_after_commit_is_a_concern() {
    let e = Env::new("dirty");
    let repo = e.dir.join("repo");
    init_repo(&repo);
    let id = e.ok(
        &[
            "run",
            "--model",
            "composer-2.5",
            "--cwd",
            repo.to_str().unwrap(),
        ],
        "DIRTY the tree",
        &[],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE_WITH_CONCERNS");
    assert_eq!(done["result"]["changeSet"]["dirtyAfter"], true);
    let files = done["result"]["changeSet"]["uncommittedFiles"]
        .as_array()
        .unwrap();
    assert!(
        files.iter().any(|f| f.as_str() == Some("extra.py")),
        "{files:?}"
    );
    let concerns = done["result"]["concerns"].as_array().unwrap();
    assert!(
        concerns
            .iter()
            .any(|c| c.as_str().unwrap().contains("still dirty")),
        "{concerns:?}"
    );
}

#[test]
fn tool_idle_stalls_a_quiet_tool_call() {
    let e = Env::new("tool-idle");
    let id = e.ok(
        &["run", "--model", "composer-2.5", "--tool-idle-ms", "300"],
        "SLOW",
        &[],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "STALLED");
    let text = done["result"]["text"].as_str().unwrap();
    assert!(text.contains("Idle watchdog killed this job"), "{text}");
}

#[test]
fn silent_agent_stalls_and_record_says_why() {
    let e = Env::new("stall");
    let id = e.ok(
        &["run", "--model", "composer-2.5"],
        "SILENT",
        &[("DELEGATE_IDLE_MS", "200")],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "STALLED");
    let text = done["result"]["text"].as_str().unwrap();
    assert!(text.contains("Idle watchdog killed this job"), "{text}");
}

#[test]
fn idle_ms_flag_overrides_the_host_window_for_one_run() {
    let e = Env::new("idle-flag");
    let id = e.ok(
        &["run", "--model", "composer-2.5", "--idle-ms", "200"],
        "SILENT",
        &[("DELEGATE_IDLE_MS", "600000")],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "STALLED");
    let text = done["result"]["text"].as_str().unwrap();
    assert!(text.contains("Idle watchdog killed this job"), "{text}");
    assert_eq!(done["resume"]["idleMs"], serde_json::json!(200));
}

#[test]
fn no_idle_ms_flag_records_a_null_override() {
    let e = Env::new("idle-null");
    let id = e.ok(&["run", "--model", "composer-2.5"], "ship it", &[]);
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert!(done["resume"]["idleMs"].is_null());
}

#[test]
fn two_runs_in_the_same_cwd_both_reach_terminal() {
    // No serialisation: a second run in the same directory starts while the first is RUNNING.
    let e = Env::new("parallel");
    let a = e.run("SLOW first");
    let b = e.run("SLOW second");
    assert_eq!(e.record(&a)["status"], "RUNNING");
    assert_eq!(e.record(&b)["status"], "RUNNING");
    e.release();
    assert_eq!(e.wait_terminal(&a)["status"], "DONE");
    assert_eq!(e.wait_terminal(&b)["status"], "DONE");
}

#[test]
fn subcommand_help_prints_usage_and_succeeds() {
    let e = Env::new("subcommand-help");
    for args in [vec!["run", "--help"], vec!["watch", "-h"]] {
        let out = e.delegate(&args, None);
        assert_eq!(out.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(stdout.contains("usage: delegate run --model M"), "{stdout}");
        assert!(stdout.contains("delegate doctor"), "{stdout}");
        assert!(out.stderr.is_empty());
    }
}

#[test]
fn capability_flag_is_an_unknown_flag_error() {
    let e = Env::new("capflag");
    let out = e.delegate(
        &[
            "run",
            "--model",
            "composer-2.5",
            "--capability",
            "read-only",
        ],
        Some("hi"),
    );
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("unknown flag --capability"), "{err}");
    assert!(out.stdout.is_empty());

    let out = e.delegate(
        &["resume", "whatever", "--capability", "read-only"],
        Some("hi"),
    );
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("unknown flag --capability"), "{err}");
    assert!(out.stdout.is_empty());
}

#[test]
fn watch_reports_dead_supervisor() {
    let e = Env::new("dead-sup");
    let id = e.run("SLOW");
    until("cursor init session id", || {
        e.record(&id)["resume"]["sessionId"] == "s-init"
    });
    let pid = e.record(&id)["supervisorPid"].as_i64().unwrap();
    unsafe { libc::kill(pid as i32, libc::SIGKILL) };
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR");
    assert_eq!(done["result"]["text"], "supervisor died");
    assert_eq!(done["result"]["sessionId"], "s-init");
    assert_eq!(e.record(&id)["status"], "ERROR");
    assert_eq!(e.record(&id)["result"]["text"], "supervisor died");
    e.release();
}

impl Env {
    fn resume(&self, id: &str, extra: &[&str], prompt: Option<&str>) -> Output {
        let mut args: Vec<&str> = vec!["resume", id];
        args.extend(extra);
        self.delegate(&args, prompt)
    }

    fn resume_ok(&self, id: &str, extra: &[&str], prompt: &str) -> String {
        let out = self.resume(id, extra, Some(prompt));
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

#[test]
fn resume_continues_session_and_links_chain() {
    let e = Env::new("resume");
    let a = e.run("first brief");
    let first = e.wait_terminal(&a);
    assert_eq!(first["status"], "DONE");
    assert_eq!(first["resume"]["sessionId"], "s-1");
    let pid = first["supervisorPid"].as_i64().unwrap();
    // The original supervisor is gone: everything resume needs is in the record.
    until("supervisor exit", || !alive(pid));

    let b = e.resume_ok(&a, &[], "follow up");
    assert_eq!(b.len(), 36);
    let done = e.wait_terminal(&b);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["jobId"], b.as_str());
    assert_eq!(done["resume"]["sessionId"], "s-1");
    // No heartbeat/progress on a terminal record.
    assert!(done.get("lastHeartbeatAt").is_none(), "{done}");
    assert!(done.get("progress").is_none(), "{done}");
    // The fake agent saw the resume flag with the original model and cwd.
    let argv = e.argv();
    assert!(
        argv.windows(2).any(|w| w == ["--resume", "s-1"]),
        "{argv:?}"
    );
    assert!(argv.contains(&"composer-2.5".to_string()), "{argv:?}");
    assert!(
        argv.windows(2).any(|w| w == ["--sandbox", "disabled"]),
        "{argv:?}"
    );
    assert_eq!(done["resume"]["cwd"], first["resume"]["cwd"]);
    assert!(done["resume"].get("capability").is_none(), "{done}");
    // Chain links: B points back, A points forward, nothing else on A changed.
    assert_eq!(done["resumedFrom"], a.as_str());
    let again = e.record(&a);
    assert_eq!(again["supersededBy"], b.as_str());
    assert_eq!(again["result"], first["result"]);
    assert_eq!(again["resume"], first["resume"]);
}

#[test]
fn resume_overrides_replace_stored_values() {
    let e = Env::new("resume-ov");
    let a = e.run("first");
    e.wait_terminal(&a);

    let b = e.resume_ok(&a, &["--model", "grok-4.7-high"], "again");
    let done = e.wait_terminal(&b);
    assert_eq!(done["resume"]["model"], "grok-4.7-high");
    assert!(
        e.argv().contains(&"grok-4.7-high".to_string()),
        "{:?}",
        e.argv()
    );

    std::fs::write(e.dir.join("follow.txt"), "gated follow-up").unwrap();
    let out = e.resume(&a, &["--gate", "true", "--prompt-file", "follow.txt"], None);
    let d = e.ok_output(&out);
    let done = e.wait_terminal(&d);
    assert_eq!(done["resume"]["gate"], "true");
    assert_eq!(done["result"]["gateResult"]["command"], "true");
    assert_eq!(done["result"]["gateResult"]["passed"], true);
}

#[test]
fn resume_cross_backend_and_unknown_models_exit_2() {
    let e = Env::new("resume-xb");
    let a = e.run("first");
    e.wait_terminal(&a);
    for m in ["openai/gpt-6-luna:xhigh", "claude-sonnet-5-5"] {
        let out = e.resume(&a, &["--model", m], Some("again"));
        assert_eq!(out.status.code(), Some(2), "{m}");
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(err.contains("backend"), "{err}");
        assert!(out.stdout.is_empty());
    }
    let out = e.resume(&a, &["--model", "nope-9"], Some("again"));
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("nope-9") && err.contains("composer-2.5"),
        "{err}"
    );
}

#[test]
fn resume_running_job_exits_2() {
    let e = Env::new("resume-run");
    let slow = e.run("SLOW");
    assert_eq!(e.record(&slow)["status"], "RUNNING");
    let out = e.resume(&slow, &[], Some("follow"));
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("RUNNING"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    e.release();
    e.wait_terminal(&slow);
}

#[test]
fn resume_unknown_no_session_and_empty_prompt_exit_2() {
    let e = Env::new("resume-err");
    let out = e.resume("nope", &[], Some("hi"));
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("unknown job nope"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let a = e.run("first");
    e.wait_terminal(&a);
    let out = e.resume(&a, &[], Some("  \n"));
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("prompt is empty"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    // A record with no session id is not resumable.
    let slow = e.run("SILENT");
    let cancelled = e.delegate(&["cancel", &slow], None);
    assert_eq!(cancelled.status.code(), Some(0));
    assert_eq!(e.record(&slow)["status"], "CANCELLED");
    let out = e.resume(&slow, &[], Some("follow"));
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("session"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn read_pid(dir: &std::path::Path, name: &str) -> i64 {
    std::fs::read_to_string(dir.join(name))
        .unwrap()
        .trim()
        .parse()
        .unwrap()
}

#[test]
fn cancel_kills_agent_and_grandchild() {
    let e = Env::new("cancel");
    let id = e.run("CANCELME");
    e.until_agent_spawned(&id);
    until("cursor init session id", || {
        e.record(&id)["resume"]["sessionId"] == "s-init"
    });
    assert_eq!(e.record(&id)["status"], "RUNNING");
    assert_eq!(e.record(&id)["resume"]["sessionId"], "s-init");
    assert_eq!(e.record(&id)["resume"]["backend"], "cursor");
    let agent = read_pid(&e.dir, "agent.pid");
    let grand = read_pid(&e.dir, "grandchild.pid");
    assert!(alive(agent) && alive(grand), "agent {agent} grand {grand}");

    let out = e.delegate(&["cancel", &id], None);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let final_rec: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(final_rec["status"], "CANCELLED");
    assert_eq!(final_rec["result"]["status"], "CANCELLED");
    assert_eq!(final_rec["result"]["jobId"], id.as_str());
    assert_eq!(final_rec["result"]["sessionId"], "s-init");
    assert_eq!(final_rec["resume"]["sessionId"], "s-init");
    until("agent death", || !alive(agent) && !alive(grand));
    assert_eq!(e.record(&id)["status"], "CANCELLED");
    let resumed = e.resume(&id, &[], Some("continue"));
    assert_eq!(
        resumed.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&resumed.stderr)
    );
    let resumed_id = String::from_utf8(resumed.stdout)
        .unwrap()
        .trim()
        .to_string();
    assert_eq!(e.wait_terminal(&resumed_id)["status"], "DONE");
    let argv = e.argv();
    assert!(
        argv.windows(2).any(|w| w == ["--resume", "s-init"]),
        "{argv:?}"
    );
}

#[test]
fn cancel_sigkill_fallback_after_stopped_supervisor() {
    let e = Env::new("cancel-kill");
    let id = e.run("CANCELME");
    e.until_agent_spawned(&id);
    until("cursor init session id", || {
        e.record(&id)["resume"]["sessionId"] == "s-init"
    });
    assert_eq!(e.record(&id)["status"], "RUNNING");
    let sup = e.record(&id)["supervisorPid"].as_i64().unwrap() as i32;
    let agent = read_pid(&e.dir, "agent.pid");
    let grand = read_pid(&e.dir, "grandchild.pid");
    // Freeze the supervisor so SIGTERM can never be answered: `cancel` must escalate
    // through the 5s wait, SIGKILL both groups and write CANCELLED itself.
    unsafe { libc::kill(sup, libc::SIGSTOP) };
    let start = Instant::now();
    let out = e.delegate(&["cancel", &id], None);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let final_rec: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(final_rec["status"], "CANCELLED");
    assert_eq!(final_rec["result"]["status"], "CANCELLED");
    assert_eq!(final_rec["result"]["sessionId"], "s-init");
    assert_eq!(final_rec["resume"]["sessionId"], "s-init");
    assert_eq!(final_rec["result"]["backend"], "cursor");
    // The full 5s SIGTERM wait elapsed: the fast supervisor path could not have fired.
    assert!(start.elapsed() >= Duration::from_secs(5));
    until("agent death", || !alive(agent) && !alive(grand));
    assert_eq!(e.record(&id)["status"], "CANCELLED");
}

#[test]
fn cancel_on_terminal_job_prints_record_and_exits_0() {
    let e = Env::new("cancel-noop");
    let id = e.run("quick");
    let done = e.wait_terminal(&id);
    let out = e.delegate(&["cancel", &id], None);
    assert_eq!(out.status.code(), Some(0));
    let printed: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(printed, done);
}

#[test]
fn cancel_unknown_job_exits_2() {
    let e = Env::new("cancel-unknown");
    let out = e.delegate(&["cancel", "nope"], None);
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("unknown job nope"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn cancel_finds_a_record_under_another_tmpdir() {
    let e = Env::new("x-cancel");
    let id = e.run("SLOW do it");
    assert_eq!(e.record(&id)["status"], "RUNNING");
    let other = std::env::temp_dir().join("cdm-cli-x-cancel-other");
    let _ = std::fs::remove_dir_all(&other);
    std::fs::create_dir_all(&other).unwrap();
    let jobs = e.dir.join("delegate-jobs");
    let out = e.delegate_env(
        &["cancel", &id],
        None,
        &[
            ("TMPDIR", other.to_str().unwrap()),
            ("DELEGATE_JOBS_DIR", jobs.to_str().unwrap()),
        ],
    );
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let final_rec: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(final_rec["status"], "CANCELLED");
    assert_eq!(e.record(&id)["status"], "CANCELLED");
    e.release();
    let _ = std::fs::remove_dir_all(&other);
}

#[test]
fn run_writes_to_the_jobs_dir_override_and_cancel_finds_it_there() {
    // docs/delegate-jobs.md#writers
    let e = Env::new("jobs-dir-writes");
    let jobs_a = e.dir.join("jobs-a");
    let tmp_b = e.dir.join("tmp-b");
    let tmp_c = e.dir.join("tmp-c");
    for d in [&jobs_a, &tmp_b, &tmp_c] {
        std::fs::create_dir_all(d).unwrap();
    }
    let out = e.delegate_env(
        &["run", "--model", "composer-2.5"],
        Some("quick"),
        &[
            ("DELEGATE_JOBS_DIR", jobs_a.to_str().unwrap()),
            ("TMPDIR", tmp_b.to_str().unwrap()),
        ],
    );
    let id = e.ok_output(&out);
    assert!(
        jobs_a.join(format!("{id}.json")).is_file(),
        "record lands under DELEGATE_JOBS_DIR, not TMPDIR"
    );
    assert!(
        !tmp_b
            .join("delegate-jobs")
            .join(format!("{id}.json"))
            .exists(),
        "no copy under the run's TMPDIR"
    );
    let out = e.delegate_env(
        &["cancel", &id],
        None,
        &[
            ("TMPDIR", tmp_c.to_str().unwrap()),
            ("DELEGATE_JOBS_DIR", jobs_a.to_str().unwrap()),
        ],
    );
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let final_rec: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(final_rec["result"]["jobId"], id.as_str());
    assert!(
        !tmp_c
            .join("delegate-jobs")
            .join(format!("{id}.json"))
            .exists(),
        "cancel writes back where it found the record"
    );
}

#[test]
fn watch_and_resume_find_a_record_under_another_tmpdir() {
    let e = Env::new("x-watch");
    let a = e.run("first brief");
    let first = e.wait_terminal(&a);
    assert_eq!(first["status"], "DONE");
    let other = std::env::temp_dir().join("cdm-cli-x-watch-other");
    let _ = std::fs::remove_dir_all(&other);
    std::fs::create_dir_all(&other).unwrap();
    let jobs = e.dir.join("delegate-jobs");
    let over = [
        ("TMPDIR", other.to_str().unwrap()),
        ("DELEGATE_JOBS_DIR", jobs.to_str().unwrap()),
    ];
    let out = e.delegate_env(&["watch", &a], None, &over);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let seen: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(seen["status"], "DONE");

    let out = e.delegate_env(&["resume", &a], Some("follow up"), &over);
    assert!(
        out.status.success(),
        "exit {:?}\nstderr: {}\nstdout: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let b = String::from_utf8(out.stdout).unwrap().trim().to_string();
    // The resumed job inherits the caller's DELEGATE_JOBS_DIR, so its record
    // lands in the override dir; watch it there (docs/delegate-jobs.md#writers).
    let out = e.delegate_env(&["watch", &b, "--timeout", "10"], None, &over);
    assert_eq!(out.status.code(), Some(0));
    let done: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(done["status"], "DONE");
    assert_eq!(e.record(&a)["supersededBy"], b.as_str());
    let _ = std::fs::remove_dir_all(&other);
}

#[test]
fn cancel_fallback_writes_back_to_the_original_record() {
    let e = Env::new("x-fallback");
    let id = e.run("SLOW");
    until("cursor init session id", || {
        e.record(&id)["resume"]["sessionId"] == "s-init"
    });
    let pid = e.record(&id)["supervisorPid"].as_i64().unwrap();
    unsafe { libc::kill(pid as i32, libc::SIGKILL) };
    until("supervisor death", || !alive(pid));
    let other = std::env::temp_dir().join("cdm-cli-x-fallback-other");
    let _ = std::fs::remove_dir_all(&other);
    std::fs::create_dir_all(&other).unwrap();
    let jobs = e.dir.join("delegate-jobs");
    let out = e.delegate_env(
        &["cancel", &id],
        None,
        &[
            ("TMPDIR", other.to_str().unwrap()),
            ("DELEGATE_JOBS_DIR", jobs.to_str().unwrap()),
        ],
    );
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let final_rec: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(final_rec["status"], "CANCELLED");
    assert_eq!(e.record(&id)["status"], "CANCELLED");
    assert!(
        !other.join("delegate-jobs").exists(),
        "no second copy in the caller's dir"
    );
    e.release();
    let _ = std::fs::remove_dir_all(&other);
}

#[test]
fn unknown_job_names_the_searched_dirs() {
    let e = Env::new("x-unknown");
    let out = e.delegate(&["watch", "nope"], None);
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("unknown job nope"), "{err}");
    assert!(
        err.contains(&e.dir.join("delegate-jobs").display().to_string()),
        "{err}"
    );
    assert!(err.contains("/tmp/delegate-jobs"), "{err}");
}

#[test]
fn cancel_with_a_separator_id_reads_nothing_outside() {
    let e = Env::new("x-sep");
    std::fs::write(e.dir.join("x.json"), "{}").unwrap();
    let out = e.delegate(&["cancel", "../x"], None);
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("unknown job ../x"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// The Muse sandbox default and host-profile override are documented in
/// delegate/README.md:48 and delegate/README.md:56.
#[test]
fn muse_run_applies_the_host_sandbox_switch() {
    let cases: [(&str, Option<&str>, bool); 3] = [
        ("muse-sandbox-default", None, true),
        ("muse-sandbox-off", Some("{\"museSandbox\":false}"), true),
        ("muse-sandbox-on", Some("{\"museSandbox\":true}"), false),
    ];
    for (name, profile_json, expect_disabled) in cases {
        let e = Env::new(name);
        let dir_str = e.dir.to_str().unwrap().to_string();
        let fixture_src = format!(
            "{}/tests/fixtures/contract/muse/tool-calls-fix.stdout",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::write(
            e.dir.join("fixture.stdout"),
            std::fs::read(fixture_src).unwrap(),
        )
        .unwrap();
        let fake = e.dir.join("muse.sh");
        std::fs::write(
            &fake,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}\ncat {}\n",
                e.dir.join("argv.txt").display(),
                e.dir.join("fixture.stdout").display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        let profile_path = match profile_json {
            Some(body) => {
                let path = e.dir.join("host-profile.json");
                std::fs::write(&path, body).unwrap();
                path.to_str().unwrap().to_string()
            }
            // Isolate from the developer machine's real host profile.
            None => e
                .dir
                .join("nonexistent-profile.json")
                .to_str()
                .unwrap()
                .to_string(),
        };
        let out = e.delegate_env(
            &["run", "--model", "muse/muse-spark-1.3-contributor"],
            Some("do the thing"),
            &[
                ("MUSE_BIN", fake.to_str().unwrap()),
                ("HOME", &dir_str),
                ("DELEGATE_HOST_PROFILE", &profile_path),
            ],
        );
        let id = e.ok_output(&out);
        let done = e.wait_terminal(&id);
        assert_eq!(done["status"], "DONE", "{name}");
        let argv: Vec<String> = std::fs::read_to_string(e.dir.join("argv.txt"))
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(
            argv.iter().any(|a| a == "--disable-sandbox"),
            expect_disabled,
            "{name}: {argv:?}"
        );
    }
}

/// A reminder-task loop emits no meaningful progress, so the idle watchdog
/// ends the job STALLED. The fake drains the fixture, writes stderr, then blocks.
#[test]
fn muse_reminder_loop_stalls_on_the_idle_watchdog() {
    let e = Env::new("muse-stall");
    let dir_str = e.dir.to_str().unwrap().to_string();
    let fixture_src = format!(
        "{}/tests/fixtures/contract/muse/reminder-stall.stdout",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::write(
        e.dir.join("fixture.stdout"),
        std::fs::read(fixture_src).unwrap(),
    )
    .unwrap();
    let fake = e.dir.join("muse.sh");
    std::fs::write(
        &fake,
        format!(
            "#!/bin/sh\ncat {}\nprintf '%s\\n' 'muse: reminder heartbeat' >&2\nexec tail -f /dev/null\n",
            e.dir.join("fixture.stdout").display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let profile = e.dir.join("nonexistent-profile.json");
    let out = e.delegate_env(
        &["run", "--model", "muse/muse-spark-1.3-contributor"],
        Some("loop forever"),
        &[
            ("MUSE_BIN", fake.to_str().unwrap()),
            ("HOME", &dir_str),
            ("DELEGATE_HOST_PROFILE", profile.to_str().unwrap()),
            ("DELEGATE_IDLE_MS", "500"),
        ],
    );
    let id = e.ok_output(&out);
    // 20 s deadline for the 500 ms idle window, which is event driven.
    let out = e.delegate(&["watch", &id, "--timeout", "20"], None);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let done: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(done["status"], "STALLED");
    let text = done["result"]["text"].as_str().unwrap();
    assert!(text.starts_with("Idle watchdog killed this job"), "{text}");
}

#[test]
fn wall_ms_is_recorded_and_survives_resume() {
    let e = Env::new("wall-plumb");
    let id = e.ok(
        &["run", "--model", "composer-2.5", "--wall-ms", "600000"],
        "quick",
        &[],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resume"]["wallMs"], serde_json::json!(600000));
    let b = e.resume_ok(&id, &[], "follow up");
    let done = e.wait_terminal(&b);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resume"]["wallMs"], serde_json::json!(600000));
}

#[test]
fn run_without_wall_ms_records_null_and_resume_keeps_null() {
    let e = Env::new("wall-none");
    let id = e.run("quick");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert!(done["resume"]["wallMs"].is_null(), "{done}");
    let b = e.resume_ok(&id, &[], "follow up");
    let done = e.wait_terminal(&b);
    assert_eq!(done["status"], "DONE");
    assert!(done["resume"]["wallMs"].is_null(), "{done}");
}

#[test]
fn wall_ms_cancels_a_running_agent_and_its_group() {
    let e = Env::new("wall-cancel");
    let id = e.ok(
        &["run", "--model", "composer-2.5", "--wall-ms", "5000"],
        "CANCELME",
        &[],
    );
    e.until_agent_spawned(&id);
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "CANCELLED");
    assert_eq!(done["result"]["status"], "CANCELLED");
    let text = done["result"]["text"].as_str().unwrap();
    assert!(
        text.starts_with("Cancelled: wall budget of 5000 ms exceeded after"),
        "{text}"
    );
    assert_eq!(done["resume"]["wallMs"], serde_json::json!(5000));
    assert_eq!(done["resume"]["sessionId"], "s-init");
    for name in ["agent.pid", "grandchild.pid"] {
        let pid: i64 = std::fs::read_to_string(e.dir.join(name))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        until("fake child dead", || !alive(pid));
    }
}

#[test]
fn wall_ms_aborts_a_running_gate() {
    let e = Env::new("wall-gate");
    let id = e.ok(
        &[
            "run",
            "--model",
            "composer-2.5",
            "--wall-ms",
            "1500",
            "--gate",
            "sleep 30",
        ],
        "quick",
        &[],
    );
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "CANCELLED");
    let text = done["result"]["text"].as_str().unwrap();
    assert!(
        text.starts_with("Cancelled: wall budget of 1500 ms exceeded after"),
        "{text}"
    );
    let err = done["result"]["gateResult"]["error"].as_str().unwrap();
    assert!(err.contains("gate killed"), "{err}");
}

#[test]
fn help_mentions_wall_ms() {
    let e = Env::new("wall-help");
    let out = e.delegate(&["--help"], None);
    assert_eq!(out.status.code(), Some(0));
    let help = String::from_utf8(out.stdout).unwrap();
    assert!(help.contains("usage: delegate run --model M"), "{help}");
    assert!(help.contains("[--wall-ms N]"), "{help}");
}
