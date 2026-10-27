mod support;

use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

static NEXT: AtomicU64 = AtomicU64::new(0);
const BIN: &str = env!("CARGO_BIN_EXE_delegate");
const MODEL: &str = "muse/muse-spark-1.3-contributor";
const MAX_TEXT: usize = delegate::session::supervisor::MAX_TEXT;

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
            "ds-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let home = base.join("home");
        let fake_dir = base.join("fake-data");
        let inbox = base.join("inbox");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&fake_dir).unwrap();
        let fake = support::muse_host_fake();
        Self {
            base,
            home,
            fake_dir,
            inbox,
            fake,
        }
    }

    fn invoke(&self, args: &[&str]) -> Output {
        self.invoke_with(args, None, "", &[], None)
    }

    fn invoke_with(
        &self,
        args: &[&str],
        input: Option<&[u8]>,
        scenario: &str,
        extra_env: &[(&str, &str)],
        muse_bin: Option<&std::path::Path>,
    ) -> Output {
        self.invoke_timeout(
            args,
            input,
            scenario,
            extra_env,
            muse_bin,
            Duration::from_secs(10),
        )
    }

    fn invoke_timeout(
        &self,
        args: &[&str],
        input: Option<&[u8]>,
        scenario: &str,
        extra_env: &[(&str, &str)],
        muse_bin: Option<&std::path::Path>,
        timeout: Duration,
    ) -> Output {
        let mut command = Command::new(BIN);
        command
            .arg("session")
            .args(args)
            .env("HOME", &self.home)
            .env("MUSE_BIN", muse_bin.unwrap_or(&self.fake))
            .env("FAKE_DIR", &self.fake_dir)
            .env("FAKE_SCENARIO", scenario)
            .env("DELEGATE_SESSION_GRACE_MS", "300")
            .env_remove("TERM")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            });
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

    fn start(&self, brief: &[u8], json_mode: bool, scenario: &str, env: &[(&str, &str)]) -> Output {
        let brief = self.brief_file(brief);
        let mut args = vec![
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            self.inbox.to_str().unwrap(),
        ];
        if json_mode {
            args.push("--json");
        }
        self.invoke_with(&args, None, scenario, env, None)
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

    fn turn_texts(&self) -> Vec<String> {
        std::fs::read_to_string(self.fake_dir.join("requests.jsonl"))
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|request| {
                request["method"] == "turn/start" || request["method"] == "turn/steer"
            })
            .filter_map(|request| {
                request["params"]["input"][0]["text"]
                    .as_str()
                    .map(str::to_string)
            })
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

fn wait_for_signal(path: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !path.exists() {
        assert!(
            Instant::now() < deadline,
            "readiness signal did not arrive: {path:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
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

fn id_from(output: &Output) -> String {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let id = String::from_utf8(output.stdout.clone())
        .unwrap()
        .trim()
        .to_string();
    assert_eq!(id.len(), 36, "unexpected session id {id}");
    id
}

fn assert_json_error(output: &Output, exit: i32, code: &str) {
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
}

fn assert_process_gone(pid: i32) {
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

#[test]
fn start_validates_detaches_and_prints_shared_help() {
    let h = Harness::new();
    let started = h.start(b"HOLD", false, "", &[]);
    let id = id_from(&started);
    assert_eq!(started.stdout, format!("{id}\n").as_bytes());
    let state = h.wait_state(&id, "first turn", |value| value["activeTurnId"].is_string());
    assert_eq!(state["status"], "running");
    assert_eq!(
        unsafe { libc::kill(state["supervisorPid"].as_i64().unwrap() as i32, 0) },
        0
    );
    let json_started = h.start(b"HOLD", true, "", &[]);
    let json_state =
        serde_json::from_slice::<Value>(&json_started.stdout).unwrap()["session"].clone();
    assert!(json_started.status.success());
    assert_eq!(json_state["status"], "running");
    assert!(json_state["activeTurnId"].is_string());

    assert_json_error(
        &h.invoke(&[
            "start",
            "--brief",
            "/missing",
            "--inbox",
            "/tmp/inbox",
            "--json",
        ]),
        2,
        "usage",
    );
    assert_eq!(
        h.invoke(&["start", "--model", MODEL, "--inbox", "/tmp/inbox"])
            .status
            .code(),
        Some(2)
    );
    assert_eq!(
        h.invoke(&["start", "--model", MODEL, "--brief", "/missing"])
            .status
            .code(),
        Some(2)
    );
    let unreadable = h.invoke(&[
        "start",
        "--model",
        MODEL,
        "--brief",
        "/tmp/no-such-session-brief",
        "--inbox",
        h.inbox.to_str().unwrap(),
        "--json",
    ]);
    assert_json_error(&unreadable, 2, "usage");
    for model in [
        "nomodel", "/x", "x/", "a b/c", "muse/", "codex/x", "fiber/x",
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
        ]);
        assert_eq!(result.status.code(), Some(2));
    }
    for contents in [b"".as_slice(), b" \n\t", &[0xff]] {
        let brief = h.brief_file(contents);
        let result = h.invoke(&[
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            h.inbox.to_str().unwrap(),
        ]);
        assert_eq!(result.status.code(), Some(2));
        assert!(!result.stderr.is_empty());
    }
    let brief = h.brief_file(b"valid brief");
    assert_eq!(
        h.invoke(&[
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            h.inbox.to_str().unwrap(),
            "--bad"
        ])
        .status
        .code(),
        Some(2)
    );
    assert_eq!(
        h.invoke(&[
            "start",
            "position",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            h.inbox.to_str().unwrap()
        ])
        .status
        .code(),
        Some(2)
    );

    let usage = h.invoke(&["--help"]);
    assert!(usage.status.success());
    for args in [&["start", "--help"][..], &["send", "id", "--help"]] {
        let output = h.invoke(args);
        assert!(output.status.success());
        assert_eq!(output.stdout, usage.stdout);
    }
    assert_eq!(h.invoke(&["frob"]).status.code(), Some(2));
    let exec_guard = support::exec_lock();
    let global_help = Command::new(BIN).arg("help").output();
    drop(exec_guard);
    let global_help = global_help.unwrap();
    assert!(global_help.status.success());
    assert_eq!(global_help.stdout, usage.stdout);
}

#[test]
fn start_rejects_an_effort_suffix_and_starts_a_bare_id() {
    let h = Harness::new();
    let suffixed = format!("{MODEL}:high");
    let brief = h.brief_file(b"HOLD");
    let rejected = h.invoke(&[
        "start",
        "--model",
        &suffixed,
        "--brief",
        brief.to_str().unwrap(),
        "--inbox",
        h.inbox.to_str().unwrap(),
        "--json",
    ]);
    assert_json_error(&rejected, 2, "usage");
    let message = serde_json::from_slice::<Value>(&rejected.stdout).unwrap()["error"]["message"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(message.contains("no reasoning-effort suffix"), "{message}");

    let started = h.start(b"HOLD", false, "", &[]);
    assert!(started.status.success());
    let id = id_from(&started);
    h.wait_state(&id, "first turn", |value| value["activeTurnId"].is_string());
}

#[test]
fn start_fast_turn_and_startup_failure_paths_are_bounded() {
    let h = Harness::new();
    for marker in ["FAST", "BADMODEL"] {
        let output = h.start(
            marker.as_bytes(),
            false,
            "",
            &[
                ("DELEGATE_SESSION_START_POLL_MS", "500"),
                ("DELEGATE_SESSION_START_WAIT_MS", "2000"),
            ],
        );
        let id = id_from(&output);
        let state = h.wait_state(&id, "fast first turn", |value| value["status"] == "idle");
        assert_eq!(state["turnCount"], 1);
    }
    let brief = h.brief_file(b"brief");
    let missing = h.base.join("missing-muse");
    let failed = h.invoke_with(
        &[
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            h.inbox.to_str().unwrap(),
        ],
        None,
        "",
        &[],
        Some(&missing),
    );
    assert_eq!(failed.status.code(), Some(1));
    let failed_entry = std::fs::read_dir(h.root())
        .unwrap()
        .flatten()
        .find(|entry| {
            std::fs::read(entry.path().join("state.json"))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                .is_some_and(|state| state["dead"]["reason"] == "startFailed")
        })
        .expect("startup failure state retained");
    assert!(failed_entry.path().join("events.jsonl").exists());

    let long = Harness::new();
    let long_home = std::path::PathBuf::from("/tmp").join(format!(
        "ds-{}-{}",
        std::process::id(),
        "x".repeat(120)
    ));
    let output = long.invoke_with(
        &[
            "start",
            "--model",
            MODEL,
            "--brief",
            brief.to_str().unwrap(),
            "--inbox",
            long.inbox.to_str().unwrap(),
        ],
        None,
        "",
        &[("HOME", long_home.to_str().unwrap())],
        None,
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(!long_home.join(".cache/agents/sessions").exists());

    let before = std::fs::read_dir(h.root()).unwrap().count();
    let oversized = h.brief_file(&vec![b'a'; MAX_TEXT + 1]);
    let result = h.invoke(&[
        "start",
        "--model",
        MODEL,
        "--brief",
        oversized.to_str().unwrap(),
        "--inbox",
        h.inbox.to_str().unwrap(),
    ]);
    assert_eq!(result.status.code(), Some(2));
    assert_eq!(std::fs::read_dir(h.root()).unwrap().count(), before);

    let timed_out = h.start(
        b"NO_INIT_ACK",
        false,
        "NO_INIT_ACK",
        &[("DELEGATE_SESSION_START_WAIT_MS", "500")],
    );
    assert_eq!(timed_out.status.code(), Some(1));
    let state = std::fs::read_dir(h.root())
        .unwrap()
        .flatten()
        .filter_map(|entry| {
            let bytes = std::fs::read(entry.path().join("state.json")).ok()?;
            let value: Value = serde_json::from_slice(&bytes).ok()?;
            (value["dead"]["message"] == "session startup timed out").then_some(value)
        })
        .next()
        .expect("timed-out state retained");
    assert_eq!(state["dead"]["reason"], "startFailed");
    assert_process_gone(state["supervisorPid"].as_i64().unwrap() as i32);
    if let Some(host) = state["hostPid"].as_i64() {
        assert_process_gone(host as i32);
    }
}

#[test]
fn startup_timeout_records_supervisor_pid() {
    let h = Harness::new();
    let timed_out = h.start(
        b"NO_INIT_ACK",
        false,
        "NO_INIT_ACK",
        &[("DELEGATE_SESSION_START_WAIT_MS", "0")],
    );
    assert_eq!(timed_out.status.code(), Some(1));
    let state = std::fs::read_dir(h.root())
        .unwrap()
        .flatten()
        .filter_map(|entry| {
            let bytes = std::fs::read(entry.path().join("state.json")).ok()?;
            let value: Value = serde_json::from_slice(&bytes).ok()?;
            (value["dead"]["message"] == "session startup timed out").then_some(value)
        })
        .next()
        .expect("timed-out state retained");
    assert_eq!(state["dead"]["reason"], "startFailed");
    assert_process_gone(state["supervisorPid"].as_i64().unwrap() as i32);
}

#[test]
fn send_text_watch_and_steer_observe_the_same_turn() {
    let h = Harness::new();
    let id = id_from(&h.start(b"FAST", false, "", &[]));
    // A send reports started only once the previous turn has gone idle.
    h.wait_state(&id, "FAST start finished", |value| {
        value["status"] == "idle"
    });
    let sent = h.invoke(&["send", &id, "HOLD hello"]);
    assert!(sent.status.success());
    assert_eq!(sent.stdout, b"started\n");
    let running = h.wait_state(&id, "started send", |value| {
        value["activeTurnId"].is_string()
    });
    assert_eq!(running["status"], "running");

    let (watch_tx, watch_rx) = mpsc::channel();
    let ready_path = h.base.join("watch-ready-send");
    let ready_arg = ready_path.to_string_lossy().into_owned();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            let env = [("DELEGATE_SESSION_TEST_WATCH_READY", ready_arg.as_str())];
            watch_tx
                .send(h.invoke_with(&["watch", &id, "--json"], None, "", &env, None))
                .unwrap()
        });
        wait_for_signal(&ready_path);
        assert!(
            watch_rx.try_recv().is_err(),
            "watch returned after observing a running session"
        );
        let steered = h.invoke(&["send", &id, "steer-me"]);
        assert!(steered.status.success());
        assert_eq!(steered.stdout, b"steered\n");
        std::fs::write(h.fake_dir.join("go"), "").unwrap();
        h.wait_state(&id, "turn completion", |value| value["status"] == "idle");
        assert!(
            watch_rx
                .recv_timeout(Duration::from_secs(10))
                .unwrap()
                .status
                .success()
        );
    });

    std::fs::remove_file(h.fake_dir.join("go")).unwrap();
    let stdin_start = h.invoke_with(
        &["send", &id, "-"],
        Some(b"HOLD stdin start\n"),
        "",
        &[],
        None,
    );
    assert!(stdin_start.status.success());
    assert_eq!(stdin_start.stdout, b"started\n");
    let stdin_steer = h.invoke_with(&["send", &id, "-"], Some(b"stdin steer"), "", &[], None);
    assert!(stdin_steer.status.success());
    assert_eq!(stdin_steer.stdout, b"steered\n");
    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    h.wait_state(&id, "stdin turn end", |value| value["status"] == "idle");

    let dash = h.invoke(&["send", &id, "--", "-starts-with-dash"]);
    assert!(dash.status.success());
    assert_eq!(dash.stdout, b"started\n");
    // A send reports started only once the previous turn has gone idle.
    h.wait_state(&id, "dash turn finished", |value| value["status"] == "idle");
    let count_before = std::fs::read_to_string(h.fake_dir.join("requests.jsonl"))
        .unwrap()
        .lines()
        .count();
    let literal_help = h.invoke(&["send", &id, "--", "--help"]);
    assert!(literal_help.status.success());
    assert_eq!(literal_help.stdout, b"started\n");
    let count_after = std::fs::read_to_string(h.fake_dir.join("requests.jsonl"))
        .unwrap()
        .lines()
        .count();
    assert!(count_after > count_before);
    let help = h.invoke(&["send", &id, "--help"]);
    assert!(help.status.success());
    assert_eq!(help.stdout, h.invoke(&["--help"]).stdout);
    assert_eq!(h.invoke(&["send", &id, "--bogus"]).status.code(), Some(2));
    assert_eq!(
        h.invoke(&["send", &id, "one", "two"]).status.code(),
        Some(2)
    );
    assert_eq!(
        h.invoke_with(&["send", &id, "-"], Some(b""), "", &[], None)
            .status
            .code(),
        Some(2)
    );
    assert_eq!(
        h.invoke_with(&["send", &id, "-"], Some(&[0xff]), "", &[], None)
            .status
            .code(),
        Some(2)
    );
    assert_eq!(
        h.invoke_with(&["send", &id, "-"], Some(b"\0"), "", &[], None)
            .status
            .code(),
        Some(2)
    );
    assert_eq!(h.invoke(&["send", "../x", "x"]).status.code(), Some(2));
    assert_eq!(
        h.invoke(&["send", "00000000-0000-7000-8000-000000000099", "x"])
            .status
            .code(),
        Some(3)
    );
    let json = h.invoke(&["send", &id, "--json", "json-text"]);
    assert!(json.status.success());
    let reply: Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(reply["ok"], true);
    assert!(reply["session"].is_object());
    let texts = h.turn_texts();
    for expected in [
        "FAST",
        "HOLD hello",
        "HOLD stdin start\n",
        "stdin steer",
        "-starts-with-dash",
        "--help",
    ] {
        assert!(
            texts.iter().any(|text| text == expected),
            "missing turn text {expected:?}"
        );
    }
    let large = "x".repeat(MAX_TEXT);
    let max_send = h.invoke_with(&["send", &id, "-"], Some(large.as_bytes()), "", &[], None);
    assert!(
        max_send.status.success(),
        "{}",
        String::from_utf8_lossy(&max_send.stderr)
    );
    assert_eq!(h.turn_texts().last().unwrap().len(), MAX_TEXT);
    h.wait_state(&id, "max-size turn", |value| value["status"] == "idle");
    let control_text = "ESC\u{1b}\r\tline\n";
    assert!(h.invoke(&["send", &id, control_text]).status.success());
    assert!(h.turn_texts().iter().any(|text| text == control_text));
}

#[test]
fn send_right_after_start_steers_an_unfinished_turn() {
    let h = Harness::new();
    let id = id_from(&h.start(b"HOLD first", false, "", &[]));
    // A send to a session with an unfinished turn steers instead of starting.
    // The held-open turn forces the interleaving, so this needs no timing luck.
    let second = h.invoke(&["send", &id, "second"]);
    assert!(second.status.success());
    assert_eq!(second.stdout, b"steered\n");
    let running = h.wait_state(&id, "held turn running", |value| {
        value["activeTurnId"].is_string() && value["status"] == "running"
    });
    assert_eq!(running["status"], "running");
    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    h.wait_state(&id, "held turns finish", |value| value["status"] == "idle");
    let texts = h.turn_texts();
    for expected in ["HOLD first", "second"] {
        assert!(
            texts.iter().any(|text| text == expected),
            "missing turn text {expected:?}"
        );
    }
}

#[test]
fn slow_ack_send_returns_after_running_state_and_two_sends_race_safely() {
    let h = Harness::new();
    let id = id_from(&h.start(b"FAST", false, "SLOW_ACK", &[]));
    // A send reaches the ack-delay path only once the previous turn has gone idle.
    h.wait_state(&id, "FAST start finished", |value| {
        value["status"] == "idle"
    });
    let (send_tx, send_rx) = mpsc::channel();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            send_tx
                .send(h.invoke(&["send", &id, "SLOW_ACK HOLD"]))
                .unwrap()
        });
        let deadline = Instant::now() + Duration::from_secs(10);
        while !h.fake_dir.join("ack.pending").exists() {
            assert!(
                Instant::now() < deadline,
                "fake did not delay the send acknowledgement"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(h.state(&id)["status"], "running");
        assert!(send_rx.try_recv().is_err());
        std::fs::write(h.fake_dir.join("ack.release"), "").unwrap();
        let sent = send_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(sent.status.success());
        assert_eq!(h.state(&id)["status"], "running");

        let (watch_tx, watch_rx) = mpsc::channel();
        let h_ref = &h;
        let id_ref = id.as_str();
        let ready_path = h.base.join("watch-ready-slow-ack");
        let ready_arg = ready_path.to_string_lossy().into_owned();
        scope.spawn(move || {
            let env = [("DELEGATE_SESSION_TEST_WATCH_READY", ready_arg.as_str())];
            watch_tx
                .send(h_ref.invoke_with(&["watch", id_ref], None, "", &env, None))
                .unwrap()
        });
        wait_for_signal(&ready_path);
        assert!(watch_rx.try_recv().is_err());
        std::fs::write(h.fake_dir.join("go"), "").unwrap();
        assert!(
            watch_rx
                .recv_timeout(Duration::from_secs(10))
                .unwrap()
                .status
                .success()
        );
    });

    std::fs::remove_file(h.fake_dir.join("go")).unwrap();
    let race_id = id_from(&h.start(b"FAST", false, "", &[]));
    // The first racing send reports started only once the start turn has gone idle.
    h.wait_state(&race_id, "race start finished", |value| {
        value["status"] == "idle"
    });
    let (tx, rx) = mpsc::channel();
    std::thread::scope(|scope| {
        let h_ref = &h;
        let race_id_ref = race_id.as_str();
        for text in ["HOLD left", "HOLD right"] {
            let tx = tx.clone();
            scope.spawn(move || tx.send(h_ref.invoke(&["send", race_id_ref, text])).unwrap());
        }
        let first = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let second = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(first.status.success() && second.status.success());
        let mut results = [
            String::from_utf8(first.stdout).unwrap(),
            String::from_utf8(second.stdout).unwrap(),
        ];
        results.sort();
        // Contract: idle sends start; running sends steer (docs/delegate-sessions.md:11).
        assert_eq!(results, ["started\n", "steered\n"]);
    });
    std::fs::write(h.fake_dir.join("go"), "").unwrap();
    h.wait_state(&race_id, "racing turns finish", |value| {
        value["status"] == "idle"
    });

    let reconnect_id = id_from(&h.start(b"HOLD", false, "", &[]));
    let stale_supervisor = h.state(&reconnect_id)["supervisorPid"].as_i64().unwrap() as i32;
    let host_pid = h.state(&reconnect_id)["hostPid"].as_i64().unwrap() as i32;
    unsafe { libc::kill(stale_supervisor, libc::SIGKILL) };
    assert_process_gone(stale_supervisor);
    let socket = h.root().join(&reconnect_id).join("sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let exec_guard = support::exec_lock();
    let stand_in = Command::new("/bin/sleep")
        .arg("30")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    drop(exec_guard);
    let mut stand_in = stand_in.unwrap();
    let mut state = h.state(&reconnect_id);
    state["supervisorPid"] = json!(stand_in.id());
    std::fs::write(
        h.root().join(&reconnect_id).join("state.json"),
        serde_json::to_vec(&state).unwrap(),
    )
    .unwrap();
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stand_in.kill().unwrap();
                    stand_in.wait().unwrap();
                    drop(stream);
                    return;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        Instant::now() < deadline,
                        "send did not reach the stale socket"
                    );
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("socket accept failed: {error}"),
            }
        }
    });
    let raced = h.invoke(&["send", &reconnect_id, "race the disconnect"]);
    server.join().unwrap();
    assert_eq!(
        raced.status.code(),
        Some(4),
        "{}",
        String::from_utf8_lossy(&raced.stderr)
    );
    assert_eq!(h.state(&reconnect_id)["dead"]["reason"], "supervisorDied");
    // Contract: one inbox note per successful idle/dead transition; competing dead-settlers share one fallback (docs/delegate-sessions.md:13-15).
    assert_eq!(h.notes(&reconnect_id, "dead").len(), 1);
    assert_process_gone(host_pid);
}

