//! Drives the real `delegate` binary against a fake Fiber hub.

#[path = "support/model_ruling.rs"]
mod model_ruling;

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const MODEL: &str = "fiber/opencode-go/muse-spark-1.3-contributor";
const REFERENCE: &str = "opencode-go/muse-spark-1.3-contributor";
static NEXT_ENV: AtomicU64 = AtomicU64::new(0);
static NEXT_HUB: AtomicU64 = AtomicU64::new(0);

struct Env {
    dir: PathBuf,
    fiber_home: PathBuf,
}

impl Env {
    fn new(name: &str) -> Self {
        loop {
            let n = NEXT_ENV.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir().join(format!("f682-{name}-{}-{n}", std::process::id()));
            match std::fs::create_dir(&dir) {
                Ok(()) => {
                    let fiber_home = dir.join("fh");
                    std::fs::create_dir(&fiber_home).unwrap();
                    return Self { dir, fiber_home };
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create test directory {}: {error}", dir.display()),
            }
        }
    }

    fn fake_hub(
        &self,
        connections: usize,
        scenario: impl FnMut(usize, &str, &mut FakeConn) + Send + 'static,
    ) -> FakeHub {
        FakeHub::new(&self.fiber_home, connections, scenario)
    }

    fn command(&self, args: &[&str], stdin: Option<&str>, fiber_bin: bool) -> Output {
        self.command_with_env(args, stdin, fiber_bin, &[])
    }

    fn command_with_env(
        &self,
        args: &[&str],
        stdin: Option<&str>,
        fiber_bin: bool,
        extra_env: &[(&str, &str)],
    ) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(model_ruling::args_with_model_ruling(args))
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("HOME", &self.dir)
            .env("FIBER_HOME", &self.fiber_home)
            .env("XDG_CACHE_HOME", self.dir.join("xdg-cache"))
            .env_remove("CLAUDECODE")
            .env("DELEGATE_HEARTBEAT_MS", "100")
            .env("DELEGATE_RETRY_DELAYS_MS", "0")
            .env(
                "DELEGATE_HOST_PROFILE",
                self.dir.join("nonexistent-profile.json"),
            );
        if fiber_bin {
            cmd.env("FIBER_BIN", self.dir.join("unused-fiber"));
        } else {
            cmd.env_remove("FIBER_BIN");
        }
        cmd.envs(extra_env.iter().copied());
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut si = child.stdin.take().unwrap();
        if let Some(text) = stdin {
            let _ = si.write_all(text.as_bytes());
        }
        drop(si);
        child.wait_with_output().unwrap()
    }

    fn delegate(&self, args: &[&str], stdin: Option<&str>) -> Output {
        self.command(args, stdin, true)
    }

    fn delegate_without_fiber_bin(&self, args: &[&str], stdin: Option<&str>) -> Output {
        self.command(args, stdin, false)
    }

    fn run_write(&self, prompt: &str) -> String {
        self.run_write_with_model(MODEL, prompt)
    }

