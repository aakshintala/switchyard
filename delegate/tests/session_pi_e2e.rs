mod support;

use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

static NEXT: AtomicU64 = AtomicU64::new(0);
const BIN: &str = env!("CARGO_BIN_EXE_delegate");
const FIXTURES: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/fixtures/contract/pi-rpc"
);
const TRIGGER: &str = delegate::session::pi::TRIGGER;

struct Harness {
    base: std::path::PathBuf,
    home: std::path::PathBuf,
    fake_dir: std::path::PathBuf,
    inbox: std::path::PathBuf,
    fake: std::path::PathBuf,
}

impl Harness {
    fn new() -> Self {
        let base = std::path::PathBuf::from("/tmp").join(format!(
            "dspi-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let home = base.join("home");
        let fake_dir = base.join("fake-data");
        let inbox = base.join("inbox");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&fake_dir).unwrap();
        let fake = support::pi_host_fake();
        Self {
            base,
            home,
            fake_dir,
            inbox,
            fake,
        }
    }

    fn invoke(&self, args: &[&str]) -> Output {
        self.invoke_with(args, None, "", None, &[])
    }

    fn invoke_with(
        &self,
        args: &[&str],
        input: Option<&[u8]>,
        scenario: &str,
        cassette: Option<&str>,
        extra_env: &[(&str, &str)],
    ) -> Output {
        self.invoke_with_timeout(
            args,
            input,
            scenario,
            cassette,
            extra_env,
            Duration::from_secs(10),
        )
    }

    fn invoke_with_timeout(
        &self,
        args: &[&str],
        input: Option<&[u8]>,
        scenario: &str,
        cassette: Option<&str>,
        extra_env: &[(&str, &str)],
        timeout: Duration,
    ) -> Output {
        let mut command = Command::new(BIN);
        command
            .arg("session")
            .args(args)
            .env("HOME", &self.home)
            .env("MUSE_BIN", "/nonexistent/muse")
            .env("PI_BIN", &self.fake)
            .env("FAKE_DIR", &self.fake_dir)
            .env("FAKE_SCENARIO", scenario)
            .env("FAKE_FIXTURE_DIR", FIXTURES)
            .env("DELEGATE_SESSION_GRACE_MS", "300")
            .env_remove("TERM")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            });
        match cassette {
            Some(paths) => {
                command.env("FAKE_CASSETTE", paths);
            }
            None => {
                command.env_remove("FAKE_CASSETTE");
            }
        }
        for (key, value) in extra_env {
            command.env(key, value);
        }
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let exec_guard = support::exec_lock();
        let spawned = command.spawn();
        drop(exec_guard);
        let mut child = spawned.unwrap();
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let (stdout_tx, stdout_rx) = mpsc::channel();
        let (stderr_tx, stderr_rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = std::io::BufReader::new(stdout).read_to_end(&mut bytes);
            let _ = stdout_tx.send(bytes);
        });
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = std::io::BufReader::new(stderr).read_to_end(&mut bytes);
            let _ = stderr_tx.send(bytes);
        });
        if let Some(input) = input {
            child.stdin.take().unwrap().write_all(input).unwrap();
        }
        let status = wait_cli(&mut child, timeout, &self.root(), args);
        let stdout = stdout_rx
            .recv_timeout(timeout)
            .expect("stdout EOF deadline");
        let stderr = stderr_rx
            .recv_timeout(timeout)
            .expect("stderr EOF deadline");
        Output {
            status,
            stdout,
            stderr,
        }
    }

    fn brief_file(&self, bytes: &[u8]) -> std::path::PathBuf {
        let path = self
            .base
            .join(format!("brief-{}.md", NEXT.fetch_add(1, Ordering::Relaxed)));
        std::fs::write(&path, bytes).unwrap();
        path
    }

    fn start_pi(
        &self,
        model: &str,
        brief: &[u8],
        json_mode: bool,
        scenario: &str,
        cassette: Option<&str>,
        env: &[(&str, &str)],
    ) -> Output {
        let brief = self.brief_file(brief);
        let mut args = vec![
            "start".to_string(),
            "--model".to_string(),
            model.to_string(),
            "--brief".to_string(),
            brief.to_str().unwrap().to_string(),
            "--inbox".to_string(),
            self.inbox.to_str().unwrap().to_string(),
        ];
        if json_mode {
            args.push("--json".to_string());
        }
        let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
        self.invoke_with(&borrowed, None, scenario, cassette, env)
    }

    fn root(&self) -> std::path::PathBuf {
        self.home.join(".cache/agents/sessions")
    }

    fn state(&self, id: &str) -> Value {
        serde_json::from_slice(&std::fs::read(self.root().join(id).join("state.json")).unwrap())
            .unwrap()
    }

    fn wait_state(&self, id: &str, what: &str, predicate: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let value = self.state(id);
            if predicate(&value) {
                return value;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}: {value}"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_file(&self, name: &str, what: &str) {
        self.wait_path(&self.fake_dir.join(name), what);
    }

    fn wait_path(&self, path: &std::path::Path, what: &str) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !path.exists() {
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}: {path:?}"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn requests(&self) -> Vec<Value> {
        std::fs::read_to_string(self.fake_dir.join("requests.jsonl"))
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .collect()
    }

    fn logs(&self, id: &str) -> Vec<Value> {
        std::fs::read_to_string(self.root().join(id).join("events.jsonl"))
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .collect()
    }

    fn notes(&self, id: &str, kind: &str) -> Vec<std::path::PathBuf> {
        let Ok(entries) = std::fs::read_dir(&self.inbox) else {
            return Vec::new();
        };
        entries
            .flatten()
            .filter_map(|entry| {
                let expected = format!("[session {id} {kind}]\n");
                (std::fs::read_to_string(entry.path()).ok().as_deref() == Some(expected.as_str()))
                    .then_some(entry.path())
            })
            .collect()
    }

    fn notes_poll(&self, id: &str, kind: &str, expected: usize) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let count = self.notes(id, kind).len();
            if count == expected {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {expected} {kind} notes, have {count}"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_requests(&self, what: &str, predicate: impl Fn(&[Value]) -> bool) -> Vec<Value> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let requests = self.requests();
            if predicate(&requests) {
                return requests;
            }
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn only_session(&self) -> String {
        let ids: Vec<String> = std::fs::read_dir(self.root())
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false))
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(ids.len(), 1, "expected one session: {ids:?}");
        ids.into_iter().next().unwrap()
    }

    fn assert_process_gone(&self, pid: i32) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if unsafe { libc::kill(pid, 0) } != 0 {
                assert_eq!(
                    std::io::Error::last_os_error().raw_os_error(),
                    Some(libc::ESRCH)
                );
                return;
            }
            assert!(Instant::now() < deadline, "process {pid} remained alive");
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        if let Ok(entries) = std::fs::read_dir(self.root()) {
            for entry in entries.flatten() {
                let Ok(bytes) = std::fs::read(entry.path().join("state.json")) else {
                    continue;
                };
                let Ok(state) = serde_json::from_slice::<Value>(&bytes) else {
                    continue;
                };
                for key in ["supervisorPid", "hostPid"] {
                    if let Some(pid) = state.get(key).and_then(Value::as_i64) {
                        unsafe {
                            libc::kill(pid as i32, libc::SIGTERM);
                            libc::kill(-(pid as i32), libc::SIGTERM);
                            libc::kill(pid as i32, libc::SIGKILL);
                            libc::kill(-(pid as i32), libc::SIGKILL);
                        }
                    }
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

fn wait_cli(
    child: &mut Child,
    timeout: Duration,
    root: &std::path::Path,
    args: &[&str],
) -> ExitStatus {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= deadline {
            let state = std::fs::read_dir(root)
                .ok()
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|entry| std::fs::read_to_string(entry.path().join("state.json")).ok())
                .collect::<Vec<_>>();
            let _ = child.kill();
            panic!("subprocess {args:?} exceeded {timeout:?}; session states: {state:?}");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn assert_json_error(output: &Output, exit: i32, code: &str) -> Value {
    assert_eq!(
        output.status.code(),
        Some(exit),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["ok"], false);
    assert_eq!(value["error"]["code"], code);
    assert!(!output.stderr.is_empty());
    value
}

#[test]
fn start_launches_pi_with_the_brief_as_a_system_prompt() {
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna:xhigh",
        b"BRIEF-TEXT-1",
        true,
        "HOLD_TOOL",
        None,
        &[],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let session = &value["session"];
    assert_eq!(session["status"], "running");
    let id = session["id"].as_str().unwrap().to_string();
    assert_eq!(session["activeTurnId"], "pi-turn-1");
    assert!(session["museSessionId"].is_null(), "{session}");

    let pi_dir = h.root().join(&id).join("pi");
    let brief_path = h.root().join(&id).join("brief.txt");
    let expected =
        delegate::session::pi::host_argv("openai/gpt-6-luna:xhigh", &id, &pi_dir, &brief_path);
    let argv = std::fs::read_to_string(h.fake_dir.join("argv.txt")).unwrap();
    let argv: Vec<String> = argv.lines().map(str::to_string).collect();
    assert_eq!(argv, expected);
    assert_eq!(
        std::fs::read(h.fake_dir.join("append-prompt.txt")).unwrap(),
        b"BRIEF-TEXT-1"
    );

    let requests = h.requests();
    assert!(requests.len() >= 3, "{requests:?}");
    assert_eq!(requests[0]["type"], "set_model");
    assert_eq!(requests[0]["provider"], "openai");
    assert_eq!(requests[0]["modelId"], "gpt-6-luna");
    assert_eq!(requests[1]["type"], "set_thinking_level");
    assert_eq!(requests[1]["level"], "xhigh");
    assert_eq!(requests[2]["type"], "prompt");
    assert_eq!(requests[2]["message"], TRIGGER);
    assert!(requests[2].get("streamingBehavior").is_none());
    for request in &requests {
        if request["type"] == "prompt" {
            let message = request["message"].as_str().unwrap_or_default();
            assert!(!message.contains("BRIEF-TEXT-1"), "{request}");
        }
    }

    let mode = std::fs::metadata(&pi_dir).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700);

    let tty = std::fs::read_to_string(h.fake_dir.join("tty.txt")).unwrap();
    for line in [
        "stdin-tty=False",
        "stdout-tty=False",
        "stderr-tty=False",
        "TERM-set=False",
    ] {
        assert!(tty.contains(line), "{tty}");
    }

    let host_pid = session["hostPid"].as_i64().unwrap();
    let spawn = std::fs::read_to_string(h.root().join(&id).join("host-spawn.pid")).unwrap();
    let mut lines = spawn.lines();
    assert_eq!(lines.next().unwrap(), host_pid.to_string());
    let recorded_start = lines.next().unwrap();
    assert!(!recorded_start.is_empty());
    let output = Command::new("ps")
        .args(["-o", "lstart=", "-p", &host_pid.to_string()])
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        recorded_start
    );

    std::fs::write(h.fake_dir.join("go"), "").unwrap();
}

#[test]
fn bad_model_fails_start_before_any_prompt() {
    let h = Harness::new();
    let started = h.start_pi("openai/no-such-model", b"B", true, "BADMODEL", None, &[]);
    let value = assert_json_error(&started, 1, "failed");
    let message = value["error"]["message"].as_str().unwrap();
    assert!(message.contains("Model not found"), "{message}");

    let requests = h.requests();
    assert!(
        requests
            .iter()
            .any(|request| request["type"] == "set_model"),
        "{requests:?}"
    );
    assert!(
        requests.iter().all(|request| request["type"] != "prompt"),
        "{requests:?}"
    );
    assert!(
        std::fs::read(h.fake_dir.join("host.pid")).is_ok(),
        "the fake never started"
    );

    let id = h.only_session();
    let state = h.wait_state(&id, "dead session", |value| value["status"] == "dead");
    assert_eq!(state["dead"]["reason"], "startFailed");
    let host_pid = state["hostPid"].as_i64().unwrap() as i32;
    h.assert_process_gone(host_pid);
}

fn cassette() -> String {
    [
        "prompt-basic.jsonl",
        "prompt-tools.jsonl",
        "steer-abort.jsonl",
        "after-abort.jsonl",
    ]
    .into_iter()
    .map(|name| format!("{FIXTURES}/{name}"))
    .collect::<Vec<_>>()
    .join(":")
}

fn send_started(h: &Harness, id: &str, text: &str) {
    let sent = h.invoke(&["send", id, text, "--json"]);
    assert!(
        sent.status.success(),
        "{}",
        String::from_utf8_lossy(&sent.stderr)
    );
    let reply: Value = serde_json::from_slice(&sent.stdout).unwrap();
    assert_eq!(reply["disposition"], "started", "{reply}");
}

fn watch_ok(h: &Harness, id: &str) {
    let watched = h.invoke(&["watch", id, "--json"]);
    assert!(
        watched.status.success(),
        "{}",
        String::from_utf8_lossy(&watched.stderr)
    );
}

#[test]
fn ui_dialog_requests_are_refused_and_other_ui_records_ignored() {
    let h = Harness::new();
    let started = h.start_pi("openai/gpt-6-luna", b"BRIEF", true, "DIALOG", None, &[]);
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();
    watch_ok(&h, &id);

    let requests = h.wait_requests("the dialog refusal", |requests| {
        requests.iter().any(|request| {
            request["type"] == "extension_ui_response"
                && request["id"] == "ui-1"
                && request["cancelled"] == true
        })
    });
    assert!(
        requests.iter().any(|request| request
            == &serde_json::json!({"type":"extension_ui_response","id":"ui-1","cancelled":true})),
        "{requests:?}"
    );

    let logs = h.logs(&id);
    let refused: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "host.refused")
        .collect();
    assert_eq!(refused.len(), 1);
    assert_eq!(refused[0]["method"], "select");
    assert!(
        logs.iter()
            .all(|line| !line.to_string().contains("notify") && !line.to_string().contains("ui-2")),
        "{logs:?}"
    );
    assert_eq!(h.state(&id)["status"], "idle");
}

#[test]
fn recorded_pi_lifecycle_replays_through_the_session_verbs() {
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "OK",
        Some(&cassette()),
        &[("DELEGATE_SESSION_STEER_REPLY_WAIT_MS", "100")],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    watch_ok(&h, &id);
    let state = h.state(&id);
    assert_eq!(state["status"], "idle");
    assert_eq!(state["lastTurn"]["terminal"], "completed");
    assert_eq!(state["turnCount"], 1);
    assert_eq!(state["usage"]["promptTokens"], 1909);
    assert_eq!(state["usage"]["outputTokens"], 17);
    assert_eq!(state["usage"]["totalTokens"], 1926);

    let listed = h.invoke(&["list", "--json"]);
    assert!(listed.status.success());
    let sessions: Value = serde_json::from_slice(&listed.stdout).unwrap();
    let entry = sessions["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["id"] == id)
        .cloned()
        .unwrap();
    assert_eq!(entry["model"], "openai/gpt-6-luna");

    send_started(&h, &id, "run tools");
    watch_ok(&h, &id);
    let state = h.state(&id);
    assert_eq!(state["turnCount"], 2);
    assert_eq!(state["usage"]["totalTokens"], 7495);
    let logs = h.logs(&id);
    assert_eq!(
        logs.iter()
            .filter(|line| line["kind"] == "tool.started")
            .count(),
        2
    );
    assert_eq!(
        logs.iter()
            .filter(|line| line["kind"] == "tool.completed" && line["status"] == "completed")
            .count(),
        2
    );
    assert_eq!(
        logs.iter()
            .filter(|line| line["kind"] == "turn.completed")
            .count(),
        2
    );

    send_started(&h, &id, "sleep");
    assert_eq!(h.state(&id)["status"], "running");

    let steered = h.invoke(&["send", &id, "steer me", "--json"]);
    assert!(steered.status.success());
    let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
    assert_eq!(reply["disposition"], "unconfirmed", "{reply}");
    assert!(
        h.logs(&id)
            .iter()
            .filter(|line| line["kind"] == "user")
            .all(|line| line["text"] != "steer me")
    );

    let stopped = h.invoke(&["stop", &id, "--interrupt", "--json"]);
    assert!(stopped.status.success());
    let reply: Value = serde_json::from_slice(&stopped.stdout).unwrap();
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["interrupted"], true);

    let requests = h.requests();
    assert_eq!(requests[0]["type"], "set_model");
    let steer_at = requests
        .iter()
        .position(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") == Some(&Value::from("steer"))
        })
        .unwrap();
    assert_eq!(requests[steer_at + 1]["type"], "clear_queue");
    assert_eq!(requests[steer_at + 2]["type"], "abort");

    let state = h.state(&id);
    assert_eq!(state["status"], "idle");
    assert_eq!(state["lastTurn"]["terminal"], "cancelled");
    let logs = h.logs(&id);
    let unconsumed: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "steer.unconsumed")
        .collect();
    assert_eq!(unconsumed.len(), 1);
    let named = unconsumed[0]["commandIds"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert_eq!(named.len(), 1);
    assert!(named[0].as_str().is_some_and(|id| !id.is_empty()));
    assert!(
        unsafe { libc::kill(state["hostPid"].as_i64().unwrap() as i32, 0) } == 0,
        "host died across the interrupt"
    );

    send_started(&h, &id, "again");
    watch_ok(&h, &id);
    let state = h.state(&id);
    assert_eq!(state["turnCount"], 4);
    assert_eq!(state["usage"]["promptTokens"], 12648);
    assert_eq!(state["usage"]["outputTokens"], 1037);
    assert_eq!(state["usage"]["totalTokens"], 13685);

    assert!(!h.fake_dir.join("mismatch.txt").exists());
    h.notes_poll(&id, "idle", 4);

    let stopped = h.invoke(&["stop", &id, "--json"]);
    assert!(stopped.status.success());
    let state = h.state(&id);
    assert_eq!(state["status"], "dead");
    assert_eq!(state["dead"]["reason"], "stopped");
    assert_eq!(state["dead"]["exitCode"], 0);
    assert_eq!(h.invoke(&["watch", &id]).status.code(), Some(4));
}