#[test]
fn stop_interrupt_busy_and_unresponsive_host_have_distinct_results() {
    let h = Harness::new();
    let id = id_from(&h.start(b"HOLD_INTERRUPT", false, "HOLD_INTERRUPT", &[]));
    let (tx, rx) = mpsc::channel();
    std::thread::scope(|scope| {
        scope.spawn(|| tx.send(h.invoke(&["stop", &id, "--interrupt"])).unwrap());
        h.wait_state(&id, "interrupt in progress", |value| {
            value["stopping"] == true
        });
        assert_eq!(
            h.invoke(&["send", &id, "while-stopping"]).status.code(),
            Some(5)
        );
        std::fs::write(h.fake_dir.join("go"), "").unwrap();
        h.wait_state(&id, "interrupt completed", |value| {
            value["status"] == "idle" && value["stopping"] == false
        });
        let stopped = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(stopped.status.success());
        assert_eq!(stopped.stdout, b"interrupted\n");
    });
    std::fs::remove_file(h.fake_dir.join("go")).unwrap();
    let next = h.invoke(&["send", &id, "HOLD plain-stop"]);
    assert!(next.status.success());
    assert_eq!(next.stdout, b"started\n");
    h.wait_state(&id, "running before plain stop", |value| {
        value["status"] == "running"
    });
    let (tx, rx) = mpsc::channel();
    std::thread::scope(|scope| {
        scope.spawn(|| tx.send(h.invoke(&["stop", &id])).unwrap());
        h.wait_state(&id, "plain stop in progress", |value| {
            value["stopping"] == true
        });
        std::fs::write(h.fake_dir.join("go"), "").unwrap();
        let stopped = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(stopped.status.success());
        assert_eq!(stopped.stdout, b"stopped\n");
    });
    assert_eq!(h.state(&id)["status"], "dead");

    let ignored = Harness::new();
    let ignored_id = id_from(&ignored.start(b"IGNORE_INTERRUPT", false, "IGNORE_INTERRUPT", &[]));
    let state = ignored.state(&ignored_id);
    let host_pid = state["hostPid"].as_i64().unwrap() as i32;
    let (tx, rx) = mpsc::channel();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            tx.send(ignored.invoke_timeout(
                &["stop", &ignored_id, "--interrupt", "--json"],
                None,
                "",
                &[],
                None,
                Duration::from_secs(15),
            ))
            .unwrap()
        });
        ignored.wait_state(&ignored_id, "ignored interrupt", |value| {
            value["stopping"] == true
        });
        assert_eq!(
            ignored.invoke(&["send", &ignored_id, "busy"]).status.code(),
            Some(5)
        );
        let result = rx.recv_timeout(Duration::from_secs(15)).unwrap();
        assert_json_error(&result, 4, "dead");
    });
    assert_eq!(ignored.state(&ignored_id)["status"], "dead");
    assert_eq!(
        ignored
            .invoke(&["send", &ignored_id, "after-dead"])
            .status
            .code(),
        Some(4)
    );
    assert_process_gone(host_pid);

    let stubborn = Harness::new();
    let stubborn_id = id_from(&stubborn.start(b"FAST", false, "IGNORE_EOF", &[]));
    let host = stubborn.state(&stubborn_id)["hostPid"].as_i64().unwrap() as i32;
    let then = Instant::now();
    let stopped = stubborn.invoke(&["stop", &stubborn_id]);
    assert!(stopped.status.success());
    assert!(then.elapsed() < Duration::from_secs(1));
    assert_process_gone(host);
}