    fn run_write_with_model(&self, model: &str, prompt: &str) -> String {
        let out = self.delegate(&["run", "--model", model], Some(prompt));
        assert!(
            out.status.success(),
            "exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    fn wait_terminal(&self, id: &str) -> Value {
        let out = self.delegate(&["watch", id, "--timeout", "10"], None);
        assert_eq!(
            out.status.code(),
            Some(0),
            "stderr: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }

    fn resume_ok(&self, id: &str, prompt: &str) -> String {
        let out = self.delegate(&["resume", id], Some(prompt));
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
        let path = self
            .dir
            .join("xdg-cache/delegate/jobs")
            .join(format!("{id}.json"));
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct FakeHub {
    session_id: String,
    commands: Arc<Mutex<Vec<Vec<Value>>>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl FakeHub {
    fn new(
        fiber_home: &Path,
        connections: usize,
        mut scenario: impl FnMut(usize, &str, &mut FakeConn) + Send + 'static,
    ) -> Self {
        let socket = fiber_home.join("run").join("hub");
        assert!(socket.as_os_str().len() < 103, "{}", socket.display());
        std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();

        let session_id = format!(
            "s_{}_{}",
            std::process::id(),
            NEXT_HUB.fetch_add(1, Ordering::Relaxed)
        );
        let commands = Arc::new(Mutex::new(vec![Vec::new(); connections]));
        let stop = Arc::new(AtomicBool::new(false));
        let worker_commands = Arc::clone(&commands);
        let worker_stop = Arc::clone(&stop);
        let worker_session_id = session_id.clone();
        let thread = thread::spawn(move || {
            for index in 0..connections {
                let stream = loop {
                    if worker_stop.load(Ordering::SeqCst) {
                        return;
                    }
                    match listener.accept() {
                        Ok((stream, _)) => break stream,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(1));
                        }
                        Err(error) => panic!("accept fake hub connection: {error}"),
                    }
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                stream
                    .set_write_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut conn = FakeConn::new(stream, index, Arc::clone(&worker_commands));
                conn.send(json!({
                    "kind": "hub_hello",
                    "schema_version": 1,
                    "payload": {"fiber_version": "test"}
                }));
                scenario(index, &worker_session_id, &mut conn);
            }
        });

        Self {
            session_id,
            commands,
            stop,
            thread: Some(thread),
        }
    }

    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn finish(mut self) -> Vec<Vec<Value>> {
        self.stop.store(true, Ordering::SeqCst);
        self.thread.take().unwrap().join().unwrap();
        self.commands.lock().unwrap().clone()
    }
}

impl Drop for FakeHub {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

struct FakeConn {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    connection: usize,
    commands: Arc<Mutex<Vec<Vec<Value>>>>,
}

impl FakeConn {
    fn new(stream: UnixStream, connection: usize, commands: Arc<Mutex<Vec<Vec<Value>>>>) -> Self {
        let reader = BufReader::new(stream.try_clone().unwrap());
        Self {
            reader,
            writer: stream,
            connection,
            commands,
        }
    }

    fn recv(&mut self) -> Value {
        let mut line = String::new();
        let count = self
            .reader
            .read_line(&mut line)
            .expect("read client command");
        assert!(
            count > 0,
            "client closed before command {} on connection {}",
            self.commands.lock().unwrap()[self.connection].len() + 1,
            self.connection
        );
        let value: Value = serde_json::from_str(&line).expect("client command JSON");
        self.commands.lock().unwrap()[self.connection].push(value.clone());
        value
    }

    fn send(&mut self, value: Value) {
        let mut line = serde_json::to_vec(&value).unwrap();
        line.push(b'\n');
        self.writer.write_all(&line).expect("write hub line");
        self.writer.flush().expect("flush hub line");
    }

    fn expect_eof(&mut self) {
        let mut line = String::new();
        let count = self
            .reader
            .read_line(&mut line)
            .expect("read after bridge exit");
        assert_eq!(
            count, 0,
            "bridge sent a hub command after idle exit: {line}"
        );
    }

    fn accept(&mut self, command: &Value, result: Value) {
        self.send(json!({
            "kind": "command_accepted",
            "schema_version": 1,
            "payload": {
                "command_id": command["id"],
                "result": result
            }
        }));
    }

    fn reject(&mut self, command: &Value, code: &str, message: &str) {
        self.send(json!({
            "kind": "command_rejected",
            "schema_version": 1,
            "payload": {
                "command_id": command["id"],
                "code": code,
                "message": message
            }
        }));
    }
}

fn command_names(commands: &[Value]) -> Vec<String> {
    commands
        .iter()
        .map(|command| command["command"].as_str().unwrap().to_string())
        .collect()
}

fn accept_start(conn: &mut FakeConn, session_id: &str) {
    let start = conn.recv();
    assert_eq!(start["command"], "start", "{start}");
    assert!(start.get("session_id").is_none(), "{start}");
    assert_eq!(start["args"]["supervised"], true, "{start}");
    conn.accept(&start, json!({"session_id": session_id}));
}

fn reject_start(conn: &mut FakeConn) {
    let start = conn.recv();
    assert_eq!(start["command"], "start", "{start}");
    conn.reject(&start, "model_not_found", "nope: model is unavailable");
}

fn subscribe_fresh(conn: &mut FakeConn, session_id: &str) {
    let subscribe = conn.recv();
    assert_eq!(subscribe["command"], "subscribe", "{subscribe}");
    assert_eq!(subscribe["session_id"], session_id, "{subscribe}");
    assert_eq!(subscribe["args"]["level"], "full", "{subscribe}");
    conn.accept(&subscribe, json!({"last_seq": 0}));
}

fn subscribe_resumed(conn: &mut FakeConn, session_id: &str) {
    let subscribe = conn.recv();
    assert_eq!(subscribe["command"], "subscribe", "{subscribe}");
    assert_eq!(subscribe["session_id"], session_id, "{subscribe}");
    assert_eq!(subscribe["args"]["level"], "full", "{subscribe}");
    conn.accept(&subscribe, json!({"last_seq": 4}));
    conn.send(event(
        "session_started",
        session_id,
        1,
        json!({"supervised": true}),
    ));
    conn.send(event(
        "fiber_exited",
        session_id,
        4,
        json!({"exit_code": 0, "text": "old verdict"}),
    ));
}

struct PromptReply<'a, F> {
    expected_prompt: Option<&'a str>,
    text: &'a str,
    questions: Option<Value>,
    exit_code: i64,
    after_prompt: F,
}

impl<'a, F> PromptReply<'a, F> {
    fn completed(
        expected_prompt: Option<&'a str>,
        text: &'a str,
        questions: Option<Value>,
        after_prompt: F,
    ) -> Self {
        Self::with_exit(expected_prompt, text, questions, 0, after_prompt)
    }

    fn with_exit(
        expected_prompt: Option<&'a str>,
        text: &'a str,
        questions: Option<Value>,
        exit_code: i64,
        after_prompt: F,
    ) -> Self {
        Self {
            expected_prompt,
            text,
            questions,
            exit_code,
            after_prompt,
        }
    }
}

fn answer_prompt<F: FnOnce()>(
    conn: &mut FakeConn,
    session_id: &str,
    last_seq: u64,
    reply: PromptReply<'_, F>,
) {
    let PromptReply {
        expected_prompt,
        text,
        questions,
        exit_code,
        after_prompt,
    } = reply;
    let prompt = conn.recv();
    assert_eq!(prompt["command"], "prompt", "{prompt}");
    assert_eq!(prompt["session_id"], session_id, "{prompt}");
    if let Some(expected) = expected_prompt {
        assert_eq!(prompt["args"]["content"][0]["text"], expected);
    }
    let prompt_id = prompt["id"].as_str().unwrap().to_string();
    after_prompt();
    conn.accept(&prompt, json!({}));

    conn.send(event(
        "turn_started",
        session_id,
        last_seq + 1,
        json!({
            "input": [{
                "command_id": prompt_id,
                "content": [{"type": "text", "text": "answer"}],
                "source": "driver",
                "type": "message"
            }]
        }),
    ));
    let mut turn_completed = json!({"outcome": "completed"});
    if let Some(questions) = questions {
        turn_completed["questions"] = questions;
    }
    conn.send(event(
        "turn_completed",
        session_id,
        last_seq + 2,
        turn_completed,
    ));
    conn.send(event(
        "fiber_exited",
        session_id,
        last_seq + 3,
        json!({
            "exit_code": exit_code,
            "text": text,
            "usage": echo_usage()
        }),
    ));
    let close = conn.recv();
    assert_eq!(close["command"], "close", "{close}");
    assert_eq!(close["session_id"], session_id, "{close}");
}

fn event(kind: &str, session_id: &str, seq: u64, payload: Value) -> Value {
    json!({
        "kind": kind,
        "session_id": session_id,
        "schema_version": 1,
        "ts": 1,
        "seq": seq,
        "payload": payload
    })
}

fn echo_usage() -> Value {
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/recorded/fiber/echo.jsonl");
    for line in std::fs::read_to_string(fixture).unwrap().lines() {
        let value: Value = serde_json::from_str(line).unwrap();
        if value["kind"] == "fiber_exited" {
            return value["payload"]["usage"].clone();
        }
    }
    panic!("echo.jsonl has no fiber_exited usage");
}

fn expected_prompt(prompt: &str) -> String {
    format!("{prompt}\n\n---\n\n{}", delegate::prompt::status_block())
}

fn rewrite_record(e: &Env, id: &str, f: impl FnOnce(&mut Value)) {
    let path = e
        .dir
        .join("xdg-cache/delegate/jobs")
        .join(format!("{id}.json"));
    let mut record: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    f(&mut record);
    std::fs::write(&path, serde_json::to_string(&record).unwrap()).unwrap();
}

#[test]
fn fiber_session_start_and_stop_use_the_hub_bridge() {
    let dir = PathBuf::from(format!(
        "/tmp/fx-{}-{}",
        std::process::id(),
        NEXT_ENV.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir(&dir).unwrap();
    let fiber_home = dir.join("fh");
    std::fs::create_dir(&fiber_home).unwrap();
    let e = Env { dir, fiber_home };
    let brief = e.dir.join("brief.txt");
    let inbox = e.dir.join("inbox");
    std::fs::write(&brief, "Reply with DONE.").unwrap();
    std::fs::create_dir(&inbox).unwrap();
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        let prompt = conn.recv();
        assert_eq!(prompt["command"], "prompt");
        conn.accept(&prompt, json!({}));
        conn.send(turn_event("turn_started", session_id, 1, "t1", json!({"input":[{"command_id":prompt["id"],"content":[{"type":"text","text":"Reply with DONE."}],"source":"driver","type":"message"}]})));
        let steer = conn.recv();
        assert_eq!(steer["command"], "steer");
        // docs/events.md, "steering_applied": the message as the turn
        // received it, with the keys of "Where a message came from".
        conn.send(turn_event("steering_applied", session_id, 2, "t1", json!({"content":[{"type":"text","text":"change text"}],"source":"driver","command_id":steer["id"]})));
        conn.send(turn_event("turn_completed", session_id, 3, "t1", json!({"outcome":"completed"})));
        let mut stop_command = conn.recv();
        if stop_command["command"] == "cancel" {
            conn.accept(&stop_command, json!({}));
            conn.send(turn_event("turn_completed", session_id, 3, "t1", json!({"outcome":"interrupted"})));
            stop_command = conn.recv();
        }
        assert_eq!(stop_command["command"], "close");
        conn.accept(&stop_command, json!({}));
        conn.send(event("fiber_exited", session_id, 4, json!({"exit_code":0,"text":"DONE"})));
    });
    let start = e.delegate(
        &[
            "session",
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            inbox.to_str().unwrap(),
            "--json",
        ],
        None,
    );
    assert!(
        start.status.success(),
        "{}",
        String::from_utf8_lossy(&start.stderr)
    );
    let state: Value = serde_json::from_slice(&start.stdout).unwrap();
    assert_eq!(state["ok"], true, "{state:#}");
    assert_eq!(state["session"]["hostSessionId"], fake.session_id());
    let id = state["session"]["id"].as_str().unwrap();
    let sent = e.delegate(&["session", "send", id, "change text", "--json"], None);
    assert!(
        sent.status.success(),
        "{}",
        String::from_utf8_lossy(&sent.stderr)
    );
    let sent_json: Value = serde_json::from_slice(&sent.stdout).unwrap();
    assert_eq!(sent_json["disposition"], "steered", "{sent_json:#}");
    let stopped = e.delegate(&["session", "stop", id, "--json"], None);
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    let commands = fake.finish();
    let names = command_names(&commands[0]);
    assert!(
        names == ["start", "subscribe", "prompt", "steer", "close"]
            || names == ["start", "subscribe", "prompt", "steer", "cancel", "close"],
        "{names:?}"
    );
}

#[test]
fn fiber_session_interrupt_cancels_without_closing_the_hub_session() {
    let dir = PathBuf::from(format!(
        "/tmp/fx-{}-{}",
        std::process::id(),
        NEXT_ENV.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir(&dir).unwrap();
    let fiber_home = dir.join("fh");
    std::fs::create_dir(&fiber_home).unwrap();
    let e = Env { dir, fiber_home };
    let brief = e.dir.join("brief.txt");
    let inbox = e.dir.join("inbox");
    std::fs::write(&brief, "Reply with DONE.").unwrap();
    std::fs::create_dir(&inbox).unwrap();
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        let prompt = conn.recv();
        assert_eq!(prompt["command"], "prompt");
        conn.accept(&prompt, json!({}));
        conn.send(turn_event(
            "turn_started",
            session_id,
            1,
            "t1",
            json!({"input":[{"command_id":prompt["id"],"type":"message"}]}),
        ));
        let cancel = conn.recv();
        assert_eq!(cancel["command"], "cancel");
        conn.accept(&cancel, json!({}));
        conn.send(turn_event(
            "turn_completed",
            session_id,
            2,
            "t1",
            json!({"outcome":"interrupted"}),
        ));
        let close = conn.recv();
        assert_eq!(close["command"], "close");
        conn.accept(&close, json!({}));
        conn.send(event("fiber_exited", session_id, 3, json!({"exit_code":0})));
    });
    let start = e.delegate(
        &[
            "session",
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            inbox.to_str().unwrap(),
            "--json",
        ],
        None,
    );
    assert!(
        start.status.success(),
        "{}",
        String::from_utf8_lossy(&start.stderr)
    );
    let state: Value = serde_json::from_slice(&start.stdout).unwrap();
    let id = state["session"]["id"].as_str().unwrap();
    let interrupted = e.delegate(&["session", "stop", id, "--interrupt", "--json"], None);
    assert!(
        interrupted.status.success(),
        "{}",
        String::from_utf8_lossy(&interrupted.stderr)
    );
    let stopped = e.delegate(&["session", "stop", id, "--json"], None);
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt", "cancel", "close"]
    );
}

#[test]
fn fiber_session_send_resumes_an_idle_exited_fiber_with_a_prompt() {
    let dir = PathBuf::from(format!(
        "/tmp/fx-{}-{}",
        std::process::id(),
        NEXT_ENV.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir(&dir).unwrap();
    let fiber_home = dir.join("fh");
    std::fs::create_dir(&fiber_home).unwrap();
    let e = Env { dir, fiber_home };
    let brief = e.dir.join("brief.txt");
    let inbox = e.dir.join("inbox");
    std::fs::write(&brief, "Reply with DONE.").unwrap();
    std::fs::create_dir(&inbox).unwrap();
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        let first_prompt = conn.recv();
        assert_eq!(first_prompt["command"], "prompt");
        conn.accept(&first_prompt, json!({}));
        conn.send(turn_event(
            "turn_started",
            session_id,
            1,
            "t1",
            json!({"input":[{"command_id":first_prompt["id"],"type":"message"}]}),
        ));
        conn.send(turn_event(
            "turn_completed",
            session_id,
            2,
            "t1",
            json!({"outcome":"completed"}),
        ));
        conn.send(event("fiber_exited", session_id, 3, json!({"exit_code":0})));
        let resumed_prompt = conn.recv();
        assert_eq!(resumed_prompt["command"], "prompt");
        assert_eq!(
            resumed_prompt["args"]["content"][0]["text"],
            "resume after idle exit"
        );
        conn.accept(&resumed_prompt, json!({}));
        conn.send(event(
            "stream_reopened",
            session_id,
            4,
            json!({"last_seq":3}),
        ));
        conn.send(turn_event(
            "turn_started",
            session_id,
            5,
            "t2",
            json!({"input":[{"command_id":resumed_prompt["id"],"type":"message"}]}),
        ));
        conn.send(turn_event(
            "turn_completed",
            session_id,
            6,
            "t2",
            json!({"outcome":"completed"}),
        ));
        let close = conn.recv();
        assert_eq!(close["command"], "close");
        conn.accept(&close, json!({}));
        conn.send(event("fiber_exited", session_id, 7, json!({"exit_code":0})));
    });
    let start = e.delegate(
        &[
            "session",
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            inbox.to_str().unwrap(),
            "--json",
        ],
        None,
    );
    assert!(
        start.status.success(),
        "{}",
        String::from_utf8_lossy(&start.stderr)
    );
    let state: Value = serde_json::from_slice(&start.stdout).unwrap();
    let id = state["session"]["id"].as_str().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let logs = e.delegate(&["session", "logs", id, "--json"], None);
        let logs: Value = serde_json::from_slice(&logs.stdout).unwrap();
        if logs["lines"]
            .as_array()
            .unwrap()
            .iter()
            .any(|line| line["kind"] == "session.exited" && line["reason"] == "idle")
        {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "idle exit was not logged: {logs:#}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let sent = e.delegate(
        &["session", "send", id, "resume after idle exit", "--json"],
        None,
    );
    assert!(
        sent.status.success(),
        "{}",
        String::from_utf8_lossy(&sent.stderr)
    );
    let value: Value = serde_json::from_slice(&sent.stdout).unwrap();
    assert_eq!(value["disposition"], "started", "{value:#}");
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let status = e.delegate(&["session", "status", id, "--json"], None);
        let status: Value = serde_json::from_slice(&status.stdout).unwrap();
        if status["session"]["status"] == "idle" {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "resumed turn did not complete: {status:#}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let stopped = e.delegate(&["session", "stop", id, "--json"], None);
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt", "prompt", "close"]
    );
}

#[test]
fn fiber_session_stop_after_idle_exit_sends_no_hub_command() {
    let dir = PathBuf::from(format!(
        "/tmp/fx-{}-{}",
        std::process::id(),
        NEXT_ENV.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir(&dir).unwrap();
    let fiber_home = dir.join("fh");
    std::fs::create_dir(&fiber_home).unwrap();
    let e = Env { dir, fiber_home };
    let brief = e.dir.join("brief.txt");
    let inbox = e.dir.join("inbox");
    std::fs::write(&brief, "Reply with DONE.").unwrap();
    std::fs::create_dir(&inbox).unwrap();
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        let prompt = conn.recv();
        assert_eq!(prompt["command"], "prompt");
        conn.accept(&prompt, json!({}));
        conn.send(turn_event(
            "turn_started",
            session_id,
            1,
            "t1",
            json!({"input":[{"command_id":prompt["id"],"type":"message"}]}),
        ));
        conn.send(turn_event(
            "turn_completed",
            session_id,
            2,
            "t1",
            json!({"outcome":"completed"}),
        ));
        conn.send(event("fiber_exited", session_id, 3, json!({"exit_code":0})));
        conn.expect_eof();
    });
    let start = e.delegate(
        &[
            "session",
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            inbox.to_str().unwrap(),
            "--json",
        ],
        None,
    );
    assert!(
        start.status.success(),
        "{}",
        String::from_utf8_lossy(&start.stderr)
    );
    let state: Value = serde_json::from_slice(&start.stdout).unwrap();
    let id = state["session"]["id"].as_str().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let status = e.delegate(&["session", "status", id, "--json"], None);
        let value: Value = serde_json::from_slice(&status.stdout).unwrap();
        if value["session"]["status"] == "idle" {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "session did not become idle: {value:#}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let logs = e.delegate(&["session", "logs", id, "--json"], None);
        let logs: Value = serde_json::from_slice(&logs.stdout).unwrap();
        if logs["lines"]
            .as_array()
            .unwrap()
            .iter()
            .any(|line| line["kind"] == "session.exited" && line["reason"] == "idle")
        {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "idle exit was not logged: {logs:#}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let stopped = e.delegate(&["session", "stop", id, "--json"], None);
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    let commands = fake.finish();
    let names = command_names(&commands[0]);
    assert_eq!(names, ["start", "subscribe", "prompt"]);
}

#[test]
fn fiber_run_books_subscription_cost_as_estimated() {
    let e = Env::new("cost");
    let prompt = "Reply with the word DONE.";
    let expected = expected_prompt(prompt);
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        answer_prompt(
            conn,
            session_id,
            0,
            PromptReply::completed(Some(&expected), "DONE", None, || {}),
        );
    });

    let id = e.run_write(prompt);
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE", "{done:#}");
    assert_eq!(done["result"]["text"], "DONE");
    assert_eq!(done["result"]["backend"], "fiber");
    assert_eq!(done["result"]["model"], MODEL);
    let cost = done["result"]["costUsd"].as_f64().unwrap();
    assert!((cost - 0.000603378).abs() < 1e-12, "{cost}");
    assert_eq!(done["result"]["costEstimated"], true);
    assert_eq!(done["resume"]["sessionId"], fake.session_id());

    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt", "close"]
    );
    assert_eq!(commands[0][0]["args"]["model"], REFERENCE);
    assert_eq!(commands[0][0]["args"]["supervised"], true);
    assert_eq!(
        commands[0][0]["args"]["overrides"],
        json!(["reviewer.model=opencode-go/glm-5.3-flash"])
    );
    assert_eq!(
        commands[0][2]["args"]["content"][0]["text"],
        expected_prompt(prompt)
    );
}

#[test]
fn fiber_run_without_a_catalogue_reviewer_keeps_fiber_defaults() {
    let e = Env::new("default-reviewer");
    let model = "fiber/codex/gpt-6-luna";
    let prompt = "Reply with the word DONE.";
    let expected = expected_prompt(prompt);
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        answer_prompt(
            conn,
            session_id,
            0,
            PromptReply::completed(Some(&expected), "DONE", None, || {}),
        );
    });

    let id = e.run_write_with_model(model, prompt);
    assert_eq!(e.wait_terminal(&id)["status"], "DONE");
    let commands = fake.finish();
    assert_eq!(commands[0][0]["args"]["model"], "codex/gpt-6-luna");
    assert!(
        commands[0][0]["args"].get("overrides").is_none(),
        "a row without reviewer must keep Fiber defaults: {}",
        commands[0][0]
    );
}

#[test]
fn fiber_prompt_over_128_kib_reaches_the_hub() {
    let e = Env::new("large");
    let prompt = format!("{}!", "x".repeat(128 * 1024));
    let expected = expected_prompt(&prompt);
    let fake_expected = expected.clone();
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        answer_prompt(
            conn,
            session_id,
            0,
            PromptReply::completed(Some(&fake_expected), "DONE", None, || {}),
        );
    });

