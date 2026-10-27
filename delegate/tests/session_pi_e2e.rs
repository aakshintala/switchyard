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
        let status = wait_cli(&mut child, Duration::from_secs(10), &self.root(), args);
        let stdout = stdout_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("stdout EOF deadline");
        let stderr = stderr_rx
            .recv_timeout(Duration::from_secs(10))
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
        let path = self.fake_dir.join(name);
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
fn recorded_pi_lifecycle_replays_through_the_session_verbs() {
    let h = Harness::new();
    let started = h.start_pi(
        "openai/gpt-6-luna",
        b"BRIEF",
        true,
        "OK",
        Some(&cassette()),
        &[],
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
    assert_eq!(reply["disposition"], "steered", "{reply}");
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
fn pi_that_exits_before_reading_stdin_fails_start_with_the_eof_text() {
    let h = Harness::new();
    let started = h.start_pi("openai/gpt-6-luna", b"B", true, "EXIT_NOW", None, &[]);
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