#[test]
fn steer_queued_during_a_tool_call_reaches_the_next_continuation() {
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_TOOL",
        None,
        &[("DELEGATE_SESSION_STEER_REPLY_WAIT_MS", "100")],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    h.wait_file("tool.paused", "the held tool call");
    let steered = h.invoke(&["send", &id, "STEER-1", "--json"]);
    assert!(steered.status.success());
    let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
    assert_eq!(reply["disposition"], "unconfirmed", "{reply}");
    let pending = h.state(&id)["pendingSteers"].as_array().unwrap().clone();
    assert_eq!(pending.len(), 1, "{pending:?}");
    assert_eq!(reply["commandId"], pending[0]["commandId"], "{reply}");

    let requests = h.requests();
    let steer_at = requests
        .iter()
        .position(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") == Some(&Value::from("steer"))
        })
        .unwrap();
    assert_eq!(requests[steer_at]["message"], "STEER-1");
    let queue = std::fs::read_to_string(h.fake_dir.join("queue.txt")).unwrap();
    assert!(queue.lines().any(|line| line == "STEER-1"), "{queue}");
    assert!(
        h.logs(&id)
            .iter()
            .filter(|line| line["kind"] == "user")
            .all(|line| line["text"] != "STEER-1")
    );
    assert_eq!(h.state(&id)["status"], "running");

    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    watch_ok(&h, &id);

    let logs = h.logs(&id);
    let completed_at = logs
        .iter()
        .position(|line| line["kind"] == "tool.completed")
        .unwrap();
    let user_at = logs
        .iter()
        .position(|line| line["kind"] == "user" && line["text"] == "STEER-1")
        .unwrap();
    assert!(logs[user_at]["commandId"].is_string());
    let saw_at = logs
        .iter()
        .position(|line| line["kind"] == "message" && line["text"] == "saw: STEER-1")
        .unwrap();
    let done_at = logs
        .iter()
        .position(|line| line["kind"] == "turn.completed")
        .unwrap();
    assert!(completed_at < user_at && user_at < saw_at && saw_at < done_at);
    assert!(
        logs.iter().all(|line| line["kind"] != "steer.unconsumed"),
        "{logs:?}"
    );
    assert!(
        logs.iter().all(|line| line["kind"] != "steer.replayed"),
        "a normally consumed steer must not be replayed: {logs:?}"
    );
    let delivered = std::fs::read_to_string(h.fake_dir.join("delivered.txt")).unwrap();
    assert_eq!(
        delivered.lines().filter(|line| *line == "STEER-1").count(),
        1
    );
}