    let id = e.run_write(&prompt);
    assert_eq!(e.wait_terminal(&id)["status"], "DONE");
    let commands = fake.finish();
    assert_eq!(commands[0][2]["args"]["content"][0]["text"], expected);
}

#[test]
fn fiber_missing_hub_is_an_error_record_naming_the_socket() {
    let e = Env::new("nohub");
    let out = e.delegate_without_fiber_bin(&["run", "--model", MODEL], Some("Reply with DONE."));
    assert!(
        out.status.success(),
        "exit {:?}\nstderr: {}\nstdout: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    assert_eq!(id.len(), 36);
    let record = e.wait_terminal(&id);
    assert_eq!(record["status"], "ERROR");
    assert_eq!(record["result"]["backend"], "fiber");
    let text = record["result"]["text"].as_str().unwrap_or("");
    let socket = e.fiber_home.join("run").join("hub");
    assert!(text.contains("cannot connect to hub socket"), "{text}");
    assert!(text.contains(&socket.display().to_string()), "{text}");
    assert!(!text.contains("fiber binary not found"), "{text}");
    let legacy_route = ["fiber", "ask"].join(" ");
    assert!(!text.contains(&legacy_route), "{text}");
}

#[test]
fn fiber_badmodel_is_an_error() {
    let e = Env::new("badmodel");
    let fake = e.fake_hub(1, |_, _, conn| reject_start(conn));
    let id = e.run_write("anything");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR");
    assert_eq!(done["result"]["backend"], "fiber");
    assert_eq!(done["result"]["model"], MODEL);
    assert!(
        done["result"]["text"]
            .as_str()
            .unwrap_or("")
            .contains("nope")
    );
    let commands = fake.finish();
    assert_eq!(command_names(&commands[0]), ["start"]);
}

#[test]
fn fiber_needs_context_resume_continues_the_hub_session() {
    let e = Env::new("needsctx");
    let first_prompt = "Which codeword should I use?";
    let first_expected = expected_prompt(first_prompt);
    let answer_expected = expected_prompt("the answer");
    let fake = e.fake_hub(2, move |index, session_id, conn| {
        if index == 0 {
            accept_start(conn, session_id);
            subscribe_fresh(conn, session_id);
            answer_prompt(
                conn,
                session_id,
                0,
                PromptReply::completed(
                    Some(&first_expected),
                    "Waiting for an answer",
                    Some(json!(["Which codeword should I use?"])),
                    || {},
                ),
            );
        } else {
            subscribe_resumed(conn, session_id);
            answer_prompt(
                conn,
                session_id,
                4,
                PromptReply::completed(Some(&answer_expected), "DONE", None, || {}),
            );
        }
    });

    let id = e.run_write(first_prompt);
    let first = e.wait_terminal(&id);
    assert_eq!(first["status"], "NEEDS_CONTEXT");
    assert!(
        first["result"]["text"]
            .as_str()
            .unwrap_or("")
            .contains("1. Which codeword should I use?"),
        "{first:#}"
    );
    assert!(
        first["result"]["text"]
            .as_str()
            .unwrap_or("")
            .ends_with("STATUS: NEEDS_CONTEXT")
    );
    assert_eq!(first["resume"]["sessionId"], fake.session_id());

    let resumed = e.resume_ok(&id, "the answer");
    let done = e.wait_terminal(&resumed);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resume"]["sessionId"], first["resume"]["sessionId"]);
    assert_eq!(done["resumedFrom"], id.as_str());

    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt", "close"]
    );
    assert_eq!(
        command_names(&commands[1]),
        ["subscribe", "prompt", "close"]
    );
    assert_eq!(commands[1][0]["session_id"], first["resume"]["sessionId"]);
    assert_eq!(
        commands[1][1]["args"]["content"][0]["text"],
        expected_prompt("the answer")
    );
}