#[test]
fn watch_logs_inbox_and_dead_session_codes_follow_state() {
    let h = Harness::new();
    let id = id_from(&h.start(b"HOLD", false, "", &[]));
    let (watch_tx, watch_rx) = mpsc::channel();
    let ready_path = h.base.join("watch-ready-log-test");
    let ready_arg = ready_path.to_string_lossy().into_owned();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            let env = [("DELEGATE_SESSION_TEST_WATCH_READY", ready_arg.as_str())];
            watch_tx
                .send(h.invoke_with(&["watch", &id, "--json"], None, "", &env, None))
                .unwrap()
        });
        wait_for_signal(&ready_path);
        assert!(watch_rx.try_recv().is_err());
        std::fs::write(h.fake_dir.join("go"), "").unwrap();
        h.wait_state(&id, "idle", |value| value["status"] == "idle");
        assert!(
            watch_rx
                .recv_timeout(Duration::from_secs(10))
                .unwrap()
                .status
                .success()
        );
    });
    // Contract: one inbox note per successful idle/dead transition; competing dead-settlers share one fallback (docs/delegate-sessions.md:13-15).
    assert_eq!(h.notes(&id, "idle").len(), 1);

    let path = h.root().join(&id).join("events.jsonl");
    let events = std::fs::read(&path).unwrap();
    assert_eq!(h.invoke(&["logs", &id]).stdout, events);
    let logs: Value = serde_json::from_slice(&h.invoke(&["logs", &id, "--json"]).stdout).unwrap();
    let expected: Vec<Value> = String::from_utf8_lossy(&events)
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(logs, json!({"ok":true,"lines":expected}));

    let (follow_tx, follow_rx) = mpsc::channel();
    let ready_path = h.base.join("logs-ready-follow");
    let ready_arg = ready_path.to_string_lossy().into_owned();
    let stopped = std::thread::scope(|scope| {
        scope.spawn(|| {
            let env = [("DELEGATE_SESSION_TEST_LOGS_READY", ready_arg.as_str())];
            follow_tx
                .send(h.invoke_with(&["logs", &id, "--follow", "--json"], None, "", &env, None))
                .unwrap()
        });
        wait_for_signal(&ready_path);
        let result = h.invoke(&["stop", &id, "--json"]);
        assert!(result.status.success());
        let follow = follow_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(follow.status.success());
        let lines: Vec<Value> = String::from_utf8_lossy(&follow.stdout)
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        // Contract: death appends session.dead before logs --follow exits (docs/delegate-sessions.md:7).
        assert_eq!(lines.last().unwrap()["kind"], "session.dead");
        result
    });
    assert_eq!(h.state(&id)["status"], "dead");
    // Contract: one inbox note per successful idle/dead transition; competing dead-settlers share one fallback (docs/delegate-sessions.md:13-15).
    assert_eq!(h.notes(&id, "dead").len(), 1);
    assert!(stopped.stderr.is_empty());
    assert!(h.invoke(&["stop", &id]).status.success());
    assert_json_error(
        &h.invoke(&["stop", &id, "--interrupt", "--json"]),
        4,
        "dead",
    );
    assert_eq!(h.invoke(&["send", &id, "dead"]).status.code(), Some(4));
    assert_eq!(h.invoke(&["watch", &id]).status.code(), Some(4));
    assert_json_error(
        &h.invoke(&["watch", "00000000-0000-7000-8000-000000000099", "--json"]),
        3,
        "noSession",
    );
    assert_eq!(
        h.invoke(&["logs", "00000000-0000-7000-8000-000000000099"])
            .status
            .code(),
        Some(3)
    );
}