#[test]
fn unconsumed_pi_steers_replay_in_order_after_the_turn_ends() {
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_REPLAY,REPLAY_UNCONSUMED",
        None,
        &[("DELEGATE_SESSION_STEER_REPLY_WAIT_MS", "100")],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    h.wait_file("tool.paused", "the held tool call");
    for text in ["REPLAY-ONE", "REPLAY-TWO"] {
        let steered = h.invoke(&["send", &id, text, "--json"]);
        assert!(
            steered.status.success(),
            "{}",
            String::from_utf8_lossy(&steered.stderr)
        );
        let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
        assert_eq!(reply["disposition"], "unconfirmed", "{reply}");
    }

    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    watch_ok(&h, &id);
    let logs = h.logs(&id);
    let replayed: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "steer.replayed")
        .collect();
    assert_eq!(replayed.len(), 1, "{logs:?}");
    let command_ids = replayed[0]["commandIds"].as_array().unwrap();
    assert_eq!(command_ids.len(), 2, "{replayed:?}");
    let replay_text = "REPLAY-ONE\n\nREPLAY-TWO";
    assert_eq!(
        logs.iter()
            .filter(|line| line["kind"] == "user" && line["text"] == replay_text)
            .count(),
        1,
        "{logs:?}"
    );
    assert_eq!(h.state(&id)["turnCount"], 2);
    assert!(
        logs.iter().all(|line| line["kind"] != "steer.unconsumed"),
        "{logs:?}"
    );
}