#[test]
fn fiber_gate_failure_resume_repairs_in_the_session() {
    let e = Env::new("gaterepair");
    let work = e.dir.clone();
    let fake = e.fake_hub(2, move |index, session_id, conn| {
        if index == 0 {
            accept_start(conn, session_id);
            subscribe_fresh(conn, session_id);
            answer_prompt(
                conn,
                session_id,
                0,
                PromptReply::completed(None, "DONE", None, || {}),
            );
        } else {
            subscribe_resumed(conn, session_id);
            answer_prompt(
                conn,
                session_id,
                4,
                PromptReply::completed(None, "DONE", None, || {
                    std::fs::write(work.join("zebra-17.txt"), "ok").unwrap();
                }),
            );
        }
    });
    let gate = "test -f zebra-17.txt";
    let out = e.delegate(
        &["run", "--model", MODEL, "--gate", gate],
        Some("Reply with the word DONE."),
    );
    assert!(out.status.success(), "{out:?}");
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let first = e.wait_terminal(&id);
    assert_eq!(first["status"], "DONE_WITH_CONCERNS");
    assert_eq!(first["result"]["gateResult"]["passed"], false);

    let resumed = e.resume_ok(&id, "Repair the missing file.");
    let done = e.wait_terminal(&resumed);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["gateResult"]["passed"], true);
    assert_eq!(done["result"]["gateResult"]["command"], gate);
    assert_eq!(done["resume"]["sessionId"], first["resume"]["sessionId"]);
    assert_eq!(done["resumedFrom"], id.as_str());
    assert_eq!(
        std::fs::read_to_string(e.dir.join("zebra-17.txt")).unwrap(),
        "ok"
    );

    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt", "close"]
    );
    assert_eq!(
        command_names(&commands[1]),
        ["subscribe", "prompt", "close"]
    );
    assert_eq!(commands[0][0]["args"]["supervised"], true);
    assert_eq!(commands[1][0]["session_id"], first["resume"]["sessionId"]);
}