#[test]
fn no_tty_stdin_closed_and_partial_log_lines_are_safe() {
    let h = Harness::new();
    let empty = h.invoke(&["list", "--json"]);
    assert_eq!(
        serde_json::from_slice::<Value>(&empty.stdout).unwrap()["sessions"],
        json!([])
    );
    let started = h.start(b"FAST", true, "", &[]);
    let value: Value = serde_json::from_slice(&started.stdout).unwrap();
    let id = value["session"]["id"].as_str().unwrap();
    for args in [
        vec!["send", id, "--json", "text"],
        vec!["logs", id, "--json"],
        vec!["watch", id, "--json"],
        vec!["list", "--json"],
    ] {
        let result = h.invoke(&args);
        assert!(
            result.status.success(),
            "{} {}",
            args.join(" "),
            String::from_utf8_lossy(&result.stderr)
        );
        assert!(result.stderr.is_empty());
        assert!(serde_json::from_slice::<Value>(&result.stdout).is_ok());
    }
    let no_stdin = h.invoke(&["send", id, "-", "--json"]);
    assert_json_error(&no_stdin, 2, "usage");
    h.wait_state(id, "idle before interrupt no-op", |value| {
        value["status"] == "idle"
    });
    let idle_interrupt = h.invoke(&["stop", id, "--interrupt", "--json"]);
    assert!(idle_interrupt.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&idle_interrupt.stdout).unwrap()["interrupted"],
        false
    );
    assert!(h.invoke(&["stop", id, "--json"]).status.success());
    let events_path = h.root().join(id).join("events.jsonl");
    let mut bytes = std::fs::read(&events_path).unwrap();
    bytes.extend_from_slice(b"not json\n{\"partial\":true}");
    std::fs::write(&events_path, bytes).unwrap();
    let plain = h.invoke(&["logs", id]);
    assert!(plain.status.success());
    assert!(plain.stdout.ends_with(b"not json\n"));
    assert!(!plain.stdout.ends_with(b"{\"partial\":true}"));
    let json_logs: Value =
        serde_json::from_slice(&h.invoke(&["logs", id, "--json"]).stdout).unwrap();
    assert_eq!(
        json_logs["lines"].as_array().unwrap().last().unwrap()["kind"],
        "unparsed"
    );
    for args in [
        vec!["stop", id, "--json"],
        vec!["logs", id, "--follow", "--json"],
    ] {
        let result = h.invoke(&args);
        assert!(result.status.success());
        if args[0] == "logs" {
            for line in String::from_utf8_lossy(&result.stdout).lines() {
                assert!(serde_json::from_str::<Value>(line).is_ok());
            }
        } else {
            assert!(serde_json::from_slice::<Value>(&result.stdout).is_ok());
        }
    }
}