#[test]
fn all_queued_pi_steers_become_unconsumed_if_no_continuation_starts() {
    let h = Harness::new();
    let continuation_wait_marker = h.base.join("continuation-wait-started");
    let continuation_wait_marker_env = continuation_wait_marker.to_str().unwrap();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_TOOL,NO_CONTINUATION",
        None,
        &[
            ("DELEGATE_SESSION_PI_CONTINUATION_WAIT_MS", "150"),
            (
                "DELEGATE_SESSION_TEST_CONTINUATION_WAIT_FILE",
                continuation_wait_marker_env,
            ),
        ],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    h.wait_file("tool.paused", "the held tool call");
    let (steered, command_id) = std::thread::scope(|scope| {
        let send = scope.spawn(|| h.invoke(&["send", &id, "NEVER-CONTINUE", "--json"]));
        h.wait_path(&h.fake_dir.join("queue.txt"), "pi to accept the steer");
        let pending = h.state(&id)["pendingSteers"].as_array().unwrap().clone();
        assert_eq!(pending.len(), 1, "{pending:?}");
        let command_id = pending[0]["commandId"].as_str().unwrap().to_string();

        std::fs::write(h.fake_dir.join("go"), "").unwrap();
        let sent = send.join().unwrap();
        (sent, command_id)
    });
    assert!(
        steered.status.success(),
        "{}",
        String::from_utf8_lossy(&steered.stderr)
    );
    let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
    assert_eq!(reply["disposition"], "unconsumed", "{reply}");

    h.wait_path(&continuation_wait_marker, "the continuation wait to start");
    let idle = h.wait_state(&id, "idle after continuation deadline", |state| {
        state["status"] == "idle"
    });
    assert!(idle["pendingSteers"].as_array().unwrap().is_empty());
    h.notes_poll(&id, "idle", 1);

    let logs = h.logs(&id);
    let unconsumed: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "steer.unconsumed")
        .collect();
    assert_eq!(unconsumed.len(), 1, "{logs:?}");
    assert_eq!(unconsumed[0]["commandIds"], serde_json::json!([command_id]));
    let completed_at = logs
        .iter()
        .position(|line| line["kind"] == "turn.completed")
        .unwrap();
    let unconsumed_at = logs
        .iter()
        .position(|line| line["kind"] == "steer.unconsumed")
        .unwrap();
    assert!(completed_at < unconsumed_at, "{logs:?}");
    assert!(
        logs.iter().all(|line| line["kind"] != "steer.replayed"),
        "{logs:?}"
    );
    assert_eq!(h.notes(&id, "idle").len(), 1);
}

#[test]
fn pi_clears_queued_steers_before_a_late_continuation_can_start() {
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_TOOL,NO_CONTINUATION,LATE_CONTINUATION",
        None,
        &[
            ("DELEGATE_SESSION_PI_CONTINUATION_WAIT_MS", "150"),
            ("DELEGATE_SESSION_STEER_REPLY_WAIT_MS", "100"),
        ],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    h.wait_file("tool.paused", "the held tool call");
    let steered = h.invoke(&["send", &id, "LATE-STEER", "--json"]);
    assert!(steered.status.success());
    let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
    assert_eq!(reply["disposition"], "unconfirmed", "{reply}");

    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    let idle = h.wait_state(&id, "idle after continuation deadline", |state| {
        state["status"] == "idle"
    });
    assert!(idle["pendingSteers"].as_array().unwrap().is_empty());
    h.notes_poll(&id, "idle", 1);
    h.wait_file(
        "late_continuation_waiting",
        "the fake pi's late continuation mode",
    );

    std::fs::write(h.fake_dir.join("late_continue"), "").unwrap();
    h.wait_file(
        "late_continuation_cleared",
        "the fake pi's late continuation check",
    );
    assert_eq!(h.state(&id)["status"], "idle");
    assert_eq!(h.state(&id)["turnCount"], 1);
    assert_eq!(h.notes(&id, "idle").len(), 1);

    let requests = h.requests();
    let steer_at = requests
        .iter()
        .position(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") == Some(&Value::from("steer"))
        })
        .unwrap();
    assert_eq!(
        requests[steer_at + 1]["type"],
        "clear_queue",
        "{requests:?}"
    );
    let logs = h.logs(&id);
    assert_eq!(
        logs.iter()
            .filter(|line| line["kind"] == "steer.unconsumed")
            .count(),
        1,
        "{logs:?}"
    );
    assert!(
        logs.iter()
            .all(|line| { !(line["kind"] == "user" && line["text"] == "LATE-STEER") }),
        "the cleared steer must not be delivered by a late turn: {logs:?}"
    );
}