fn resume_without_session_case(name: &str, session_id: Option<&str>) {
    let e = Env::new(name);
    let expected = expected_prompt("try again");
    let fake = e.fake_hub(2, move |index, sid, conn| {
        if index == 0 {
            reject_start(conn);
        } else {
            accept_start(conn, sid);
            subscribe_fresh(conn, sid);
            answer_prompt(
                conn,
                sid,
                0,
                PromptReply::completed(Some(&expected), "DONE", None, || {}),
            );
        }
    });
    let id = e.run_write("Reply with the word DONE.");
    let first = e.wait_terminal(&id);
    assert_eq!(first["status"], "ERROR");
    if let Some(session_id) = session_id {
        rewrite_record(&e, &id, |record| {
            record["resume"]["sessionId"] = Value::String(session_id.to_string());
        });
    } else {
        assert!(first["resume"]["sessionId"].is_null(), "{first:#}");
    }

    let resumed = e.resume_ok(&id, "try again");
    let done = e.wait_terminal(&resumed);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resumedFrom"], id.as_str());
    let commands = fake.finish();
    assert_eq!(command_names(&commands[0]), ["start"]);
    assert_eq!(
        command_names(&commands[1]),
        ["start", "subscribe", "prompt", "close"]
    );
}

#[test]
fn fiber_resume_without_a_session_id_runs_fresh() {
    resume_without_session_case("nosession", None);
}

#[test]
fn fiber_resume_with_an_empty_session_id_runs_fresh() {
    resume_without_session_case("empty", Some(""));
}

#[test]
fn fiber_resume_with_a_whitespace_session_id_runs_fresh() {
    resume_without_session_case("whitespace", Some("   "));
}

#[test]
fn fiber_resume_of_a_cancelled_record_without_a_session_id_stays_refused() {
    let e = Env::new("cancelled");
    let fake = e.fake_hub(1, |_, _, conn| reject_start(conn));
    let id = e.run_write("Reply with the word DONE.");
    let first = e.wait_terminal(&id);
    assert_eq!(first["status"], "ERROR");
    assert!(first["resume"]["sessionId"].is_null(), "{first:#}");
    rewrite_record(&e, &id, |record| {
        record["status"] = Value::String("CANCELLED".into());
    });

    let out = e.delegate(&["resume", &id], Some("try again"));
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("no session id"));
    let commands = fake.finish();
    assert_eq!(command_names(&commands[0]), ["start"]);
    assert_eq!(commands.len(), 1);
    assert!(e.record(&id).get("supersededBy").is_none());
}

#[test]
fn fiber_thinking_suffix_reaches_hub_without_the_prefix() {
    let e = Env::new("thinking");
    let high = format!("{MODEL}:high");
    let fake = e.fake_hub(1, |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        answer_prompt(
            conn,
            session_id,
            0,
            PromptReply::completed(None, "DONE", None, || {}),
        );
    });
    let out = e.delegate(
        &["run", "--model", &high],
        Some("Reply with the word DONE."),
    );
    assert!(out.status.success(), "{out:?}");
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["model"], high);
    let commands = fake.finish();
    assert_eq!(commands[0][0]["args"]["model"], format!("{REFERENCE}:high"));
    assert!(
        !commands[0][0]["args"]["model"]
            .as_str()
            .unwrap()
            .starts_with("fiber/")
    );
}