#[test]
fn list_sorts_by_started_time_then_id_and_marks_unreadable() {
    let h = Harness::new();
    let first = id_from(&h.start(b"FAST", false, "", &[]));
    let second = id_from(&h.start(b"FAST", false, "", &[]));
    let third = id_from(&h.start(b"FAST", false, "", &[]));
    for id in [&first, &second, &third] {
        let stopped = h.invoke(&["stop", id]);
        assert!(
            stopped.status.success(),
            "failed to stop {id}: {}",
            String::from_utf8_lossy(&stopped.stderr)
        );
        h.wait_state(id, "session stopped before editing list state", |state| {
            state["status"] == "dead"
        });
    }
    for (id, started) in [(&first, 20), (&second, 10), (&third, 10)] {
        let path = h.root().join(id).join("state.json");
        let mut state: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        state["startedAt"] = json!(started);
        std::fs::write(path, serde_json::to_vec(&state).unwrap()).unwrap();
    }
    let corrupt = h.root().join("00000000-0000-7000-8000-000000000088");
    std::fs::create_dir_all(&corrupt).unwrap();
    std::fs::write(corrupt.join("state.json"), b"not json").unwrap();
    let list = h.invoke(&["list", "--json"]);
    assert!(list.status.success());
    let entries = serde_json::from_slice::<Value>(&list.stdout).unwrap()["sessions"]
        .as_array()
        .unwrap()
        .clone();
    // Contract: list includes each valid session dir and marks corrupt state unreadable (docs/delegate-sessions.md:9).
    assert_eq!(entries.len(), 4);
    let mut tied = [second.as_str(), third.as_str()];
    tied.sort();
    // Contract: readable sessions sort by startedAt, then id (docs/delegate-sessions.md:9).
    assert_eq!(entries[0]["id"], tied[0]);
    assert_eq!(entries[1]["id"], tied[1]);
    assert_eq!(entries[2]["id"], first);
    assert_eq!(entries[3]["status"], "unreadable");
    let human = String::from_utf8(h.invoke(&["list"]).stdout).unwrap();
    assert!(human.lines().any(|line| line
        == format!(
            "{} unreadable",
            corrupt.file_name().unwrap().to_string_lossy()
        )));
    for id in [&first, &second, &third] {
        let state = h.state(id);
        let line = format!(
            "{} {} {} turns={} {}",
            state["id"].as_str().unwrap(),
            state["status"].as_str().unwrap(),
            state["model"].as_str().unwrap(),
            state["turnCount"],
            state["cwd"].as_str().unwrap()
        );
        assert!(
            human.lines().any(|actual| actual == line),
            "missing list line {line}"
        );
    }
}