#[test]
fn stopping_during_pi_continuation_wait_does_not_publish_idle() {
    let h = Harness::new();
    let continuation_wait_marker = h.base.join("continuation-wait-started");
    let continuation_wait_marker_env = continuation_wait_marker.to_str().unwrap();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_TOOL,NO_CONTINUATION",
        None,
        &[
            (
                "DELEGATE_SESSION_TEST_CONTINUATION_WAIT_FILE",
                continuation_wait_marker_env,
            ),
            ("DELEGATE_SESSION_STEER_REPLY_WAIT_MS", "100"),
        ],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    h.wait_file("tool.paused", "the held tool call");
    let steered = h.invoke(&["send", &id, "STOP-DURING-WAIT", "--json"]);
    assert!(steered.status.success());
    let pending = h.state(&id)["pendingSteers"].as_array().unwrap().clone();
    assert_eq!(pending.len(), 1);
    let command_id = pending[0]["commandId"].as_str().unwrap();
    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    h.wait_path(&continuation_wait_marker, "the continuation wait to start");

    let stopped = h.invoke_with_timeout(
        &["stop", &id, "--interrupt", "--json"],
        None,
        "",
        None,
        &[],
        Duration::from_secs(30),
    );
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    let reply: Value = serde_json::from_slice(&stopped.stdout).unwrap();
    assert_eq!(reply["interrupted"], true, "{reply}");
    assert_eq!(h.state(&id)["status"], "idle");
    assert!(
        h.notes(&id, "idle").is_empty(),
        "the continuation wait must not publish an idle note when stop owns the session"
    );
    let logs = h.logs(&id);
    let unconsumed: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "steer.unconsumed")
        .collect();
    assert_eq!(unconsumed.len(), 1, "{logs:?}");
    assert_eq!(unconsumed[0]["commandIds"], serde_json::json!([command_id]));
}

#[test]
fn mixed_pi_queue_replays_only_dropped_steer_after_continuation() {
    let h = Harness::new();
    let release_event_write = h.base.join("release-event-write");
    let release_event_write_env = release_event_write.to_str().unwrap();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_REPLAY,REPLAY_MIXED",
        None,
        &[
            ("DELEGATE_SESSION_STEER_REPLY_WAIT_MS", "100"),
            (
                "DELEGATE_SESSION_TEST_HOLD_EVENT_WRITE_UNTIL",
                release_event_write_env,
            ),
            (
                "DELEGATE_SESSION_TEST_HOLD_EVENT_WRITE_TURN_ID",
                "pi-turn-2",
            ),
            (
                "DELEGATE_SESSION_TEST_HOLD_EVENT_WRITE_KIND",
                "turn.started",
            ),
        ],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    h.wait_file("tool.paused", "the held tool call");
    for text in ["MIXED-S1", "MIXED-S2"] {
        let steered = h.invoke(&["send", &id, text, "--json"]);
        assert!(
            steered.status.success(),
            "{}",
            String::from_utf8_lossy(&steered.stderr)
        );
        let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
        assert_eq!(reply["disposition"], "unconfirmed", "{reply}");
    }
    let pending = h.state(&id)["pendingSteers"].as_array().unwrap().clone();
    assert_eq!(pending.len(), 2, "{pending:?}");
    let s2_id = pending[1]["commandId"].as_str().unwrap().to_string();

    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    let held_marker = std::path::PathBuf::from(format!("{}.held", release_event_write.display()));
    h.wait_path(&held_marker, "pi continuation start event hold");
    let ordinary_starts = h
        .requests()
        .iter()
        .filter(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") != Some(&Value::from("steer"))
        })
        .count();
    assert_eq!(
        ordinary_starts,
        1,
        "unexpected replay during continuation start: {:?}",
        h.requests()
    );

    std::fs::write(&release_event_write, "").unwrap();
    watch_ok(&h, &id);
    let logs = h.logs(&id);
    let replayed: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "steer.replayed")
        .collect();
    assert_eq!(replayed.len(), 1, "{logs:?}");
    assert_eq!(
        replayed[0]["commandIds"],
        serde_json::json!([s2_id]),
        "{replayed:?}"
    );
    let s1_delivery = logs
        .iter()
        .position(|line| line["kind"] == "user" && line["text"] == "MIXED-S1")
        .unwrap();
    let s2_delivery = logs
        .iter()
        .position(|line| line["kind"] == "user" && line["text"] == "MIXED-S2")
        .unwrap();
    assert!(s1_delivery < s2_delivery, "{logs:?}");
    assert_eq!(
        logs.iter()
            .filter(|line| line["kind"] == "user" && line["text"] == "MIXED-S1")
            .count(),
        1,
        "{logs:?}"
    );
    assert_eq!(
        logs.iter()
            .filter(|line| line["kind"] == "user" && line["text"] == "MIXED-S2")
            .count(),
        1,
        "{logs:?}"
    );
    let continuation_done = logs
        .iter()
        .position(|line| line["kind"] == "turn.completed" && line["turnId"] == "pi-turn-2")
        .unwrap();
    let replayed_at = logs
        .iter()
        .position(|line| line["kind"] == "steer.replayed")
        .unwrap();
    assert!(continuation_done < replayed_at, "{logs:?}");
    let delivered = std::fs::read_to_string(h.fake_dir.join("delivered.txt")).unwrap();
    assert_eq!(delivered, "MIXED-S1\n");
    assert_eq!(h.state(&id)["turnCount"], 3);
    let requests = h.requests();
    let replay_turn_starts: Vec<&Value> = requests
        .iter()
        .filter(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") != Some(&Value::from("steer"))
        })
        .collect();
    assert_eq!(replay_turn_starts.len(), 2, "{requests:?}");
    assert_eq!(replay_turn_starts[1]["message"], "MIXED-S2");
    let ordinary_starts = requests
        .iter()
        .filter(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") != Some(&Value::from("steer"))
        })
        .count();
    assert_eq!(
        ordinary_starts,
        2,
        "one initial start plus the S2 replay: {:?}",
        h.requests()
    );
}