#[test]
fn fiber_bad_thinking_level_is_a_usage_error_without_hub_traffic() {
    let e = Env::new("thinkingbad");
    let bad = format!("{MODEL}:bogus");
    let out = e.delegate(&["run", "--model", &bad], Some("hi"));
    assert_eq!(out.status.code(), Some(2));
    assert!(
        out.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains(&bad), "{err}");
    assert!(err.contains("unknown thinking level \"bogus\""), "{err}");
    assert!(
        err.contains("off, minimal, low, medium, high, xhigh, max"),
        "{err}"
    );
    assert!(!e.fiber_home.join("run").join("hub").exists());
}

#[test]
fn fiber_exited_error_maps_to_an_error_job() {
    let e = Env::new("exiterror");
    let fake = e.fake_hub(1, |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        answer_prompt(
            conn,
            session_id,
            0,
            PromptReply::with_exit(None, "provider failed", None, 1, || {}),
        );
    });
    let id = e.run_write("Reply with DONE.");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR");
    assert!(
        done["result"]["text"]
            .as_str()
            .unwrap_or("")
            .contains("provider failed")
    );
    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt", "close"]
    );
}

/// A session test's directory sits under `/tmp`, so the hub socket path stays
/// short enough to bind.
fn session_env() -> (Env, PathBuf, PathBuf) {
    let dir = PathBuf::from(format!(
        "/tmp/fx-{}-{}",
        std::process::id(),
        NEXT_ENV.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir(&dir).unwrap();
    let fiber_home = dir.join("fh");
    std::fs::create_dir(&fiber_home).unwrap();
    let e = Env { dir, fiber_home };
    let brief = e.dir.join("brief.txt");
    let inbox = e.dir.join("inbox");
    std::fs::write(&brief, "Reply with DONE.").unwrap();
    std::fs::create_dir(&inbox).unwrap();
    (e, brief, inbox)
}

fn start_fiber_session(
    e: &Env,
    model: &str,
    brief: &Path,
    inbox: &Path,
    extra_env: &[(&str, &str)],
) -> Output {
    e.command_with_env(
        &[
            "session",
            "start",
            "--model",
            model,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            inbox.to_str().unwrap(),
            "--json",
        ],
        None,
        true,
        extra_env,
    )
}

fn started_session_id(start: &Output) -> String {
    assert!(
        start.status.success(),
        "exit {:?}\nstderr: {}\nstdout: {}",
        start.status.code(),
        String::from_utf8_lossy(&start.stderr),
        String::from_utf8_lossy(&start.stdout)
    );
    let state: Value = serde_json::from_slice(&start.stdout).unwrap();
    state["session"]["id"].as_str().unwrap().to_string()
}

/// A hub event about a turn: as in Fiber's envelope, `turn_id` sits beside
/// `seq`, not in the payload.
fn turn_event(kind: &str, session_id: &str, seq: u64, turn_id: &str, payload: Value) -> Value {
    let mut value = event(kind, session_id, seq, payload);
    value["turn_id"] = json!(turn_id);
    value
}

fn session_state(e: &Env, id: &str) -> Value {
    let out = e.delegate(&["session", "status", id, "--json"], None);
    let value: Value = serde_json::from_slice(&out.stdout).unwrap();
    value["session"].clone()
}

fn session_log_lines(e: &Env, id: &str) -> Vec<Value> {
    let out = e.delegate(&["session", "logs", id, "--json"], None);
    let value: Value = serde_json::from_slice(&out.stdout).unwrap();
    value["lines"].as_array().unwrap().clone()
}

fn wait_for_status(e: &Env, id: &str, status: &str, within: Duration) -> Value {
    let deadline = std::time::Instant::now() + within;
    loop {
        let state = session_state(e, id);
        if state["status"] == status {
            return state;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "session did not become {status}: {state:#}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_note(inbox: &Path, note: &str) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let notes: Vec<String> = std::fs::read_dir(inbox)
            .unwrap()
            .filter_map(|entry| std::fs::read_to_string(entry.unwrap().path()).ok())
            .collect();
        if notes.iter().any(|text| text == note) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "inbox has no {note:?}: {notes:?}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

struct OneTurn {
    id: String,
    watched: Value,
    lines: Vec<Value>,
}

/// Runs a session whose first turn, `t1`, ends with `turn_events`, watches it
/// to idle, waits for the idle inbox note, then stops it.
fn one_fiber_turn(turn_events: fn(&str) -> Vec<Value>) -> OneTurn {
    let (e, brief, inbox) = session_env();
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        let prompt = conn.recv();
        assert_eq!(prompt["command"], "prompt");
        conn.accept(&prompt, json!({}));
        conn.send(turn_event(
            "turn_started",
            session_id,
            1,
            "t1",
            json!({"input":[{"command_id":prompt["id"],"content":[{"type":"text","text":"Reply with DONE."}],"source":"driver","type":"message"}]}),
        ));
        for line in turn_events(session_id) {
            conn.send(line);
        }
        let close = conn.recv();
        assert_eq!(close["command"], "close");
        conn.accept(&close, json!({}));
        conn.send(event("fiber_exited", session_id, 99, json!({"exit_code":0})));
    });
    let id = started_session_id(&start_fiber_session(&e, MODEL, &brief, &inbox, &[]));
    wait_for_status(&e, &id, "idle", Duration::from_secs(10));
    let watch = e.delegate(&["session", "watch", &id, "--json"], None);
    assert_eq!(
        watch.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&watch.stderr)
    );
    let watched: Value = serde_json::from_slice(&watch.stdout).unwrap();
    wait_for_note(&inbox, &format!("[session {id} idle]\n"));
    let lines = session_log_lines(&e, &id);
    let stopped = e.delegate(&["session", "stop", &id, "--json"], None);
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt", "close"]
    );
    OneTurn { id, watched, lines }
}

fn text_part(session_id: &str, seq: u64, action_id: &str, text: &str) -> Value {
    let mut value = turn_event(
        "text_completed",
        session_id,
        seq,
        "t1",
        json!({"text": text}),
    );
    value["action_id"] = json!(action_id);
    value
}

#[test]
fn fiber_session_watch_returns_zero_at_idle_and_notes_the_inbox() {
    let turn = one_fiber_turn(|session_id| {
        let mut lines = reply(session_id, 2, "a_1", &["DONE"], "completed");
        lines.push(turn_event(
            "turn_completed",
            session_id,
            5,
            "t1",
            json!({"outcome":"completed"}),
        ));
        lines
    });
    assert_eq!(turn.watched["ok"], true, "{:#}", turn.watched);
    assert_eq!(turn.watched["session"]["status"], "idle");
    assert_eq!(turn.watched["session"]["id"], turn.id.as_str());
    assert_eq!(turn.watched["session"]["lastTurn"]["turnId"], "t1");
}

#[test]
fn fiber_session_failed_turn_ends_failed() {
    let turn = one_fiber_turn(|session_id| {
        vec![turn_event(
            "turn_completed",
            session_id,
            2,
            "t1",
            json!({"outcome":"failed","error":{"code":"provider_error","message":"the model call failed"}}),
        )]
    });
    let last_turn = &turn.watched["session"]["lastTurn"];
    assert_eq!(last_turn["turnId"], "t1", "{last_turn:#}");
    assert_eq!(last_turn["terminal"], "failed", "{last_turn:#}");
    // Fiber's `error` is `{code, message}` (docs/events.md, "error");
    // MSP's is `{kind, message}`, with `kind` the Fiber `code`.
    assert_eq!(
        last_turn["error"],
        json!({"kind":"provider_error","message":"the model call failed"}),
        "{last_turn:#}"
    );
    let completed = turn
        .lines
        .iter()
        .find(|line| line["kind"] == "turn.completed")
        .expect("a turn.completed log line");
    assert_eq!(
        completed["error"],
        json!({"kind":"provider_error","message":"the model call failed"}),
        "{completed:#}"
    );
}

#[test]
fn fiber_session_supervised_questions_ride_on_the_turn_completed_line() {
    let turn = one_fiber_turn(|session_id| {
        vec![turn_event(
            "turn_completed",
            session_id,
            2,
            "t1",
            json!({"outcome":"completed","questions":[{"header":"Branch","question":"Which branch should the fix land on?","options":[{"label":"main (Recommended)"},{"label":"release"}]}]}),
        )]
    });
    let last_turn = &turn.watched["session"]["lastTurn"];
    assert_eq!(last_turn["terminal"], "completed", "{last_turn:#}");
    let completed = turn
        .lines
        .iter()
        .find(|line| line["kind"] == "turn.completed")
        .expect("no turn.completed line");
    assert_eq!(completed["turnId"], "t1", "{completed:#}");
    assert_eq!(
        completed["questions"][0]["question"], "Which branch should the fix land on?",
        "{completed:#}"
    );
    assert_eq!(
        completed["questions"][0]["options"][0]["label"],
        "main (Recommended)"
    );
}

#[test]
fn fiber_session_reconnect_exhaustion_marks_the_session_dead() {
    let (e, brief, inbox) = session_env();
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        let prompt = conn.recv();
        assert_eq!(prompt["command"], "prompt");
        conn.accept(&prompt, json!({}));
        conn.send(turn_event(
            "turn_started",
            session_id,
            1,
            "t1",
            json!({"input":[{"command_id":prompt["id"],"type":"message"}]}),
        ));
        // The scenario returns: the connection drops and the hub's listener
        // goes with it, so every reconnect attempt is refused.
    });
    let id = started_session_id(&start_fiber_session(&e, MODEL, &brief, &inbox, &[]));
    let state = wait_for_status(&e, &id, "dead", Duration::from_secs(20));
    assert_eq!(state["dead"]["reason"], "hostExited", "{state:#}");
    assert_eq!(state["dead"]["exitCode"], 1, "{state:#}");
    wait_for_note(&inbox, &format!("[session {id} dead]\n"));
    let watch = e.delegate(&["session", "watch", &id, "--json"], None);
    assert_eq!(watch.status.code(), Some(4));
    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt"]
    );
}

