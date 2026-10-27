mod support;

use delegate::session::{
    inbox, ipc,
    state::{self, DeadReason, Paths, State, Status},
    supervisor::{self, SupervisorConfig},
};
use serde_json::{Value, json};
use std::io::{BufRead, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

static NEXT: AtomicU64 = AtomicU64::new(0);

fn temp_root(prefix: &str) -> std::path::PathBuf {
    std::path::PathBuf::from("/tmp").join(format!(
        "{prefix}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}

fn paths() -> (Paths, String, std::path::PathBuf) {
    let root = temp_root("ds");
    let id = "00000000-0000-7000-8000-000000000001".to_string();
    std::fs::create_dir_all(root.join(&id)).unwrap();
    (Paths::new(root.clone()), id, root)
}

#[derive(Clone, Copy)]
struct Bounds {
    rpc_ms: u64,
    steer_ms: u64,
    interrupt_ms: u64,
    stop_ms: u64,
    term_ms: u64,
    read_ms: u64,
}

impl Default for Bounds {
    fn default() -> Self {
        Self {
            rpc_ms: 300,
            steer_ms: 300,
            interrupt_ms: 300,
            stop_ms: 300,
            term_ms: 300,
            read_ms: 300,
        }
    }
}

struct Session {
    paths: Paths,
    id: String,
    root: std::path::PathBuf,
    fake_dir: std::path::PathBuf,
    done: mpsc::Receiver<i32>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Session {
    fn spawn(scenario: &str, brief: &str, inbox: Option<&std::path::Path>, bounds: Bounds) -> Self {
        Self::spawn_with_options(scenario, brief, inbox, bounds, None, false, None)
    }

    fn spawn_with_options(
        scenario: &str,
        brief: &str,
        inbox: Option<&std::path::Path>,
        bounds: Bounds,
        muse_bin: Option<String>,
        long_root: bool,
        panic_mode: Option<&str>,
    ) -> Self {
        let root = if long_root {
            std::path::PathBuf::from("/tmp").join(format!(
                "ds-long-{}-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed),
                "x".repeat(120)
            ))
        } else {
            temp_root("ds-supervisor")
        };
        let id = format!(
            "00000000-0000-7000-8000-{:012x}",
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let paths = Paths::new(root.clone());
        state::create_session_dir(&paths, &id).unwrap();
        let cwd = root.to_string_lossy().into_owned();
        let inbox_text = inbox
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default();
        let value = state::new_state(&id, "muse/muse-spark-1.3-contributor", &cwd, &inbox_text, 1);
        state::write_state(&paths, &value).unwrap();
        let brief_path = paths.brief_file(&id);
        let mut brief_file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&brief_path)
            .unwrap();
        brief_file.write_all(brief.as_bytes()).unwrap();
        std::fs::set_permissions(&brief_path, std::fs::Permissions::from_mode(0o600)).unwrap();

        let fake_dir = root.join("fake");
        std::fs::create_dir_all(&fake_dir).unwrap();
        let fake = support::muse_host_fake();
        std::fs::write(
            root.join("fake-config.json"),
            serde_json::to_string(&json!({"fakeDir": fake_dir, "scenario": scenario})).unwrap(),
        )
        .unwrap();

        if let Some(mode) = panic_mode {
            unsafe {
                std::env::set_var("DELEGATE_SESSION_TEST_PANIC", format!("{id}:{mode}"));
            }
        }
        let config = SupervisorConfig {
            paths: paths.clone(),
            muse_bin: muse_bin.unwrap_or_else(|| fake.to_string_lossy().into_owned()),
            rpc_timeout: Duration::from_millis(bounds.rpc_ms),
            steer_settle: Duration::from_millis(bounds.steer_ms),
            interrupt_wait: Duration::from_millis(bounds.interrupt_ms),
            stop_grace: Duration::from_millis(bounds.stop_ms),
            term_wait: Duration::from_millis(bounds.term_ms),
            request_read: Duration::from_millis(bounds.read_ms),
        };
        let (done_tx, done) = mpsc::channel();
        let session_id = id.clone();
        let thread = std::thread::spawn(move || {
            let code = supervisor::run(config, &session_id);
            let _ = done_tx.send(code);
        });
        Self {
            paths,
            id,
            root,
            fake_dir,
            done,
            thread: Some(thread),
        }
    }

    fn state(&self) -> State {
        state::read_state(&self.paths, &self.id).unwrap()
    }

    fn until(&self, what: &str, predicate: impl Fn(&State) -> bool) -> State {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let current = self.state();
            if predicate(&current) {
                return current;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}: {current:?}"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn requests(&self) -> Vec<Value> {
        let path = self.fake_dir.join("requests.jsonl");
        let Ok(contents) = std::fs::read_to_string(path) else {
            return Vec::new();
        };
        contents
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }

    fn request(&self, request: &Value) -> Result<Value, ipc::IpcError> {
        self.request_timeout(request, Duration::from_secs(10))
    }

    fn request_timeout(&self, request: &Value, timeout: Duration) -> Result<Value, ipc::IpcError> {
        ipc::request(&self.paths, &self.id, request, timeout)
    }

    fn events(&self) -> Vec<Value> {
        std::fs::read_to_string(self.paths.events_file(&self.id))
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }

    fn send(&self, text: &str) -> Result<Value, ipc::IpcError> {
        self.request(&json!({"op":"send","text":text}))
    }

    fn stop(&self, interrupt: bool) -> Result<Value, ipc::IpcError> {
        self.request(&json!({"op":"stop","interrupt":interrupt}))
    }

    fn wait_run(&mut self) -> i32 {
        let code = self
            .done
            .recv_timeout(Duration::from_secs(10))
            .expect("supervisor run deadline");
        self.thread.take().unwrap().join().unwrap();
        code
    }

    fn stop_and_join(&mut self) -> i32 {
        if self.state().status != Status::Dead {
            let _ = self.stop(false);
        }
        self.wait_run()
    }

    fn inbox_notes(&self, inbox_path: &std::path::Path) -> Vec<String> {
        let Ok(entries) = std::fs::read_dir(inbox_path) else {
            return Vec::new();
        };
        entries
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .path()
                    .extension()
                    .is_some_and(|extension| extension == "md")
            })
            .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
            .collect()
    }

    fn inbox_note_names(&self, inbox_path: &std::path::Path) -> Vec<std::ffi::OsString> {
        let Ok(entries) = std::fs::read_dir(inbox_path) else {
            return Vec::new();
        };
        entries
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .path()
                    .extension()
                    .is_some_and(|extension| extension == "md")
            })
            .map(|entry| entry.file_name())
            .collect()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let mut completed = false;
        if self.thread.is_some() {
            let _ = self.stop(false);
            completed = self.done.recv_timeout(Duration::from_secs(5)).is_ok();
            if !completed
                && let Ok(current) = state::read_state(&self.paths, &self.id)
                && let Some(pid) = current.host_pid
            {
                unsafe { libc::kill(-pid, libc::SIGKILL) };
                completed = self.done.recv_timeout(Duration::from_secs(5)).is_ok();
            }
            if completed && let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
        if completed || self.thread.is_none() {
            let _ = std::fs::set_permissions(
                self.paths.dir(&self.id),
                std::fs::Permissions::from_mode(0o700),
            );
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}

fn make_stale_socket(socket: &std::path::Path) -> OwnedFd {
    use std::os::unix::ffi::OsStrExt;
    // A bound-but-never-listening stream socket refuses connects with
    // ECONNREFUSED whether or not a copy of its fd is alive, so a leaked fd
    // cannot turn this stale inode back into a reachable server.
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    assert!(raw >= 0, "socket() failed to create an AF_UNIX fd");
    // SAFETY: `socket()` returned an open fd owned by this function.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let bytes = socket.as_os_str().as_bytes();
    // SAFETY: zeroed; `sun_len` exists only on BSD and stays zero.
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    assert!(
        bytes.len() < addr.sun_path.len(),
        "socket path leaves no room for its NUL terminator"
    );
    for (i, &b) in bytes.iter().enumerate() {
        addr.sun_path[i] = b as libc::c_char;
    }
    // `sun_path` follows `sun_family` with no padding on Linux or macOS, and
    // the trailing +1 carries the NUL terminator the length check reserved.
    let len = (std::mem::size_of::<libc::sa_family_t>() + bytes.len() + 1) as libc::socklen_t;
    // SAFETY: `addr` is a valid `sockaddr_un` of `len` bytes for `bind`.
    let bound = unsafe {
        libc::bind(
            fd.as_raw_fd(),
            &addr as *const _ as *const libc::sockaddr,
            len,
        )
    };
    assert_eq!(bound, 0, "bind() failed to claim the stale socket path");
    fd
}

#[test]
fn ipc_request_reports_a_stale_socket_as_unreachable() {
    let (paths, id, root) = paths();
    let socket = paths.socket_path(&id).unwrap();
    drop(make_stale_socket(&socket));

    let result = ipc::request(
        &paths,
        &id,
        &json!({"op":"send","text":"hello"}),
        Duration::from_millis(100),
    );

    assert!(
        matches!(result, Err(ipc::IpcError::Unreachable(_))),
        "{result:?}"
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn ipc_request_reports_a_stale_socket_as_unreachable_while_a_copy_of_its_fd_is_open() {
    let (paths, id, root) = paths();
    let socket = paths.socket_path(&id).unwrap();
    let stale = make_stale_socket(&socket);
    // Stand-in for a forked child's copy of the listening fd: it keeps the
    // socket accept()-able after the test hands its own handle to the holder.
    let held = stale.try_clone().unwrap();
    let (done_tx, done_rx) = mpsc::channel();
    let holder = std::thread::spawn(move || {
        let listener = UnixListener::from(stale);
        // On a non-listening socket this errors at once and the thread exits.
        if let Ok((stream, _)) = listener.accept() {
            let mut line = String::new();
            let _ = std::io::BufReader::new(stream).read_line(&mut line);
        }
        let _ = done_tx.send(());
    });

    let result = ipc::request(
        &paths,
        &id,
        &json!({"op":"send","text":"hello"}),
        Duration::from_millis(100),
    );

    // The holder reads the request line before dropping it, so the client sees
    // a clean EOF and reports BadReply rather than an Unreachable reset.
    assert!(
        matches!(result, Err(ipc::IpcError::Unreachable(_))),
        "{result:?}"
    );
    drop(held);
    done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    holder.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn ipc_request_times_out_when_the_server_does_not_reply() {
    let (paths, id, root) = paths();
    let socket = paths.socket_path(&id).unwrap();
    let listener = UnixListener::bind(&socket).unwrap();
    let (release_tx, release_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let server = std::thread::spawn(move || {
        let (_stream, _) = listener.accept().unwrap();
        let _ = release_rx.recv_timeout(Duration::from_secs(2));
        let _ = done_tx.send(());
    });

    let timeout = Duration::from_millis(100);
    let started = Instant::now();
    let result = ipc::request(&paths, &id, &json!({"op":"send","text":"hello"}), timeout);
    let elapsed = started.elapsed();

    assert!(matches!(result, Err(ipc::IpcError::Timeout)));
    assert!(elapsed >= timeout.saturating_sub(Duration::from_millis(10)));
    let _ = release_tx.send(());
    done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    server.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn inbox_utc_stamp_handles_exact_time_day_boundary_and_leap_day() {
    assert_eq!(inbox::utc_stamp(1_792_714_029_748), "20261023T000709Z");
    assert_eq!(inbox::utc_stamp(1_792_713_599_999), "20261022T235959Z");
    assert_eq!(inbox::utc_stamp(1_792_713_600_000), "20261023T000000Z");
    assert_eq!(inbox::utc_stamp(1_582_934_400_000), "20200229T000000Z");
}

#[test]
fn inbox_notify_writes_an_atomic_idle_note_with_a_drain_compatible_name() {
    let root = temp_root("ds-inbox");
    let inbox_path = root.join("nested/inbox");
    let id = "00000000-0000-7000-8000-000000000001";

    let path = inbox::notify(&inbox_path, id, inbox::Note::Idle, 1_792_714_029_748).unwrap();

    assert!(inbox_path.is_dir());
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        format!("[session {id} idle]\n")
    );
    let name = path.file_name().unwrap().to_str().unwrap();
    assert!(name.ends_with(".md"));
    let fields = name.strip_suffix(".md").unwrap();
    let (without_random, random) = fields.rsplit_once('-').unwrap();
    let (without_pid, pid) = without_random.rsplit_once('-').unwrap();
    let (sender, stamp) = without_pid.rsplit_once('-').unwrap();
    assert_eq!(sender, format!("session-{id}"));
    assert_eq!(stamp, "20261023T000709Z");
    assert!(!pid.is_empty());
    assert!(!random.is_empty());
    assert!(std::fs::read_dir(&inbox_path).unwrap().all(|entry| {
        !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains(".tmp.")
    }));

    let dead = inbox::notify(&inbox_path, id, inbox::Note::Dead, 1_792_714_029_748).unwrap();
    assert_eq!(
        std::fs::read_to_string(dead).unwrap(),
        format!("[session {id} dead]\n")
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn inbox_notify_returns_an_error_when_inbox_is_a_file() {
    let root = temp_root("ds-inbox-file");
    std::fs::create_dir_all(&root).unwrap();
    let inbox_path = root.join("not-a-directory");
    std::fs::write(&inbox_path, "keep me").unwrap();

    let result = inbox::notify(
        &inbox_path,
        "00000000-0000-7000-8000-000000000001",
        inbox::Note::Idle,
        1_792_714_029_748,
    );

    assert!(result.is_err());
    assert_eq!(std::fs::read_to_string(inbox_path).unwrap(), "keep me");
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn supervisor_starts_the_host_with_the_brief_and_expected_permissions() {
    let mut session = Session::spawn("HOLD", "exact brief bytes", None, Bounds::default());
    let current = session.until("first turn acknowledgement", |state| {
        state.status == Status::Running && state.active_turn_id.is_some()
    });

    assert_eq!(current.turn_count, 1);
    assert_eq!(current.muse_session_id.as_deref(), Some("fake-session"));
    assert!(current.supervisor_pid.is_some());
    let host_pid = current.host_pid.unwrap();
    assert!(host_pid > 1);
    // prepublish spawn record holds the published host pid, mode 0600.
    assert_eq!(
        std::fs::read_to_string(session.paths.host_spawn_file(&session.id))
            .unwrap()
            .parse::<i32>()
            .unwrap(),
        host_pid
    );
    assert_eq!(mode(&session.paths.host_spawn_file(&session.id)), 0o600);
    assert_eq!(current.cwd, session.root.to_string_lossy());

    let requests = session.requests();
    let start = requests
        .iter()
        .find(|request| request["method"] == "session/start")
        .unwrap();
    assert_eq!(start["params"]["approvalMode"], "allowAll");
    assert_eq!(start["params"]["providerId"], "meta");
    assert_eq!(start["params"]["modelId"], "muse-spark-1.3-contributor");
    assert_eq!(start["params"]["workspaceRoot"], current.cwd);
    let turn = requests
        .iter()
        .find(|request| request["method"] == "turn/start")
        .unwrap();
    assert_eq!(turn["params"]["input"][0]["text"], "exact brief bytes");
    assert_eq!(
        std::fs::read_to_string(session.fake_dir.join("argv.txt")).unwrap(),
        "serve\n--provider\nmeta\n--model\nmuse-spark-1.3-contributor\n--disable-sandbox\n"
    );
    assert_eq!(
        mode(&session.paths.socket_path(&session.id).unwrap()),
        0o600
    );
    assert_eq!(mode(&session.paths.brief_file(&session.id)), 0o600);
    assert_eq!(mode(&session.paths.host_stderr(&session.id)), 0o600);
    assert_eq!(mode(&session.paths.events_file(&session.id)), 0o600);
    assert_eq!(mode(&session.paths.dir(&session.id)), 0o700);
    assert_eq!(session.stop_and_join(), 0);
}

#[test]
fn supervisor_fast_turn_logs_events_and_writes_idle_then_dead_notes() {
    let inbox_path = temp_root("ds-supervisor-inbox");
    let mut session = Session::spawn("FAST", "brief", Some(&inbox_path), Bounds::default());
    let current = session.until("completed first turn and idle note", |state| {
        state.status == Status::Idle
            && state.last_turn.is_some()
            && session
                .inbox_notes(&inbox_path)
                .contains(&format!("[session {} idle]\n", session.id))
    });
    assert_eq!(current.last_turn.as_ref().unwrap().terminal, "completed");
    assert!(current.usage.total_tokens > 0);
    let events = session.events();
    for kind in [
        "session.started",
        "status",
        "turn.started",
        "user",
        "message",
        "usage",
        "turn.completed",
    ] {
        assert!(
            events.iter().any(|event| event["kind"] == kind),
            "missing event kind {kind}"
        );
    }
    assert!(
        session
            .inbox_notes(&inbox_path)
            .contains(&format!("[session {} idle]\n", session.id))
    );
    let previous_notes = session.inbox_note_names(&inbox_path);

    let reply = session.send("another turn").unwrap();
    assert_eq!(reply["disposition"], "started");
    let current = session.until("second turn completion", |state| {
        state.turn_count == 2
            && state
                .last_turn
                .as_ref()
                .is_some_and(|turn| turn.turn_id == "fake-turn-2")
    });
    assert_eq!(current.status, Status::Idle);
    session.until("second idle note", |_| {
        session
            .inbox_note_names(&inbox_path)
            .iter()
            .any(|name| !previous_notes.contains(name))
    });
    assert_eq!(session.stop(false).unwrap()["ok"], true);
    assert_eq!(session.wait_run(), 0);
    assert!(
        session
            .inbox_notes(&inbox_path)
            .contains(&format!("[session {} dead]\n", session.id))
    );
}

#[test]
fn supervisor_send_while_running_steers_and_tracks_the_command() {
    let mut session = Session::spawn("HOLD", "brief", None, Bounds::default());
    let current = session.until("held first turn", |state| {
        state.status == Status::Running && state.active_turn_id.is_some()
    });
    let reply = session.send("steer text").unwrap();
    assert_eq!(reply["disposition"], "steered");
    session.until("steer request", |_| {
        session
            .requests()
            .iter()
            .any(|request| request["method"] == "turn/steer")
    });
    let frame = session
        .requests()
        .into_iter()
        .find(|item| item["method"] == "turn/steer")
        .unwrap();
    assert_eq!(
        frame["params"]["expectedTurnId"],
        current.active_turn_id.unwrap()
    );
    let command_id = frame["params"]["commandId"].as_str().unwrap().to_string();
    session.until("steered user message", |_| {
        session
            .events()
            .iter()
            .any(|event| event["kind"] == "user" && event["commandId"] == command_id)
    });
    std::fs::write(session.fake_dir.join("go"), "").unwrap();
    session.until("steered turn completion", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    assert!(
        !session
            .events()
            .iter()
            .any(|event| event["kind"] == "steer.unconsumed")
    );
    assert_eq!(session.stop_and_join(), 0);
}

#[test]
fn supervisor_refused_steer_retries_after_idle_but_not_while_running() {
    let mut ended = Session::spawn("STEERREFUSE", "brief", None, Bounds::default());
    ended.until("initial held turn", |state| state.active_turn_id.is_some());
    let reply = ended.send("retry this text").unwrap();
    assert_eq!(reply["disposition"], "started");
    let starts: Vec<_> = ended
        .requests()
        .into_iter()
        .filter(|request| request["method"] == "turn/start")
        .collect();
    assert_eq!(
        starts.last().unwrap()["params"]["input"][0]["text"],
        "retry this text"
    );
    assert_eq!(ended.stop_and_join(), 0);

    let mut held = Session::spawn("STEERREFUSE_HOLD", "brief", None, Bounds::default());
    held.until("initial held turn", |state| state.active_turn_id.is_some());
    let started = Instant::now();
    let reply = held.send("do not queue").unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["code"], "failed");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(held.state().status, Status::Running);
    assert!(held.requests().iter().all(|request| {
        request["method"] != "turn/start" || request["params"]["input"][0]["text"] != "do not queue"
    }));
    assert_eq!(held.stop_and_join(), 0);
}

#[test]
fn supervisor_serializes_concurrent_idle_sends_into_start_then_steer() {
    let mut session = Session::spawn("HOLD", "brief", None, Bounds::default());
    session.until("initial turn", |state| state.active_turn_id.is_some());
    std::fs::write(session.fake_dir.join("go"), "").unwrap();
    session.until("idle after initial turn", |state| {
        state.status == Status::Idle
    });
    std::fs::remove_file(session.fake_dir.join("go")).unwrap();

    let (start_a_tx, start_a_rx) = mpsc::channel();
    let (start_b_tx, start_b_rx) = mpsc::channel();
    let (result_tx, result_rx) = mpsc::channel();
    let mut workers = Vec::new();
    for (text, start_rx) in [("first", start_a_rx), ("second", start_b_rx)] {
        let paths = session.paths.clone();
        let id = session.id.clone();
        let result_tx = result_tx.clone();
        workers.push(std::thread::spawn(move || {
            start_rx.recv_timeout(Duration::from_secs(2)).unwrap();
            let result = ipc::request(
                &paths,
                &id,
                &json!({"op":"send","text":text}),
                Duration::from_secs(5),
            );
            result_tx.send(result).unwrap();
        }));
    }
    start_a_tx.send(()).unwrap();
    start_b_tx.send(()).unwrap();
    let first = result_rx
        .recv_timeout(Duration::from_secs(6))
        .unwrap()
        .unwrap();
    let second = result_rx
        .recv_timeout(Duration::from_secs(6))
        .unwrap()
        .unwrap();
    for worker in workers {
        worker.join().unwrap();
    }
    let dispositions = [
        first["disposition"].as_str().unwrap(),
        second["disposition"].as_str().unwrap(),
    ];
    assert!(dispositions.contains(&"started"));
    assert!(dispositions.contains(&"steered"));
    std::fs::write(session.fake_dir.join("go"), "").unwrap();
    session.until("concurrent turn completion", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    assert_eq!(session.stop_and_join(), 0);
}

#[test]
fn supervisor_interrupt_stop_keeps_session_and_idle_interrupt_is_a_noop() {
    let mut running = Session::spawn("HOLD", "brief", None, Bounds::default());
    let active = running.until("running turn", |state| state.active_turn_id.is_some());
    let host_pid = active.host_pid.unwrap();
    let reply = running.stop(true).unwrap();
    assert_eq!(reply["interrupted"], true);
    let idle = running.until("interrupted turn", |state| {
        state.status == Status::Idle && !state.stopping
    });
    assert_eq!(idle.last_turn.as_ref().unwrap().terminal, "cancelled");
    assert!(process_exists(host_pid));
    assert_eq!(running.send("continue").unwrap()["disposition"], "started");
    assert_eq!(running.stop_and_join(), 0);

    let mut idle = Session::spawn("FAST", "brief", None, Bounds::default());
    idle.until("idle session", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    let reply = idle.stop(true).unwrap();
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["interrupted"], false);
    assert!(
        !idle
            .requests()
            .iter()
            .any(|request| request["method"] == "turn/interrupt")
    );
    assert_eq!(idle.stop_and_join(), 0);
}

#[test]
fn supervisor_plain_stop_interrupts_then_closes_and_reaps_the_host() {
    let mut running = Session::spawn("HOLD", "brief", None, Bounds::default());
    let current = running.until("running turn", |state| state.active_turn_id.is_some());
    let host_pid = current.host_pid.unwrap();
    assert_eq!(running.stop(false).unwrap()["ok"], true);
    assert_eq!(running.wait_run(), 0);
    let stopped = running.state();
    assert_eq!(stopped.status, Status::Dead);
    assert_eq!(stopped.dead.unwrap().reason, DeadReason::Stopped);
    assert!(!running.paths.socket_path(&running.id).unwrap().exists());
    assert!(!process_exists(host_pid));
    let methods: Vec<_> = running
        .requests()
        .into_iter()
        .filter_map(|request| request["method"].as_str().map(str::to_owned))
        .collect();
    assert!(methods.iter().any(|method| method == "turn/interrupt"));

    let mut idle = Session::spawn("FAST", "brief", None, Bounds::default());
    idle.until("idle session", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    assert_eq!(idle.stop(false).unwrap()["ok"], true);
    assert_eq!(idle.wait_run(), 0);
    assert!(
        !idle
            .requests()
            .iter()
            .any(|request| request["method"] == "turn/interrupt")
    );
}

#[test]
fn supervisor_escalates_when_the_host_ignores_eof_or_sigterm() {
    for scenario in ["IGNORE_EOF", "IGNORE_EOF,IGNORE_TERM"] {
        let mut session = Session::spawn(scenario, "brief", None, Bounds::default());
        session.until("idle session", |state| {
            state.status == Status::Idle && state.last_turn.is_some()
        });
        let started = Instant::now();
        assert_eq!(session.stop(false).unwrap()["ok"], true);
        assert_eq!(session.wait_run(), 0);
        assert!(started.elapsed() < Duration::from_secs(3));
        let host_pid = session.state().host_pid.unwrap();
        assert!(!process_exists(host_pid));
    }
}

#[test]
fn supervisor_busy_replies_do_not_wait_for_interrupt_completion() {
    let bounds = Bounds {
        interrupt_ms: 5_000,
        ..Bounds::default()
    };
    let mut session = Session::spawn("HOLD_INTERRUPT", "brief", None, bounds);
    session.until("running turn", |state| state.active_turn_id.is_some());
    let (stop_tx, stop_rx) = mpsc::channel();
    let paths = session.paths.clone();
    let id = session.id.clone();
    let stop_thread = std::thread::spawn(move || {
        stop_tx
            .send(ipc::request(
                &paths,
                &id,
                &json!({"op":"stop","interrupt":true}),
                Duration::from_secs(7),
            ))
            .unwrap();
    });
    session.until("interrupt accepted and stop waiting", |state| {
        state.stopping
            && session
                .requests()
                .iter()
                .any(|request| request["method"] == "turn/interrupt")
    });
    for request in [
        json!({"op":"send","text":"busy"}),
        json!({"op":"stop","interrupt":false}),
    ] {
        let started = Instant::now();
        let reply = session
            .request_timeout(&request, Duration::from_secs(1))
            .unwrap();
        assert_eq!(reply["code"], "busy");
        assert!(started.elapsed() < Duration::from_secs(1));
    }
    std::fs::write(session.fake_dir.join("go"), "").unwrap();
    assert_eq!(
        stop_rx
            .recv_timeout(Duration::from_secs(6))
            .unwrap()
            .unwrap()["interrupted"],
        true
    );
    stop_thread.join().unwrap();
    assert_eq!(session.stop_and_join(), 0);
}

fn process_exists(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

fn mode(path: &std::path::Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn supervisor_interrupt_timeout_kills_host_and_plain_stop_still_finishes() {
    let bounds = Bounds {
        interrupt_ms: 300,
        ..Bounds::default()
    };
    let mut interrupted = Session::spawn("IGNORE_INTERRUPT", "brief", None, bounds);
    interrupted.until("running turn", |state| state.active_turn_id.is_some());
    let host_pid = interrupted.state().host_pid.unwrap();
    let reply = interrupted.stop(true).unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["code"], "dead");
    let dead = interrupted.state();
    assert_eq!(dead.status, Status::Dead);
    assert_eq!(
        dead.dead.as_ref().unwrap().reason,
        DeadReason::HostUnresponsive
    );
    assert!(dead.stopping);
    assert!(!process_exists(host_pid));
    let after = interrupted.send("after dead");
    assert!(matches!(after, Ok(ref reply) if reply["code"] == "dead"));
    let after = interrupted.stop(false);
    assert!(matches!(after, Ok(ref reply) if reply["code"] == "dead"));
    assert_eq!(interrupted.wait_run(), 0);

    let mut plain = Session::spawn("IGNORE_INTERRUPT", "brief", None, bounds);
    plain.until("running turn", |state| state.active_turn_id.is_some());
    assert_eq!(plain.stop(false).unwrap()["ok"], true);
    assert_eq!(plain.wait_run(), 0);
    assert_eq!(plain.state().dead.unwrap().reason, DeadReason::Stopped);

    let mut stubborn = Session::spawn(
        "IGNORE_INTERRUPT,IGNORE_EOF,IGNORE_TERM",
        "brief",
        None,
        bounds,
    );
    stubborn.until("running turn", |state| state.active_turn_id.is_some());
    let started = Instant::now();
    assert_eq!(stubborn.stop(false).unwrap()["ok"], true);
    assert_eq!(stubborn.wait_run(), 0);
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn supervisor_kills_a_host_that_stops_reading_without_blocking_other_calls() {
    let mut session = Session::spawn("STOP_READING", "brief", None, Bounds::default());
    session.until("startup turn completed", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    let paths = session.paths.clone();
    let id = session.id.clone();
    let (send_tx, send_rx) = mpsc::channel();
    let sender = std::thread::spawn(move || {
        let result = ipc::request(
            &paths,
            &id,
            &json!({"op":"send","text":"x".repeat(2 * 1024 * 1024)}),
            Duration::from_secs(5),
        );
        send_tx.send(result).unwrap();
    });
    session.until("blocked turn start", |state| {
        state.status == Status::Running && state.turn_count == 1
    });

    let paths = session.paths.clone();
    let id = session.id.clone();
    let (second_tx, second_rx) = mpsc::channel();
    let second_thread = std::thread::spawn(move || {
        second_tx
            .send(ipc::request(
                &paths,
                &id,
                &json!({"op":"send","text":"second"}),
                Duration::from_secs(3),
            ))
            .unwrap();
    });
    let paths = session.paths.clone();
    let id = session.id.clone();
    let (stop_tx, stop_rx) = mpsc::channel();
    let stopper = std::thread::spawn(move || {
        stop_tx
            .send(ipc::request(
                &paths,
                &id,
                &json!({"op":"stop","interrupt":false}),
                Duration::from_secs(3),
            ))
            .unwrap();
    });

    let result = send_rx
        .recv_timeout(Duration::from_secs(3))
        .unwrap()
        .unwrap();
    assert_eq!(result["ok"], false);
    assert_eq!(result["code"], "failed");
    let second_reply = second_rx
        .recv_timeout(Duration::from_secs(3))
        .unwrap()
        .unwrap();
    let stop = stop_rx
        .recv_timeout(Duration::from_secs(3))
        .unwrap()
        .unwrap();
    assert!(second_reply["code"] == "dead" || second_reply["code"] == "busy");
    assert!(stop["code"] == "dead" || stop["code"] == "busy");
    sender.join().unwrap();
    second_thread.join().unwrap();
    stopper.join().unwrap();
    let dead = session.until("unresponsive host death", |state| {
        state.status == Status::Dead
    });
    assert_eq!(dead.dead.unwrap().reason, DeadReason::HostUnresponsive);
    assert_eq!(session.wait_run(), 0);
}

#[test]
fn supervisor_reports_host_exit_noise_host_requests_and_bad_models() {
    let mut died = Session::spawn("DIE", "brief", None, Bounds::default());
    let dead = died.until("host exit", |state| state.status == Status::Dead);
    assert_eq!(dead.dead.as_ref().unwrap().reason, DeadReason::HostExited);
    assert_eq!(dead.dead.as_ref().unwrap().exit_code, Some(3));
    let host_pid = dead.host_pid.unwrap();
    assert_eq!(died.wait_run(), 0);
    assert!(!process_exists(host_pid));
    assert!(!died.paths.socket_path(&died.id).unwrap().exists());

    let mut noise = Session::spawn("NOISE,APPROVAL", "brief", None, Bounds::default());
    noise.until("noisy turn completion", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    let stderr = std::fs::read_to_string(noise.paths.host_stderr(&noise.id)).unwrap();
    assert!(stderr.contains("sandbox warning"));
    assert!(stderr.contains("\"jsonrpc\""));
    let events = noise.events();
    assert!(events.iter().any(|event| event["kind"] == "host.unparsed"));
    assert!(events.iter().any(|event| event["kind"] == "host.refused"));
    assert!(
        noise
            .requests()
            .iter()
            .any(|request| request["error"]["code"] == -32601)
    );
    assert_eq!(noise.stop_and_join(), 0);

    let mut bad_model = Session::spawn("BADMODEL", "brief", None, Bounds::default());
    let failed = bad_model.until("failed model turn", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    assert_eq!(failed.last_turn.as_ref().unwrap().terminal, "failed");
    assert_eq!(
        failed
            .last_turn
            .as_ref()
            .unwrap()
            .error
            .as_ref()
            .unwrap()
            .kind,
        "modelError"
    );
    assert_eq!(
        bad_model.send("try again").unwrap()["disposition"],
        "started"
    );
    assert_eq!(bad_model.stop_and_join(), 0);
}

#[test]
fn muse_host_fake_consumes_a_turn_start_buffered_after_host_refusal() {
    let root = temp_root("ds-coalesced-host-frames");
    let fake_dir = root.join("fake");
    std::fs::create_dir_all(&fake_dir).unwrap();
    let fake = support::muse_host_fake();

    let exec_guard = support::exec_lock();
    let child = std::process::Command::new("python3")
        .arg("-S")
        .arg(&fake)
        .args([
            "serve",
            "--provider",
            "meta",
            "--model",
            "test",
            "--disable-sandbox",
        ])
        .env("FAKE_DIR", &fake_dir)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn();
    drop(exec_guard);
    let mut child = child.unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (output_tx, output_rx) = mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in std::io::BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if output_tx.send(line).is_err() {
                break;
            }
        }
    });

    let frames = concat!(
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        "\n",
        r#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":2,"method":"session/start","params":{}}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":981,"error":{"code":-32601,"message":"delegate does not handle host requests"}}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"input":[{"text":"coalesced"}],"commandId":"test-command"}}"#,
        "\n",
    );
    let bytes = frames.as_bytes();
    assert_eq!(stdin.write(bytes).unwrap(), bytes.len());
    stdin.flush().unwrap();

    let turn_started = loop {
        let Ok(line) = output_rx.recv_timeout(Duration::from_secs(3)) else {
            break false;
        };
        let Ok(frame) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if frame["id"] == 3 && frame.get("result").is_some() {
            break true;
        }
    };
    drop(stdin);
    if !turn_started {
        let _ = child.kill();
    }
    let status = child.wait().unwrap();
    reader.join().unwrap();
    assert!(
        turn_started,
        "fake host did not process buffered turn/start"
    );
    assert!(status.success());

    let requests: Vec<Value> = std::fs::read_to_string(fake_dir.join("requests.jsonl"))
        .unwrap()
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    assert!(
        requests
            .iter()
            .any(|request| { request["id"] == 981 && request["error"]["code"] == -32601 })
    );
    assert!(
        requests
            .iter()
            .any(|request| request["method"] == "turn/start" && request["id"] == 3)
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn supervisor_startup_and_runtime_failures_are_recorded() {
    let mut missing = Session::spawn_with_options(
        "FAST",
        "brief",
        None,
        Bounds::default(),
        Some("/tmp/no-such-muse-session-host".into()),
        false,
        None,
    );
    let dead = missing.until("missing host failure", |state| state.status == Status::Dead);
    assert_eq!(dead.dead.as_ref().unwrap().reason, DeadReason::StartFailed);
    assert!(!dead.dead.as_ref().unwrap().message.is_empty());
    assert_eq!(missing.wait_run(), 0);

    let mut start_failure = Session::spawn("STARTFAIL", "brief", None, Bounds::default());
    let dead = start_failure.until("session start failure", |state| {
        state.status == Status::Dead
    });
    assert_eq!(dead.dead.as_ref().unwrap().reason, DeadReason::StartFailed);
    assert!(
        dead.dead
            .as_ref()
            .unwrap()
            .message
            .contains("fake session start failed")
    );
    assert_eq!(start_failure.wait_run(), 0);

    let mut no_ack = Session::spawn("NO_INIT_ACK", "brief", None, Bounds::default());
    let dead = no_ack.until("initialization timeout", |state| {
        state.status == Status::Dead
    });
    assert_eq!(dead.dead.as_ref().unwrap().reason, DeadReason::StartFailed);
    assert_eq!(no_ack.wait_run(), 0);

    let mut too_deep =
        Session::spawn_with_options("FAST", "brief", None, Bounds::default(), None, true, None);
    let dead = too_deep.until("socket path limit", |state| state.status == Status::Dead);
    assert_eq!(dead.dead.as_ref().unwrap().reason, DeadReason::StartFailed);
    assert!(dead.dead.as_ref().unwrap().message.contains("socket path"));
    assert!(!too_deep.fake_dir.join("host.pid").exists());
    assert_eq!(too_deep.wait_run(), 0);

    let mut muted = Session::spawn("MUTE_AFTER_START", "brief", None, Bounds::default());
    muted.until("first turn completion", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    let reply = muted.send("second turn").unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["code"], "failed");
    let dead = muted.until("runtime RPC timeout", |state| state.status == Status::Dead);
    assert_eq!(
        dead.dead.as_ref().unwrap().reason,
        DeadReason::HostUnresponsive
    );
    assert_eq!(muted.wait_run(), 0);
}

#[test]
fn supervisor_rejects_bad_socket_requests_and_drops_silent_clients() {
    let mut session = Session::spawn("FAST", "brief", None, Bounds::default());
    session.until("idle session", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    let socket = session.paths.socket_path(&session.id).unwrap();
    let mut silent = UnixStream::connect(socket).unwrap();
    silent
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let started = Instant::now();
    let mut response = [0u8; 1];
    assert_eq!(silent.read(&mut response).unwrap(), 0);
    assert!(
        started.elapsed() >= Duration::from_millis(250),
        "silent-client drop took {:?}; state={:?}",
        started.elapsed(),
        session.state()
    );

    assert_eq!(
        session.request(&json!({"op":"unknown"})).unwrap()["code"],
        "usage"
    );
    assert_eq!(
        session
            .request(&json!({"op":"send","text":"  \n"}))
            .unwrap()["code"],
        "usage"
    );
    let too_long = "x".repeat(supervisor::MAX_TEXT + 1);
    assert_eq!(session.send(&too_long).unwrap()["code"], "usage");
    assert_eq!(session.state().status, Status::Idle);
    assert_eq!(
        session.send("still serving").unwrap()["disposition"],
        "started"
    );
    assert_eq!(session.stop_and_join(), 0);
}

#[test]
fn supervisor_accepts_escaped_max_text_and_rejects_a_line_over_max_line() {
    let bounds = Bounds {
        rpc_ms: 5_000,
        // The ~48 MiB write must finish inside the request deadline.
        read_ms: supervisor::REQUEST_READ,
        ..Bounds::default()
    };
    let mut session = Session::spawn("FAST", "brief", None, bounds);
    session.until("idle session", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    let exact = "\"".repeat(supervisor::MAX_TEXT);
    let reply = session.send(&exact).unwrap();
    assert_eq!(reply["disposition"], "started", "reply was {reply}");
    let turn = session.until("max text turn", |state| {
        state.turn_count == 2 && state.status == Status::Idle && state.last_turn.is_some()
    });
    assert_eq!(turn.last_turn.as_ref().unwrap().turn_id, "fake-turn-2");
    let logged = session
        .requests()
        .into_iter()
        .rfind(|request| request["method"] == "turn/start")
        .unwrap();
    assert_eq!(
        logged["params"]["input"][0]["text"].as_str().unwrap().len(),
        supervisor::MAX_TEXT
    );
    assert_eq!(logged["params"]["input"][0]["text"], exact);

    let socket = session.paths.socket_path(&session.id).unwrap();
    let mut stream = UnixStream::connect(socket).unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let chunk = vec![b'x'; 64 * 1024];
    let mut sent = 0usize;
    while sent <= supervisor::MAX_LINE {
        let count = (supervisor::MAX_LINE + 1 - sent).min(chunk.len());
        if stream.write_all(&chunk[..count]).is_err() {
            break;
        }
        sent += count;
    }
    let mut reply = Vec::new();
    let read = stream.read_to_end(&mut reply);
    // The raw bytes print before the newline strip, so a lone `\n` reply stays visible.
    let reply: Value = serde_json::from_slice(reply.strip_suffix(b"\n").unwrap_or(&reply))
        .unwrap_or_else(|error| {
            panic!(
                "reply to oversized line did not parse: read={read:?} bytes={reply:?} error={error}"
            )
        });
    assert_eq!(reply["code"], "usage");
    assert_eq!(session.stop_and_join(), 0);
}

#[test]
fn supervisor_notifies_only_after_completed_turn_and_keeps_inbox_failures_nonfatal() {
    let inbox_path = temp_root("ds-idle-early");
    let mut early = Session::spawn("IDLE_EARLY", "brief", Some(&inbox_path), Bounds::default());
    early.until("early idle status", |state| {
        state.status == Status::Running
            && early
                .events()
                .iter()
                .any(|event| event["kind"] == "status" && event["status"] == "idle")
    });
    assert!(early.inbox_notes(&inbox_path).is_empty());
    std::fs::write(early.fake_dir.join("go"), "").unwrap();
    early.until("completed turn and idle note", |state| {
        state.status == Status::Idle
            && early
                .inbox_notes(&inbox_path)
                .contains(&format!("[session {} idle]\n", early.id))
    });
    assert_eq!(early.stop_and_join(), 0);

    let dead_inbox = temp_root("ds-dead-inbox");
    let mut died = Session::spawn("DIE", "brief", Some(&dead_inbox), Bounds::default());
    died.until("dead host with note", |state| {
        state.status == Status::Dead
            && died
                .inbox_notes(&dead_inbox)
                .contains(&format!("[session {} dead]\n", died.id))
    });
    assert!(
        died.inbox_notes(&dead_inbox)
            .contains(&format!("[session {} dead]\n", died.id))
    );
    assert_eq!(died.wait_run(), 0);

    let bad_inbox_root = temp_root("ds-bad-inbox");
    std::fs::create_dir_all(&bad_inbox_root).unwrap();
    let bad_inbox = bad_inbox_root.join("file");
    std::fs::write(&bad_inbox, "not a directory").unwrap();
    let mut unaffected = Session::spawn("FAST", "brief", Some(&bad_inbox), Bounds::default());
    let idle = unaffected.until("idle despite inbox failure", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    // The supervisor writes inbox.failed after it publishes idle, so wait for the
    // event itself rather than reading the events once after idle (#664).
    unaffected.until("inbox.failed event", |_| {
        unaffected
            .events()
            .iter()
            .any(|event| event["kind"] == "inbox.failed")
    });
    let serialized = serde_json::to_value(idle).unwrap();
    assert!(serialized.get("inboxFailed").is_none());
    assert_eq!(
        unaffected.send("still running").unwrap()["disposition"],
        "started"
    );
    assert_eq!(unaffected.stop_and_join(), 0);
}

#[test]
fn supervisor_ack_completion_race_and_queued_ack_leave_idle_state_correct() {
    let mut race = Session::spawn("FAST", "brief", None, Bounds::default());
    race.until("initial idle", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    assert_eq!(race.send("RACE").unwrap()["disposition"], "started");
    let current = race.until("racing completion", |state| {
        state.status == Status::Idle && state.turn_count == 2
    });
    assert_eq!(current.active_turn_id, None);
    assert_eq!(current.last_turn.as_ref().unwrap().turn_id, "fake-turn-2");
    assert_eq!(race.stop_and_join(), 0);

    let mut queued = Session::spawn("FAST", "brief", None, Bounds::default());
    queued.until("initial idle", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    assert_eq!(queued.send("QUEUED_ACK").unwrap()["disposition"], "started");
    let current = queued.until("queued host turn completion", |state| {
        state.status == Status::Idle && state.turn_count == 2 && state.last_turn.is_some()
    });
    assert_eq!(current.active_turn_id, None);
    assert!(
        queued
            .events()
            .iter()
            .any(|event| event["kind"] == "ack.unexpected")
    );
    assert_eq!(queued.stop_and_join(), 0);
}

#[test]
fn supervisor_persists_running_before_a_test_released_start_ack() {
    let bounds = Bounds {
        rpc_ms: 1_000,
        ..Bounds::default()
    };
    let mut session = Session::spawn("SLOW_ACK", "brief", None, bounds);
    session.until("first idle turn", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    let paths = session.paths.clone();
    let id = session.id.clone();
    let (reply_tx, reply_rx) = mpsc::channel();
    let sender = std::thread::spawn(move || {
        reply_tx
            .send(ipc::request(
                &paths,
                &id,
                &json!({"op":"send","text":"slow"}),
                Duration::from_secs(3),
            ))
            .unwrap();
    });
    session.until("start acknowledgement held by fake", |_| {
        session.fake_dir.join("ack.pending").exists()
    });
    let pending = session.state();
    assert_eq!(pending.status, Status::Running);
    assert!(pending.active_turn_id.is_none());
    assert!(matches!(
        reply_rx.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    std::fs::write(session.fake_dir.join("ack.release"), "release").unwrap();
    assert_eq!(
        reply_rx
            .recv_timeout(Duration::from_secs(3))
            .unwrap()
            .unwrap()["disposition"],
        "started"
    );
    sender.join().unwrap();
    assert_eq!(session.stop_and_join(), 0);
}

#[test]
fn supervisor_rejects_oversized_briefs_and_sends_an_exact_maximum_brief() {
    let oversized = "x".repeat(supervisor::MAX_TEXT + 1);
    let mut too_large = Session::spawn("FAST", &oversized, None, Bounds::default());
    let dead = too_large.until("oversized brief rejection", |state| {
        state.status == Status::Dead
    });
    assert_eq!(dead.dead.as_ref().unwrap().reason, DeadReason::StartFailed);
    assert!(
        dead.dead
            .as_ref()
            .unwrap()
            .message
            .contains("brief exceeds MAX_TEXT")
    );
    assert!(!too_large.fake_dir.join("host.pid").exists());
    assert_eq!(too_large.wait_run(), 0);

    let exact = "x".repeat(supervisor::MAX_TEXT);
    let mut accepted = Session::spawn("HOLD", &exact, None, Bounds::default());
    accepted.until("maximum brief turn", |state| {
        state.turn_count == 1 && state.active_turn_id.is_some()
    });
    let request = accepted
        .requests()
        .into_iter()
        .find(|frame| frame["method"] == "turn/start")
        .unwrap();
    assert_eq!(request["params"]["input"][0]["text"], exact);
    assert_eq!(accepted.stop_and_join(), 0);
}

#[test]
fn supervisor_logs_unparsed_multibyte_lines_by_character_count() {
    let mut session = Session::spawn("MULTIBYTE", "brief", None, Bounds::default());
    session.until("multibyte line logged", |state| {
        state.status == Status::Idle
            && session
                .events()
                .iter()
                .any(|event| event["kind"] == "host.unparsed")
    });
    let line = session
        .events()
        .into_iter()
        .find(|event| event["kind"] == "host.unparsed")
        .unwrap();
    assert_eq!(line["line"].as_str().unwrap().chars().count(), 200);
    assert!(
        line["line"]
            .as_str()
            .unwrap()
            .chars()
            .all(|character| character == 'é')
    );
    assert_eq!(session.stop_and_join(), 0);
}

#[test]
fn supervisor_panic_guards_reap_host_and_remove_socket() {
    for mode in ["reader", "apply", "run"] {
        let scenario = if mode == "run" { "FAST" } else { "PANIC_LINE" };
        let mut session = Session::spawn_with_options(
            scenario,
            "brief",
            None,
            Bounds::default(),
            None,
            false,
            Some(mode),
        );
        let dead = session.until("panic cleanup", |state| state.status == Status::Dead);
        assert_eq!(
            dead.dead.as_ref().unwrap().reason,
            DeadReason::HostUnresponsive
        );
        assert_eq!(
            dead.dead.as_ref().unwrap().message,
            "supervisor thread panicked"
        );
        let host_pid = dead.host_pid.unwrap();
        if mode == "apply" {
            let response = session.send("after panic");
            assert!(matches!(response, Ok(ref value) if value["code"] == "dead"));
        }
        assert_eq!(session.wait_run(), 1);
        assert!(!session.paths.socket_path(&session.id).unwrap().exists());
        assert!(!process_exists(host_pid));
        unsafe { std::env::remove_var("DELEGATE_SESSION_TEST_PANIC") };
    }
}

#[test]
fn supervisor_host_inherits_no_unrelated_descriptors() {
    let mut session = Session::spawn("FAST", "brief", None, Bounds::default());
    session.until("fake descriptor report", |state| {
        state.status == Status::Idle && session.fake_dir.join("fds.txt").exists()
    });
    assert_eq!(
        std::fs::read_to_string(session.fake_dir.join("fds.txt")).unwrap(),
        ""
    );
    assert_eq!(session.stop_and_join(), 0);
}

#[test]
fn supervisor_state_write_failure_kills_host_and_removes_socket() {
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    let mut session = Session::spawn("FAST", "brief", None, Bounds::default());
    let current = session.until("idle before state write failure", |state| {
        state.status == Status::Idle && state.last_turn.is_some()
    });
    let host_pid = current.host_pid.unwrap();
    std::fs::set_permissions(
        session.paths.dir(&session.id),
        std::fs::Permissions::from_mode(0o500),
    )
    .unwrap();
    let _ = session.send("state write must fail");
    assert_eq!(session.wait_run(), 1);
    assert!(!session.paths.socket_path(&session.id).unwrap().exists());
    assert!(!process_exists(host_pid));
    std::fs::set_permissions(
        session.paths.dir(&session.id),
        std::fs::Permissions::from_mode(0o700),
    )
    .unwrap();
}

// A supervisor killed after it spawns the host but before it publishes
// either pid leaves no hostPid on record; these tests prove every reaper
// path still accounts for that host. They drive the real `delegate` binary
// as a subprocess because killing "the supervisor" must not kill the test
// runner, and the fake host ignores stdin EOF so only a reap removes it.
const PREPUBLISH_BIN: &str = env!("CARGO_BIN_EXE_delegate");
const PREPUBLISH_MODEL: &str = "muse/muse-spark-1.3-contributor";
const PREPUBLISH_HOOK_ENV: &str = "DELEGATE_SESSION_TEST_PAUSE_PREPUBLISH";

struct PrepublishRoot {
    base: std::path::PathBuf,
    home: std::path::PathBuf,
    fake_dir: std::path::PathBuf,
    inbox: std::path::PathBuf,
    brief: std::path::PathBuf,
    ready: std::path::PathBuf,
}

struct PrepublishRun {
    child: std::process::Child,
    stdout: mpsc::Receiver<Vec<u8>>,
    stderr: mpsc::Receiver<Vec<u8>>,
}

impl PrepublishRoot {
    fn new() -> Self {
        let base = std::path::PathBuf::from("/tmp").join(format!(
            "dsp-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let home = base.join("home");
        let fake_dir = base.join("fake-data");
        let inbox = base.join("inbox");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&fake_dir).unwrap();
        std::fs::create_dir_all(&inbox).unwrap();
        let brief = base.join("brief.md");
        std::fs::write(&brief, b"prepublish brief").unwrap();
        let ready = base.join("ready");
        Self {
            base,
            home,
            fake_dir,
            inbox,
            brief,
            ready,
        }
    }

    fn fresh_id(&self) -> String {
        format!(
            "00000000-0000-7001-8000-{:012x}",
            NEXT.fetch_add(1, Ordering::Relaxed)
        )
    }

    fn paths(&self) -> Paths {
        Paths::new(self.home.join(".cache/agents/sessions"))
    }

    fn create_session(&self, id: &str) -> u64 {
        let paths = self.paths();
        state::create_session_dir(&paths, id).unwrap();
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let value = state::new_state(
            id,
            PREPUBLISH_MODEL,
            &self.base.to_string_lossy(),
            &self.inbox.to_string_lossy(),
            now_ms,
        );
        state::write_state(&paths, &value).unwrap();
        let brief_path = paths.brief_file(id);
        let mut brief_file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&brief_path)
            .unwrap();
        brief_file.write_all(b"prepublish brief").unwrap();
        std::fs::set_permissions(&brief_path, std::fs::Permissions::from_mode(0o600)).unwrap();
        now_ms
    }

    fn spawn(
        &self,
        args: &[&str],
        scenario: &str,
        extra_env: &[(&str, &str)],
        hook: bool,
    ) -> PrepublishRun {
        let mut command = std::process::Command::new(PREPUBLISH_BIN);
        command
            .args(args)
            .current_dir(&self.base)
            .env("HOME", &self.home)
            .env("MUSE_BIN", support::muse_host_fake())
            .env("FAKE_DIR", &self.fake_dir)
            .env("FAKE_SCENARIO", scenario)
            .env("DELEGATE_SESSION_GRACE_MS", "300")
            .env_remove("TERM")
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .stdin(std::process::Stdio::null());
        if hook {
            command.env(PREPUBLISH_HOOK_ENV, &self.ready);
        }
        for (key, value) in extra_env {
            command.env(key, value);
        }
        let exec_guard = support::exec_lock();
        let mut child = command.spawn().unwrap();
        drop(exec_guard);
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
        PrepublishRun {
            child,
            stdout: stdout_rx,
            stderr: stderr_rx,
        }
    }

    fn spawn_start(&self, scenario: &str, wait_ms: &str) -> PrepublishRun {
        let brief = self.brief.to_str().unwrap().to_string();
        let inbox = self.inbox.to_str().unwrap().to_string();
        self.spawn(
            &[
                "session",
                "start",
                "--model",
                PREPUBLISH_MODEL,
                "--brief",
                &brief,
                "--inbox",
                &inbox,
            ],
            scenario,
            &[("DELEGATE_SESSION_START_WAIT_MS", wait_ms)],
            true,
        )
    }

    // The ready file counts only once the hook has written both pids and its
    // trailing newline, so a partial write never parses.
    fn wait_ready(&self) -> (i32, i32) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(bytes) = std::fs::read(&self.ready)
                && let Some(pids) = parse_ready(&bytes)
            {
                return pids;
            }
            assert!(
                Instant::now() < deadline,
                "prepublish ready file did not arrive: {:?}",
                self.ready
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn ready_pids(&self) -> Option<(i32, i32)> {
        parse_ready(&std::fs::read(&self.ready).ok()?)
    }

    fn assert_gone(pid: i32) {
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

fn parse_ready(bytes: &[u8]) -> Option<(i32, i32)> {
    if !bytes.ends_with(b"\n") {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let mut parts = text.split_whitespace();
    let first = parts.next()?.parse::<i32>().ok()?;
    let second = parts.next()?.parse::<i32>().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((first, second))
}

impl PrepublishRun {
    fn kill(&mut self) {
        self.child.kill().expect("kill the parked supervisor");
    }

    fn wait_bounded(mut self, timeout: Duration, what: &str) -> std::process::Output {
        let deadline = Instant::now() + timeout;
        let status = loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= deadline {
                let _ = self.child.kill();
                panic!("prepublish subprocess exceeded {timeout:?} waiting for {what}");
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let stdout = self
            .stdout
            .recv_timeout(Duration::from_secs(10))
            .expect("stdout EOF deadline");
        let stderr = self
            .stderr
            .recv_timeout(Duration::from_secs(10))
            .expect("stderr EOF deadline");
        std::process::Output {
            status,
            stdout,
            stderr,
        }
    }
}

impl Drop for PrepublishRoot {
    fn drop(&mut self) {
        if let Some((supervisor_pid, host_pid)) = self.ready_pids() {
            unsafe {
                libc::kill(supervisor_pid, libc::SIGKILL);
                libc::kill(-host_pid, libc::SIGKILL);
                libc::kill(host_pid, libc::SIGKILL);
            }
        }
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

#[test]
fn prepublish_kill_is_reaped_by_settle_dead_supervisor() {
    let root = PrepublishRoot::new();
    let id = root.fresh_id();
    let started_at = root.create_session(&id);
    let mut run = root.spawn(&["session", "__supervise", &id], "IGNORE_EOF", &[], true);
    let (_, host_pid) = root.wait_ready();
    assert_eq!(
        unsafe { libc::kill(host_pid, 0) },
        0,
        "host exited before the supervisor kill"
    );
    run.kill();
    let _ = run.wait_bounded(Duration::from_secs(10), "supervise exit after SIGKILL");
    let settled = state::settle_dead_supervisor(
        &root.paths(),
        &id,
        started_at + state::STARTING_GRACE_MS + 1,
    )
    .unwrap()
    .expect("a pre-publication kill must settle the session dead");
    assert_eq!(
        settled.dead.as_ref().unwrap().reason,
        DeadReason::StartFailed
    );
    assert_eq!(settled.supervisor_pid, None);
    assert_eq!(settled.host_pid, None);
    PrepublishRoot::assert_gone(host_pid);
}

#[test]
fn prepublish_start_timeout_reaps_the_host() {
    let root = PrepublishRoot::new();
    let run = root.spawn_start("IGNORE_EOF", "5000");
    let output = run.wait_bounded(Duration::from_secs(15), "session start timeout");
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("session startup timed out"),
        "unexpected start stderr: {stderr}"
    );
    let (_, host_pid) = root
        .ready_pids()
        .expect("ready file holds the pre-publication pids");
    PrepublishRoot::assert_gone(host_pid);
}

#[test]
fn prepublish_supervisor_exit_before_first_turn_reaps_the_host() {
    let root = PrepublishRoot::new();
    let run = root.spawn_start("IGNORE_EOF", "30000");
    let (supervisor_pid, host_pid) = root.wait_ready();
    unsafe {
        libc::kill(supervisor_pid, libc::SIGKILL);
    }
    let output = run.wait_bounded(
        Duration::from_secs(10),
        "session start exit after supervisor SIGKILL",
    );
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("session supervisor exited before first turn"),
        "unexpected start stderr: {stderr}"
    );
    PrepublishRoot::assert_gone(host_pid);
}

#[test]
fn prepublish_spawn_record_failure_stops_the_start_before_any_host_runs() {
    let root = PrepublishRoot::new();
    let id = root.fresh_id();
    let _ = root.create_session(&id);
    // A directory where the spawn record must go makes the pre-exec open fail.
    std::fs::create_dir_all(root.paths().host_spawn_file(&id)).unwrap();
    let run = root.spawn(&["session", "__supervise", &id], "IGNORE_EOF", &[], false);
    let output = run.wait_bounded(
        Duration::from_secs(10),
        "supervise exit after record failure",
    );
    assert_eq!(output.status.code(), Some(0));
    let state = state::read_state(&root.paths(), &id).unwrap();
    assert_eq!(state.status, Status::Dead);
    assert_eq!(state.dead.as_ref().unwrap().reason, DeadReason::StartFailed);
    assert!(!root.fake_dir.join("host.pid").exists());
    assert!(!root.paths().socket_path(&id).unwrap().exists());
}