#[test]
fn pending_steer_replay_stays_busy_while_send_holds_admission() {
    const REPLAY_TEXT: &str = "STEER-LOCKED";
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_REPLAY,REPLAY_UNCONSUMED,REPLAY_SEND_HOLD",
        None,
        &[],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();
    h.wait_file("tool.paused", "the held tool call");

    let (send_tx, send_rx) = mpsc::channel();
    let (watch_tx, watch_rx) = mpsc::channel();
    std::thread::scope(|scope| {
        let send_h = &h;
        let send_id = &id;
        scope.spawn(move || {
            send_tx
                .send(send_h.invoke(&["send", send_id, REPLAY_TEXT, "--json"]))
                .unwrap();
        });

        h.wait_file(
            "steer.paused",
            "send holding admission across turn completion",
        );
        let completed = h.wait_state(&id, "held send turn completion", |state| {
            state["lastTurn"]["turnId"] == "pi-turn-1"
        });
        let busy_after_completion = completed["status"] == "running";

        let watch_h = &h;
        let watch_id = &id;
        let watch_ready = h.fake_dir.join("watch.ready");
        let watch_ready = watch_ready.to_str().unwrap().to_string();
        scope.spawn(move || {
            watch_tx
                .send(watch_h.invoke_with(
                    &["watch", watch_id, "--json"],
                    None,
                    "",
                    None,
                    &[("DELEGATE_SESSION_TEST_WATCH_READY", &watch_ready)],
                ))
                .unwrap();
        });
        h.wait_file("watch.ready", "watch waiting through replay");

        std::fs::write(h.fake_dir.join("steer.release"), "").unwrap();
        let sent = send_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("send did not release admission");
        assert!(
            sent.status.success(),
            "{}",
            String::from_utf8_lossy(&sent.stderr)
        );
        let sent: Value = serde_json::from_slice(&sent.stdout).unwrap();
        assert_eq!(sent["disposition"], "steered", "{sent}");

        h.wait_file("replay-start.paused", "the replay turn start request");
        let replay_start_state = h.state(&id);
        let busy_before_replay_start = replay_start_state["status"] == "running";

        std::fs::write(h.fake_dir.join("replay-start.go"), "").unwrap();
        h.wait_state(&id, "replay turn completion", |state| {
            state["status"] == "idle" && state["turnCount"] == 2
        });
        let watched = watch_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("watch did not return after the replay turn completed");
        assert!(
            watched.status.success(),
            "{}",
            String::from_utf8_lossy(&watched.stderr)
        );

        let logs = h.logs(&id);
        assert_eq!(
            logs.iter()
                .filter(|line| line["kind"] == "steer.replayed")
                .count(),
            1,
            "{logs:?}"
        );
        assert_eq!(
            logs.iter()
                .filter(|line| line["kind"] == "user" && line["text"] == REPLAY_TEXT)
                .count(),
            1,
            "{logs:?}"
        );
        assert_eq!(h.state(&id)["turnCount"], 2);
        h.notes_poll(&id, "idle", 1);

        assert!(
            busy_after_completion,
            "completion published idle while the send still held admission: {completed}"
        );
        assert!(
            busy_before_replay_start,
            "replay decision published idle before its turn started: {replay_start_state}"
        );
    });
}

#[test]
fn interrupt_during_pending_replay_cancels_without_starting_replay() {
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_REPLAY,REPLAY_UNCONSUMED,REPLAY_SEND_HOLD",
        None,
        &[],
    );
    assert!(started.status.success());
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();
    h.wait_file("tool.paused", "the held tool call");

    let (send_tx, send_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    std::thread::scope(|scope| {
        let send_h = &h;
        let send_id = &id;
        scope.spawn(move || {
            send_tx
                .send(send_h.invoke(&["send", send_id, "INTERRUPT-ME", "--json"]))
                .unwrap()
        });
        h.wait_file("steer.paused", "send holding admission after completion");
        h.wait_state(&id, "replay-pending completion", |state| {
            state["status"] == "running" && state["activeTurnId"].is_null()
        });
        let stop_h = &h;
        let stop_id = &id;
        scope.spawn(move || {
            stop_tx
                .send(stop_h.invoke(&["stop", stop_id, "--interrupt", "--json"]))
                .unwrap()
        });
        h.wait_state(&id, "interrupt claimed replay-pending session", |state| {
            state["stopping"] == true
        });
        std::fs::write(h.fake_dir.join("steer.release"), "").unwrap();
        let stopped = stop_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("stop did not complete");
        assert!(
            stopped.status.success(),
            "{}",
            String::from_utf8_lossy(&stopped.stderr)
        );
        let reply: Value = serde_json::from_slice(&stopped.stdout).unwrap();
        assert_eq!(reply["interrupted"], true, "{reply}");
        let sent = send_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("send did not complete");
        assert!(
            sent.status.success(),
            "{}",
            String::from_utf8_lossy(&sent.stderr)
        );
        let logs = h.logs(&id);
        assert!(
            logs.iter().all(|line| line["kind"] != "steer.replayed"),
            "{logs:?}"
        );
        let requests = h.requests();
        assert_eq!(
            requests
                .iter()
                .filter(|request| request["type"] == "prompt"
                    && request.get("streamingBehavior") != Some(&Value::from("steer")))
                .count(),
            1,
            "{requests:?}"
        );
    });
}

#[test]
fn interrupt_clears_the_queue_before_abort_and_the_host_survives() {
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "HOLD_TOOL",
        None,
        &[("DELEGATE_SESSION_STEER_REPLY_WAIT_MS", "100")],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    h.wait_file("tool.paused", "the held tool call");
    let steered = h.invoke(&["send", &id, "STEER-2", "--json"]);
    assert!(steered.status.success());
    let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
    assert_eq!(reply["disposition"], "unconfirmed", "{reply}");

    let stopped = h.invoke(&["stop", &id, "--interrupt", "--json"]);
    assert!(stopped.status.success());
    let reply: Value = serde_json::from_slice(&stopped.stdout).unwrap();
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["interrupted"], true);

    let requests = h.requests();
    let steer_at = requests
        .iter()
        .position(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") == Some(&Value::from("steer"))
        })
        .unwrap();
    assert_eq!(requests[steer_at + 1]["type"], "clear_queue");
    assert_eq!(requests[steer_at + 2]["type"], "abort");

    let cleared = std::fs::read_to_string(h.fake_dir.join("cleared.txt")).unwrap();
    let cleared: Vec<Value> = cleared
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    assert!(
        cleared
            .iter()
            .any(|list| list == &Value::from(vec![Value::from("STEER-2")])),
        "{cleared:?}"
    );

    let logs = h.logs(&id);
    let cancelled: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "turn.completed" && line["terminal"] == "cancelled")
        .collect();
    assert_eq!(cancelled.len(), 1);
    assert_eq!(
        logs.iter()
            .filter(|line| line["kind"] == "steer.unconsumed")
            .count(),
        1
    );
    assert!(
        logs.iter()
            .filter(|line| line["kind"] == "user")
            .all(|line| line["text"] != "STEER-2")
    );
    let delivered = std::fs::read_to_string(h.fake_dir.join("delivered.txt")).unwrap_or_default();
    assert!(
        !delivered.lines().any(|line| line == "STEER-2"),
        "{delivered}"
    );

    let state = h.state(&id);
    assert_eq!(state["status"], "idle");
    assert!(
        unsafe { libc::kill(state["hostPid"].as_i64().unwrap() as i32, 0) } == 0,
        "host died across the interrupt"
    );
    assert!(
        !h.fake_dir.join("tool.paused").exists(),
        "the abort left a stale pause marker"
    );

    send_started(&h, &id, "next");
    h.wait_file("tool.paused", "the second held tool call");
    let steered = h.invoke(&["send", &id, "STEER-4", "--json"]);
    assert!(steered.status.success());
    let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
    assert_eq!(reply["disposition"], "unconfirmed", "{reply}");

    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    watch_ok(&h, &id);

    let logs = h.logs(&id);
    let user_at = logs
        .iter()
        .position(|line| line["kind"] == "user" && line["text"] == "STEER-4")
        .unwrap();
    assert!(logs[user_at]["commandId"].is_string());
    assert!(
        logs.iter()
            .filter(|line| line["kind"] == "user")
            .all(|line| line["text"] != "STEER-2")
    );
    let delivered = std::fs::read_to_string(h.fake_dir.join("delivered.txt")).unwrap();
    assert!(
        delivered.lines().any(|line| line == "STEER-4"),
        "{delivered}"
    );
    assert!(
        !delivered.lines().any(|line| line == "STEER-2"),
        "{delivered}"
    );
}