#[test]
fn fiber_session_start_refuses_a_harness_model_without_the_fiber_prefix() {
    let (e, brief, inbox) = session_env();
    let out = start_fiber_session(&e, "codex/gpt-6-luna", &brief, &inbox, &[]);
    assert_eq!(out.status.code(), Some(2), "{out:?}");
    let value: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(value["ok"], false, "{value:#}");
    assert_eq!(value["error"]["code"], "usage", "{value:#}");
    assert!(
        value["error"]["message"]
            .as_str()
            .unwrap()
            .contains("--model must use"),
        "{value:#}"
    );
    assert!(!e.fiber_home.join("run").join("hub").exists());
}

#[test]
fn fiber_session_start_accepts_both_lane_model_fiber_rows() {
    for (model, reference) in [
        ("fiber/codex/gpt-6-luna:medium", "codex/gpt-6-luna:medium"),
        (
            "fiber/opencode-go/muse-spark-1.3-contributor",
            "opencode-go/muse-spark-1.3-contributor",
        ),
    ] {
        let (e, brief, inbox) = session_env();
        let fake = e.fake_hub(1, move |_, session_id, conn| {
            let start = conn.recv();
            assert_eq!(start["command"], "start", "{start}");
            assert_eq!(start["args"]["model"], reference, "{start}");
            conn.accept(&start, json!({"session_id": session_id}));
            subscribe_fresh(conn, session_id);
            let prompt = conn.recv();
            assert_eq!(prompt["command"], "prompt");
            conn.accept(&prompt, json!({}));
            conn.send(turn_event(
                "turn_started",
                session_id,
                1,
                "t1",
                json!({"input":[{"command_id":prompt["id"],"type":"message"}]}),
            ));
            conn.send(turn_event(
                "turn_completed",
                session_id,
                2,
                "t1",
                json!({"outcome":"completed"}),
            ));
            let close = conn.recv();
            assert_eq!(close["command"], "close");
            conn.accept(&close, json!({}));
            conn.send(event("fiber_exited", session_id, 3, json!({"exit_code":0})));
        });
        let id = started_session_id(&start_fiber_session(&e, model, &brief, &inbox, &[]));
        assert_eq!(session_state(&e, &id)["model"], model);
        wait_for_status(&e, &id, "idle", Duration::from_secs(10));
        let stopped = e.delegate(&["session", "stop", &id, "--json"], None);
        assert!(
            stopped.status.success(),
            "{}",
            String::from_utf8_lossy(&stopped.stderr)
        );
        let commands = fake.finish();
        assert_eq!(
            command_names(&commands[0]),
            ["start", "subscribe", "prompt", "close"]
        );
    }
}

#[test]
fn fiber_session_completed_turn_logs_the_last_message_with_its_status_line() {
    let turn = one_fiber_turn(|session_id| {
        let mut lines = reply(
            session_id,
            2,
            "a_1",
            &["Checked the failing test."],
            "completed",
        );
        lines.extend(reply(
            session_id,
            5,
            "a_2",
            &["The test passes now.\n\nSTATUS: DONE_WITH_CONCERNS"],
            "completed",
        ));
        lines.push(turn_event(
            "turn_completed",
            session_id,
            8,
            "t1",
            json!({"outcome":"completed"}),
        ));
        lines
    });
    let last_turn = &turn.watched["session"]["lastTurn"];
    assert_eq!(last_turn["terminal"], "completed", "{last_turn:#}");
    let messages: Vec<&Value> = turn
        .lines
        .iter()
        .filter(|line| line["kind"] == "message")
        .collect();
    let last = messages.last().expect("no message log line");
    assert_eq!(last["turnId"], "t1", "{last:#}");
    assert!(
        last["text"]
            .as_str()
            .unwrap()
            .ends_with("STATUS: DONE_WITH_CONCERNS"),
        "{last:#}"
    );
    let completed = turn
        .lines
        .iter()
        .find(|line| line["kind"] == "turn.completed")
        .expect("no turn.completed line");
    assert!(completed["questions"].is_null(), "{completed:#}");
}

