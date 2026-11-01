//! Drives the real `delegate` binary against a fake Fiber hub.

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
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(args)
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
        let path = self.dir.join("delegate-jobs").join(format!("{id}.json"));
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
        assert!(count > 0, "client closed before sending the next command");
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

fn answer_prompt(
    conn: &mut FakeConn,
    session_id: &str,
    last_seq: u64,
    expected_prompt: Option<&str>,
    text: &str,
    questions: Option<Value>,
    exit_code: i64,
    after_prompt: impl FnOnce(),
) {
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
    let path = e.dir.join("delegate-jobs").join(format!("{id}.json"));
    let mut record: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    f(&mut record);
    std::fs::write(&path, serde_json::to_string(&record).unwrap()).unwrap();
}

#[test]
fn fiber_run_books_subscription_cost_as_estimated() {
    let e = Env::new("cost");
    let prompt = "Reply with the word DONE.";
    let expected = expected_prompt(prompt);
    let fake = e.fake_hub(1, move |_, session_id, conn| {
        accept_start(conn, session_id);
        subscribe_fresh(conn, session_id);
        answer_prompt(conn, session_id, 0, Some(&expected), "DONE", None, 0, || {});
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
        commands[0][2]["args"]["content"][0]["text"],
        expected_prompt(prompt)
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
            Some(&fake_expected),
            "DONE",
            None,
            0,
            || {},
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
                Some(&first_expected),
                "Waiting for an answer",
                Some(json!(["Which codeword should I use?"])),
                0,
                || {},
            );
        } else {
            subscribe_resumed(conn, session_id);
            answer_prompt(
                conn,
                session_id,
                4,
                Some(&answer_expected),
                "DONE",
                None,
                0,
                || {},
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
            answer_prompt(conn, session_id, 0, None, "DONE", None, 0, || {});
        } else {
            subscribe_resumed(conn, session_id);
            answer_prompt(conn, session_id, 4, None, "DONE", None, 0, || {
                std::fs::write(work.join("zebra-17.txt"), "ok").unwrap();
            });
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
            answer_prompt(conn, sid, 0, Some(&expected), "DONE", None, 0, || {});
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
        answer_prompt(conn, session_id, 0, None, "DONE", None, 0, || {});
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
        answer_prompt(conn, session_id, 0, None, "provider failed", None, 1, || {});
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