#[test]
fn pi_failures_map_to_the_existing_contracts() {
    // (i) A missing pi binary is a spawn error: start fails, the session is
    // dead/startFailed.
    {
        let h = Harness::new();
        let started = h.start_pi(
            "openai/gpt-6-luna",
            b"B",
            true,
            "",
            None,
            &[("PI_BIN", "/nonexistent/pi")],
        );
        let value = assert_json_error(&started, 1, "failed");
        let message = value["error"]["message"].as_str().unwrap();
        assert!(message.contains("No such file or directory"), "{message}");
        let id = h.only_session();
        let state = h.wait_state(&id, "dead session", |value| value["status"] == "dead");
        assert_eq!(state["dead"]["reason"], "startFailed");
    }
    // (ii) A host that exits at startup fails the start fast with the EOF
    // text, and its stderr line is kept.
    {
        let h = Harness::new();
        let started = h.start_pi("openai/gpt-6-luna", b"B", true, "EXIT_AT_START", None, &[]);
        let value = assert_json_error(&started, 1, "failed");
        let message = value["error"]["message"].as_str().unwrap();
        assert!(message.contains("pi host"), "{message}");
        let id = h.only_session();
        let stderr = std::fs::read_to_string(h.root().join(&id).join("host.stderr")).unwrap();
        assert!(stderr.contains("fake host starting"), "{stderr}");
    }
    // (iii) A host that dies mid-session leaves a dead/hostExited session.
    {
        let h = Harness::new();
        let started = h.start_pi("openai/gpt-6-luna", b"B", true, "DIE", None, &[]);
        assert!(started.status.success());
        let value: Value = serde_json::from_slice(&started.stdout).unwrap();
        let id = value["session"]["id"].as_str().unwrap().to_string();
        watch_ok(&h, &id);
        send_started(&h, &id, "second");
        assert_eq!(h.invoke(&["watch", &id]).status.code(), Some(4));
        let state = h.state(&id);
        assert_eq!(state["status"], "dead");
        assert_eq!(state["dead"]["reason"], "hostExited");
        assert_eq!(state["dead"]["exitCode"], 3);
    }
    // (iv) A prompt the host handles without starting a run fails the send
    // and leaves the session idle with its turn count unchanged.
    {
        let h = Harness::new();
        let started = h.start_pi("openai/gpt-6-luna", b"B", true, "HANDLED", None, &[]);
        assert!(started.status.success());
        let value: Value = serde_json::from_slice(&started.stdout).unwrap();
        let id = value["session"]["id"].as_str().unwrap().to_string();
        watch_ok(&h, &id);
        assert_eq!(h.state(&id)["turnCount"], 1);
        let sent = h.invoke(&["send", &id, "second", "--json"]);
        assert_json_error(&sent, 1, "failed");
        let state = h.state(&id);
        assert_eq!(state["status"], "idle");
        assert_eq!(state["turnCount"], 1);
    }
    // (v) A prompt the host refuses fails the send the same way.
    {
        let h = Harness::new();
        let started = h.start_pi("openai/gpt-6-luna", b"B", true, "PROMPT_FAIL", None, &[]);
        assert!(started.status.success());
        let value: Value = serde_json::from_slice(&started.stdout).unwrap();
        let id = value["session"]["id"].as_str().unwrap().to_string();
        watch_ok(&h, &id);
        let sent = h.invoke(&["send", &id, "second", "--json"]);
        assert_json_error(&sent, 1, "failed");
        let state = h.state(&id);
        assert_eq!(state["status"], "idle");
        assert_eq!(state["turnCount"], 1);
    }
    // (vi) A non-JSON stdout line is logged as unparsed and the session
    // still completes.
    {
        let h = Harness::new();
        let started = h.start_pi("openai/gpt-6-luna", b"B", true, "NOISE", None, &[]);
        assert!(started.status.success());
        let value: Value = serde_json::from_slice(&started.stdout).unwrap();
        let id = value["session"]["id"].as_str().unwrap().to_string();
        watch_ok(&h, &id);
        let logs = h.logs(&id);
        let unparsed: Vec<&Value> = logs
            .iter()
            .filter(|line| line["kind"] == "host.unparsed")
            .collect();
        assert_eq!(unparsed.len(), 1);
        let line = unparsed[0]["line"].as_str().unwrap();
        assert!(line.len() <= 200, "{line}");
        assert_eq!(h.state(&id)["status"], "idle");
    }
    // (vii) A host that never answers set_model fails the start on the boot
    // bound, naming the method; a host that answers set_model but never
    // set_thinking_level fails on the shared deadline, naming the second
    // call.
    {
        let h = Harness::new();
        let started = h.start_pi(
            "openai/gpt-6-luna",
            b"B",
            true,
            "SLOW_BOOT",
            None,
            &[("DELEGATE_SESSION_PI_BOOT_WAIT_MS", "300")],
        );
        let value = assert_json_error(&started, 1, "failed");
        let message = value["error"]["message"].as_str().unwrap();
        assert!(message.contains("model/set"), "{message}");
        let id = h.only_session();
        let state = h.wait_state(&id, "dead session", |value| value["status"] == "dead");
        assert_eq!(state["dead"]["reason"], "startFailed");
        assert!(
            h.requests()
                .iter()
                .all(|request| request["type"] != "prompt"),
            "a prompt was sent before the boot bound fired"
        );
    }
    {
        let h = Harness::new();
        let begin = Instant::now();
        let started = h.start_pi(
            "openai/gpt-6-luna:high",
            b"B",
            true,
            "SLOW_THINK",
            None,
            &[("DELEGATE_SESSION_PI_BOOT_WAIT_MS", "3000")],
        );
        let elapsed = begin.elapsed();
        let value = assert_json_error(&started, 1, "failed");
        let message = value["error"]["message"].as_str().unwrap();
        assert!(message.contains("thinking/set"), "{message}");
        assert!(!message.contains("model/set"), "{message}");
        assert!(
            elapsed < Duration::from_millis(4500),
            "shared boot deadline not applied: {elapsed:?}"
        );
        assert!(
            h.requests()
                .iter()
                .all(|request| request["type"] != "prompt"),
            "a prompt was sent before the boot bound fired"
        );
    }
    // (viii) A send text starting with `/` is rejected for pi before any
    // prompt is sent; leading whitespace is sent as-is.
    {
        let h = Harness::new();
        let started = h.start_pi("openai/gpt-6-luna", b"B", true, "", None, &[]);
        assert!(started.status.success());
        let value: Value = serde_json::from_slice(&started.stdout).unwrap();
        let id = value["session"]["id"].as_str().unwrap().to_string();
        watch_ok(&h, &id);
        for text in ["/skill:x", "/help"] {
            let sent = h.invoke(&["send", &id, text, "--json"]);
            let value = assert_json_error(&sent, 2, "usage");
            let message = value["error"]["message"].as_str().unwrap();
            assert!(message.contains("/skill"), "{message}");
            assert!(message.contains("extension"), "{message}");
        }
        assert_eq!(
            h.requests()
                .iter()
                .filter(|request| request["type"] == "prompt")
                .count(),
            1
        );
        send_started(&h, &id, " /x");
        watch_ok(&h, &id);
        assert_eq!(h.state(&id)["turnCount"], 2);
    }
}