#[test]
fn fiber_session_stop_sends_close_now_when_fiber_does_not_exit_within_the_grace() {
    let (e, brief, inbox) = session_env();
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        let prompt = conn.recv();
        assert_eq!(prompt["command"], "prompt");
        conn.accept(&prompt, json!({}));
        conn.send(turn_event(
            "turn_started",
            session_id,
            1,
            "t1",
            json!({"input":[{"command_id":prompt["id"],"type":"message"}]}),
        ));
        conn.send(turn_event(
            "turn_completed",
            session_id,
            2,
            "t1",
            json!({"outcome":"completed"}),
        ));
        // The first close is accepted, but Fiber does not exit.
        let close = conn.recv();
        assert_eq!(close["command"], "close");
        assert!(close["args"]["now"].is_null(), "{close}");
        conn.accept(&close, json!({}));
        let close_now = conn.recv();
        assert_eq!(close_now["command"], "close", "{close_now}");
        assert_eq!(close_now["args"]["now"], true, "{close_now}");
        assert_ne!(close_now["id"], close["id"], "{close_now}");
        conn.accept(&close_now, json!({}));
        conn.send(event("fiber_exited", session_id, 3, json!({"exit_code":0})));
    });
    let grace = [("DELEGATE_SESSION_GRACE_MS", "300")];
    let id = started_session_id(&start_fiber_session(&e, MODEL, &brief, &inbox, &grace));
    wait_for_status(&e, &id, "idle", Duration::from_secs(10));
    let stopped = e.command_with_env(&["session", "stop", &id, "--json"], None, true, &grace);
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    let state = wait_for_status(&e, &id, "dead", Duration::from_secs(10));
    assert_eq!(state["dead"]["reason"], "stopped", "{state:#}");
    let commands = fake.finish();
    assert_eq!(
        command_names(&commands[0]),
        ["start", "subscribe", "prompt", "close", "close"]
    );
}

/// A durable action line: the envelope carries `turn_id` and `action_id`
/// (docs/events.md, "The envelope" and "Actions").
fn action_event(kind: &str, session_id: &str, seq: u64, action_id: &str, payload: Value) -> Value {
    let mut value = turn_event(kind, session_id, seq, "t1", payload);
    value["action_id"] = json!(action_id);
    value
}

fn usage_recorded(session_id: &str, seq: u64, generation_id: &str, tokens: Value) -> Value {
    action_event(
        "usage_recorded",
        session_id,
        seq,
        "a_1",
        json!({"generation_id":generation_id,"model":"synthetic/model-a","tokens":tokens,"input_bytes":2048,"cost":null}),
    )
}

#[test]
fn fiber_session_logs_tool_calls_usage_and_the_prompt_from_fibers_event_kinds() {
    let turn = one_fiber_turn(|session_id| {
        vec![
            usage_recorded(
                session_id,
                2,
                "gen-1",
                json!({"input":10,"cache_read":0,"cache_write":{},"output":1}),
            ),
            // A late cost is a second line with the same generation_id,
            // replacing the first (docs/events.md, "usage_recorded").
            usage_recorded(
                session_id,
                3,
                "gen-1",
                json!({"input":100,"cache_read":20,"cache_write":{"5m":5},"output":7}),
            ),
            action_event(
                "tool_call_requested",
                session_id,
                4,
                "a_2",
                json!({"name":"bash","arguments":{"command":"cargo test"},"provider_id":"call_x1"}),
            ),
            action_event(
                "tool_call_started",
                session_id,
                5,
                "a_2",
                json!({"effects":["executes"],"reversible":false}),
            ),
            action_event(
                "tool_call_completed",
                session_id,
                6,
                "a_2",
                json!({"status":"failed","error":{"code":"nonzero_exit","message":"exit 101"},"content":[{"type":"text","text":"1 failed"}]}),
            ),
            usage_recorded(
                session_id,
                7,
                "gen-2",
                json!({"input":3,"cache_read":200,"cache_write":{},"output":4}),
            ),
            turn_event(
                "turn_completed",
                session_id,
                8,
                "t1",
                json!({"outcome":"completed"}),
            ),
        ]
    });
    let started = turn
        .lines
        .iter()
        .find(|line| line["kind"] == "tool.started")
        .expect("a tool.started log line");
    assert_eq!(started["turnId"], "t1", "{started:#}");
    assert_eq!(started["tool"], "bash", "{started:#}");
    assert_eq!(started["callId"], "a_2", "{started:#}");
    let completed = turn
        .lines
        .iter()
        .find(|line| line["kind"] == "tool.completed")
        .expect("a tool.completed log line");
    assert_eq!(completed["tool"], "bash", "{completed:#}");
    assert_eq!(completed["callId"], "a_2", "{completed:#}");
    assert_eq!(completed["status"], "failed", "{completed:#}");
    // Prompt tokens are input, cache reads and cache writes, as the pi host
    // counts them; gen-1 counts once, at its latest line.
    let usage = &turn.watched["session"]["usage"];
    assert_eq!(
        *usage,
        json!({"promptTokens":125 + 203,"outputTokens":7 + 4,"totalTokens":125 + 203 + 7 + 4}),
        "{usage:#}"
    );
    let user = turn
        .lines
        .iter()
        .find(|line| line["kind"] == "user")
        .expect("a user log line for the prompt");
    assert_eq!(user["turnId"], "t1", "{user:#}");
    assert!(
        user["text"]
            .as_str()
            .is_some_and(|text| text.starts_with("Reply with DONE.")),
        "{user:#}"
    );
}

/// One reply: `assistant_message_started`, its text parts, then
/// `assistant_message_completed`, all under the reply's `action_id`
/// (docs/events.md, "text_completed").
fn reply(session_id: &str, seq: u64, action_id: &str, parts: &[&str], outcome: &str) -> Vec<Value> {
    let mut lines = vec![action_event(
        "assistant_message_started",
        session_id,
        seq,
        action_id,
        json!({}),
    )];
    for (n, part) in parts.iter().enumerate() {
        lines.push(text_part(session_id, seq + 1 + n as u64, action_id, part));
    }
    let mut completed = json!({"outcome": outcome});
    if outcome == "failed" {
        completed["error"] = json!({"code":"provider_error","message":"stream reset"});
    }
    lines.push(action_event(
        "assistant_message_completed",
        session_id,
        seq + 1 + parts.len() as u64,
        action_id,
        completed,
    ));
    lines
}

#[test]
fn fiber_session_logs_one_message_per_reply_and_none_for_a_failed_call() {
    let turn = one_fiber_turn(|session_id| {
        let mut lines = reply(session_id, 2, "a_1", &["Partial th"], "failed");
        lines.extend(reply(
            session_id,
            5,
            "a_2",
            &["The test passes now.", "", "\n\nSTATUS: DONE"],
            "completed",
        ));
        lines.push(turn_event(
            "turn_completed",
            session_id,
            11,
            "t1",
            json!({"outcome":"completed"}),
        ));
        lines
    });
    let messages: Vec<&Value> = turn
        .lines
        .iter()
        .filter(|line| line["kind"] == "message")
        .collect();
    assert_eq!(messages.len(), 1, "{messages:#?}");
    assert_eq!(messages[0]["turnId"], "t1", "{:#}", messages[0]);
    assert_eq!(
        messages[0]["text"], "The test passes now.\n\nSTATUS: DONE",
        "{:#}",
        messages[0]
    );
}