#[test]
fn dead_supervisor_is_settled_once_and_racing_sends_are_started_then_steered() {
    let h = Harness::new();
    let id = id_from(&h.start(b"HOLD", false, "", &[]));
    let state = h.state(&id);
    let supervisor_pid = state["supervisorPid"].as_i64().unwrap() as i32;
    let host_pid = state["hostPid"].as_i64().unwrap() as i32;
    unsafe {
        libc::kill(supervisor_pid, libc::SIGKILL);
    }
    let (watch_tx, watch_rx) = mpsc::channel();
    let (list_tx, list_rx) = mpsc::channel();
    std::thread::scope(|scope| {
        scope.spawn(|| watch_tx.send(h.invoke(&["watch", &id])).unwrap());
        scope.spawn(|| list_tx.send(h.invoke(&["list", "--json"])).unwrap());
        let watch = watch_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let list = list_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(watch.status.code(), Some(4));
        assert!(list.status.success());
    });
    assert_eq!(h.state(&id)["dead"]["reason"], "supervisorDied");
    // Contract: one inbox note per successful idle/dead transition; competing dead-settlers share one fallback (docs/delegate-sessions.md:13-15).
    assert_eq!(h.notes(&id, "dead").len(), 1);
    assert_process_gone(host_pid);

    let second = id_from(&h.start(b"FAST", false, "", &[]));
    // The first racing send reports started only once the start turn has gone idle.
    h.wait_state(&second, "second start finished", |value| {
        value["status"] == "idle"
    });
    let (tx, rx) = mpsc::channel();
    std::thread::scope(|scope| {
        let h_ref = &h;
        let second_ref = second.as_str();
        for text in ["HOLD left", "HOLD right"] {
            let tx = tx.clone();
            scope.spawn(move || tx.send(h_ref.invoke(&["send", second_ref, text])).unwrap());
        }
        let one = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let two = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(one.status.success() && two.status.success());
        let mut replies = [
            String::from_utf8(one.stdout).unwrap(),
            String::from_utf8(two.stdout).unwrap(),
        ];
        replies.sort();
        // Contract: idle sends start; running sends steer (docs/delegate-sessions.md:11).
        assert_eq!(replies, ["started\n", "steered\n"]);
    });
}