#[test]
fn steer_racing_the_end_of_a_turn_starts_the_next_turn() {
    let h = Harness::new();
    let release_event_write = h.base.join("release-event-write");
    let release_event_write_env = release_event_write.to_str().unwrap();
    let continuation_wait_marker = h.base.join("continuation-wait-started");
    let continuation_wait_marker_env = continuation_wait_marker.to_str().unwrap();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "STEER_RACE",
        None,
        &[
            ("DELEGATE_SESSION_STEER_REPLY_WAIT_MS", "100"),
            (
                "DELEGATE_SESSION_TEST_HOLD_EVENT_WRITE_UNTIL",
                release_event_write_env,
            ),
            (
                "DELEGATE_SESSION_TEST_HOLD_EVENT_WRITE_TURN_ID",
                "pi-turn-2",
            ),
            (
                "DELEGATE_SESSION_TEST_HOLD_EVENT_WRITE_KIND",
                "turn.started",
            ),
            (
                "DELEGATE_SESSION_TEST_CONTINUATION_WAIT_FILE",
                continuation_wait_marker_env,
            ),
        ],
    );
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();

    let steered = h.invoke(&["send", &id, "STEER-3", "--json"]);
    assert!(steered.status.success());
    let reply: Value = serde_json::from_slice(&steered.stdout).unwrap();
    assert_eq!(reply["disposition"], "unconfirmed", "{reply}");

    let held_marker = std::path::PathBuf::from(format!("{}.held", release_event_write.display()));
    h.wait_path(&held_marker, "pi-turn-2 start event append hold");
    h.wait_path(
        &continuation_wait_marker,
        "the continuation wait after the replay decision",
    );
    assert_eq!(
        h.notes(&id, "idle").len(),
        0,
        "idle note appeared before the queued continuation's TurnStarted"
    );
    let ordinary_prompts_before_release = h
        .requests()
        .iter()
        .filter(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") != Some(&Value::from("steer"))
        })
        .count();
    assert_eq!(
        ordinary_prompts_before_release,
        1,
        "replay must not race pi's queued continuation: {:?}",
        h.requests()
    );

    std::fs::write(&release_event_write, "").unwrap();
    h.wait_state(&id, "pi-turn-2 running", |state| {
        state["status"] == "running" && state["activeTurnId"] == "pi-turn-2"
    });
    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    watch_ok(&h, &id);

    let logs = h.logs(&id);
    let replayed: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "steer.replayed")
        .collect();
    assert!(
        replayed.is_empty(),
        "pi-started steer must not replay: {logs:?}"
    );
    assert!(
        logs.iter().all(|line| line["kind"] != "steer.unconsumed"),
        "pi-delivered steer must not be marked unconsumed: {logs:?}"
    );
    let deliveries: Vec<&Value> = logs
        .iter()
        .filter(|line| line["kind"] == "user" && line["text"] == "STEER-3")
        .collect();
    assert_eq!(deliveries.len(), 1, "{logs:?}");
    let started2 = logs
        .iter()
        .position(|line| line["kind"] == "turn.started" && line["turnId"] == "pi-turn-2")
        .unwrap();
    let delivered = logs
        .iter()
        .position(|line| line["kind"] == "user" && line["text"] == "STEER-3")
        .unwrap();
    let done2 = logs
        .iter()
        .position(|line| line["kind"] == "turn.completed" && line["turnId"] == "pi-turn-2")
        .unwrap();
    assert!(started2 < delivered && delivered < done2, "{logs:?}");
    assert_eq!(deliveries[0]["turnId"], "pi-turn-2");
    assert_eq!(
        std::fs::read_to_string(h.fake_dir.join("delivered.txt")).unwrap(),
        "STEER-3\n"
    );
    let replay_prompt_requests = h
        .requests()
        .iter()
        .filter(|request| {
            request["type"] == "prompt"
                && request.get("streamingBehavior") != Some(&Value::from("steer"))
        })
        .count();
    assert_eq!(
        replay_prompt_requests,
        1,
        "{}",
        h.requests()
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\\n")
    );

    assert_eq!(h.state(&id)["turnCount"], 2);
    h.notes_poll(&id, "idle", 1);
}

#[test]
fn pi_that_exits_before_reading_stdin_fails_start_with_the_eof_text() {
    let h = Harness::new();
    let started = h.start_pi("openai/gpt-6-luna", b"B", true, "EXIT_NOW", None, &[]);
    assert_eq!(
        std::fs::read(h.fake_dir.join("stdin-ready")).unwrap(),
        b"",
        "fake host must exit only after initialize bytes are pending, without reading them"
    );
    let value = assert_json_error(&started, 1, "failed");
    let message = value["error"]["message"].as_str().unwrap();
    assert!(message.contains("pi host closed stdout"), "{message}");
    assert!(!message.contains("Broken pipe"), "{message}");
}

#[test]
fn model_shapes_select_the_host() {
    let h = Harness::new();
    for model in [
        "nomodel",
        "/x",
        "x/",
        "a b/c",
        "muse/",
        "codex/x",
        "fiber/x",
        "pi/openai/x",
        "muse/muse-spark-1.3-contributor:high",
    ] {
        let brief = h.brief_file(b"x");
        let result = h.invoke(&[
            "start",
            "--model",
            model,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            h.inbox.to_str().unwrap(),
            "--json",
        ]);
        assert_json_error(&result, 2, "usage");
    }
    assert!(!h.fake_dir.join("requests.jsonl").exists());

    let started = h.start_pi("museish/model", b"plain brief", true, "", None, &[]);
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stderr)
    );
    let requests = h.requests();
    assert_eq!(requests[0]["type"], "set_model");
    assert_eq!(requests[0]["provider"], "museish");
    assert!(
        requests
            .iter()
            .all(|request| request["type"] != "set_thinking_level"),
        "{requests:?}"
    );
    let argv = std::fs::read_to_string(h.fake_dir.join("argv.txt")).unwrap();
    let argv: Vec<String> = argv.lines().map(str::to_string).collect();
    assert!(
        argv.windows(2).any(|pair| pair == ["--mode", "rpc"]),
        "{argv:?}"
    );
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap().to_string();
    let watched = h.invoke(&["watch", &id]);
    assert!(
        watched.status.success(),
        "{}",
        String::from_utf8_lossy(&watched.stderr)
    );
}
