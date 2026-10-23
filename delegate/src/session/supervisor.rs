use crate::session::inbox::{self, Note};
use crate::session::msp::{self, Disposition, HostEvent, Incoming, RpcError};
use crate::session::state::{self, DeadReason, Paths, State, Status, Store};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ExitStatus, Stdio};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const RPC_TIMEOUT: u64 = 10_000;
pub const STEER_SETTLE: u64 = 2_000;
pub const INTERRUPT_WAIT: u64 = 10_000;
pub const STOP_GRACE: u64 = 10_000;
pub const TERM_WAIT: u64 = 2_000;
pub const REQUEST_READ: u64 = 5_000;
pub const MAX_TEXT: usize = 8 * 1024 * 1024;
pub const MAX_LINE: usize = 6 * MAX_TEXT + 1024;
const ACCEPT_POLL: Duration = Duration::from_millis(25);
const KILL_REAP_WAIT: Duration = Duration::from_secs(2);

#[derive(Clone)]
pub struct SupervisorConfig {
    pub paths: Paths,
    pub muse_bin: String,
    pub rpc_timeout: Duration,
    pub steer_settle: Duration,
    pub interrupt_wait: Duration,
    pub stop_grace: Duration,
    pub term_wait: Duration,
    pub request_read: Duration,
}

impl SupervisorConfig {
    pub fn from_env(paths: Paths) -> Self {
        let grace_ms = std::env::var("DELEGATE_SESSION_GRACE_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok());
        let term_wait = grace_ms
            .map(|value| Duration::from_millis(TERM_WAIT.min(value)))
            .unwrap_or_else(|| Duration::from_millis(TERM_WAIT));
        Self {
            paths,
            muse_bin: msp::resolve_muse_bin(),
            rpc_timeout: Duration::from_millis(RPC_TIMEOUT),
            steer_settle: Duration::from_millis(STEER_SETTLE),
            interrupt_wait: Duration::from_millis(INTERRUPT_WAIT),
            stop_grace: grace_ms
                .map(Duration::from_millis)
                .unwrap_or_else(|| Duration::from_millis(STOP_GRACE)),
            term_wait,
            request_read: Duration::from_millis(REQUEST_READ),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PanicMode {
    Reader,
    Apply,
    Run,
}

impl PanicMode {
    fn for_session(id: &str) -> Option<Self> {
        let value = std::env::var("DELEGATE_SESSION_TEST_PANIC").ok()?;
        let (session_id, mode) = value.split_once(':')?;
        if session_id != id {
            return None;
        }
        match mode {
            "reader" => Some(Self::Reader),
            "apply" => Some(Self::Apply),
            "run" => Some(Self::Run),
            _ => None,
        }
    }
}

struct Pending {
    method: String,
    response: Sender<Result<Value, RpcError>>,
}

enum WriterMessage {
    Write {
        line: String,
        finished: Option<Sender<Result<(), String>>>,
    },
    Close(Sender<()>),
}

struct HostControl {
    pid: i32,
    child: Mutex<Child>,
}

impl HostControl {
    fn try_wait(&self) -> std::io::Result<Option<ExitStatus>> {
        lock(&self.child).try_wait()
    }

    fn signal_group(&self, signal: i32) {
        unsafe {
            libc::kill(-self.pid, signal);
        }
    }

    fn wait_for_exit(&self, timeout: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now().checked_add(timeout)?;
        loop {
            if let Ok(Some(status)) = self.try_wait() {
                return Some(status);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}

struct Shared {
    store: Arc<Store>,
    paths: Paths,
    id: String,
    config: SupervisorConfig,
    host: Arc<HostControl>,
    writer: Sender<WriterMessage>,
    pending: Mutex<HashMap<i64, Pending>>,
    admission: Mutex<()>,
    next_request_id: AtomicI64,
    first_turn_acked: AtomicBool,
    host_eof: AtomicBool,
    shutdown: AtomicBool,
    thread_panicked: AtomicBool,
    fatal_write: Arc<AtomicBool>,
    panic_mode: Option<PanicMode>,
}

struct RunGuard {
    shared: Arc<Shared>,
    socket: PathBuf,
    active: bool,
}

impl RunGuard {
    fn disarm(&mut self) {
        self.active = false;
    }
}

impl Drop for RunGuard {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        self.shared.host.signal_group(libc::SIGKILL);
        let _ = self.shared.host.wait_for_exit(KILL_REAP_WAIT);
        remove_socket(&self.shared.paths, &self.shared.id, &self.socket);
        if !self.shared.fatal_write.load(Ordering::SeqCst) {
            let _ = catch_unwind_silent(|| {
                mark_dead(
                    &self.shared.store,
                    &self.shared.paths,
                    &self.shared.id,
                    DeadReason::HostUnresponsive,
                    None,
                    "supervisor thread panicked",
                    false,
                    &self.shared.fatal_write,
                );
            });
        }
    }
}

pub fn run(config: SupervisorConfig, id: &str) -> i32 {
    dead_event_ids()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .remove(id);
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_inner(config, id))).unwrap_or(1)
}

fn run_inner(config: SupervisorConfig, id: &str) -> i32 {
    let initial = match state::read_state(&config.paths, id) {
        Ok(state) => state,
        Err(_) => return 1,
    };
    let store = match Store::open(config.paths.clone(), initial.clone()) {
        Ok(store) => Arc::new(store),
        Err(_) => return 1,
    };
    if initial.status == Status::Dead {
        if let Ok(socket) = config.paths.socket_path(id) {
            let _ = fs::remove_file(socket);
        }
        return 0;
    }
    let panic_mode = PanicMode::for_session(id);
    let brief = match fs::read(config.paths.brief_file(id)) {
        Ok(brief) => brief,
        Err(error) => {
            return finish_pre_spawn_failure(
                &store,
                &config.paths,
                id,
                DeadReason::StartFailed,
                &error.to_string(),
            );
        }
    };
    if brief.len() > MAX_TEXT {
        return finish_pre_spawn_failure(
            &store,
            &config.paths,
            id,
            DeadReason::StartFailed,
            "brief exceeds MAX_TEXT",
        );
    }
    let brief = match String::from_utf8(brief) {
        Ok(brief) => brief,
        Err(error) => {
            return finish_pre_spawn_failure(
                &store,
                &config.paths,
                id,
                DeadReason::StartFailed,
                &error.to_string(),
            );
        }
    };
    let socket = match config.paths.socket_path(id) {
        Ok(socket) => socket,
        Err(error) => {
            return finish_pre_spawn_failure(
                &store,
                &config.paths,
                id,
                DeadReason::StartFailed,
                &error.to_string(),
            );
        }
    };
    let _ = fs::remove_file(&socket);
    let listener = match UnixListener::bind(&socket) {
        Ok(listener) => listener,
        Err(error) => {
            return finish_pre_spawn_failure(
                &store,
                &config.paths,
                id,
                DeadReason::StartFailed,
                &error.to_string(),
            );
        }
    };
    if let Err(error) = fs::set_permissions(&socket, fs::Permissions::from_mode(0o600)) {
        let _ = fs::remove_file(&socket);
        return finish_pre_spawn_failure(
            &store,
            &config.paths,
            id,
            DeadReason::StartFailed,
            &error.to_string(),
        );
    }
    if let Err(error) = listener.set_nonblocking(true) {
        let _ = fs::remove_file(&socket);
        return finish_pre_spawn_failure(
            &store,
            &config.paths,
            id,
            DeadReason::StartFailed,
            &error.to_string(),
        );
    }
    let stderr = match open_host_stderr(&config.paths.host_stderr(id)) {
        Ok(file) => file,
        Err(error) => {
            let _ = fs::remove_file(&socket);
            return finish_pre_spawn_failure(
                &store,
                &config.paths,
                id,
                DeadReason::StartFailed,
                &error.to_string(),
            );
        }
    };

    let model_id = initial
        .model
        .strip_prefix("muse/")
        .unwrap_or(&initial.model);
    let mut command = match crate::util::captured_command(&config.muse_bin) {
        Ok(command) => command,
        Err(error) => {
            let _ = fs::remove_file(&socket);
            return finish_pre_spawn_failure(
                &store,
                &config.paths,
                id,
                DeadReason::StartFailed,
                &error.to_string(),
            );
        }
    };
    command
        .args(msp::host_argv(model_id))
        .current_dir(&initial.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(stderr));
    command.process_group(0);
    isolate_child_descriptors(&mut command);
    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            let _ = fs::remove_file(&socket);
            return finish_pre_spawn_failure(
                &store,
                &config.paths,
                id,
                DeadReason::StartFailed,
                &error.to_string(),
            );
        }
    };

    let host_pid = child.id() as i32;
    let host = Arc::new(HostControl {
        pid: host_pid,
        child: Mutex::new(child),
    });
    let fatal_write = Arc::new(AtomicBool::new(false));
    let (writer_tx, writer_rx) = mpsc::channel();
    let shared = Arc::new(Shared {
        store: store.clone(),
        paths: config.paths.clone(),
        id: id.to_string(),
        config: config.clone(),
        host: host.clone(),
        writer: writer_tx,
        pending: Mutex::new(HashMap::new()),
        admission: Mutex::new(()),
        next_request_id: AtomicI64::new(1),
        first_turn_acked: AtomicBool::new(false),
        host_eof: AtomicBool::new(false),
        shutdown: AtomicBool::new(false),
        thread_panicked: AtomicBool::new(false),
        fatal_write: fatal_write.clone(),
        panic_mode,
    });
    let mut guard = RunGuard {
        shared: shared.clone(),
        socket: socket.clone(),
        active: true,
    };

    if update_store(&shared, |state| {
        state.supervisor_pid = Some(std::process::id() as i32);
        state.host_pid = Some(host_pid);
        Vec::new()
    })
    .is_err()
    {
        return cleanup_after_host(shared, &socket, None, None, None, &mut guard, 1);
    }
    if panic_mode == Some(PanicMode::Run) {
        panic!("test panic in supervisor run thread");
    }

    let stdin = child_stdin(&host);
    let stdout = child_stdout(&host);
    let (Some(stdin), Some(stdout)) = (stdin, stdout) else {
        mark_dead(
            &store,
            &config.paths,
            id,
            DeadReason::StartFailed,
            None,
            "muse host did not provide stdin and stdout pipes",
            false,
            &fatal_write,
        );
        return cleanup_after_host(shared, &socket, None, None, None, &mut guard, 0);
    };

    let writer_shared = shared.clone();
    let writer_thread = thread::spawn(move || {
        guard_thread(writer_shared, || writer_loop(writer_rx, stdin));
    });
    let reader_shared = shared.clone();
    let reader_thread = thread::spawn(move || {
        guard_thread(reader_shared.clone(), || reader_loop(stdout, reader_shared));
    });

    let startup = start_host(&shared, &initial, &brief);
    if let Err(error) = startup {
        if !fatal_write.load(Ordering::SeqCst) && shared.store.snapshot().status != Status::Dead {
            let (reason, message) = match error {
                CallFailure::Rpc(error) => (DeadReason::StartFailed, error.message),
                CallFailure::Failed(message) => (DeadReason::StartFailed, message),
            };
            mark_dead(
                &store,
                &config.paths,
                id,
                reason,
                None,
                &message,
                false,
                &fatal_write,
            );
        }
        return cleanup_after_host(
            shared,
            &socket,
            Some(writer_thread),
            Some(reader_thread),
            None,
            &mut guard,
            if fatal_write.load(Ordering::SeqCst) {
                1
            } else {
                0
            },
        );
    }

    let accept_shared = shared.clone();
    let accept_thread = thread::spawn(move || {
        guard_thread(accept_shared.clone(), || {
            accept_loop(listener, accept_shared)
        });
    });

    let code = loop {
        if fatal_write.load(Ordering::SeqCst) {
            break 1;
        }
        if shared.thread_panicked.load(Ordering::SeqCst) {
            mark_dead(
                &store,
                &config.paths,
                id,
                DeadReason::HostUnresponsive,
                None,
                "supervisor thread panicked",
                false,
                &fatal_write,
            );
            thread::sleep(dead_reply_grace(&shared));
            break 1;
        }
        let current = store.snapshot();
        if current.status == Status::Dead {
            thread::sleep(dead_reply_grace(&shared));
            break 0;
        }
        match host.try_wait() {
            Ok(Some(status)) if !current.stopping => {
                mark_dead(
                    &store,
                    &config.paths,
                    id,
                    DeadReason::HostExited,
                    status.code(),
                    "muse host exited",
                    false,
                    &fatal_write,
                );
                thread::sleep(dead_reply_grace(&shared));
                break 0;
            }
            Err(error) if !current.stopping => {
                mark_dead(
                    &store,
                    &config.paths,
                    id,
                    DeadReason::HostExited,
                    None,
                    &error.to_string(),
                    false,
                    &fatal_write,
                );
                thread::sleep(dead_reply_grace(&shared));
                break 0;
            }
            _ => {}
        }
        if shared.host_eof.load(Ordering::SeqCst) && !current.stopping {
            host.signal_group(libc::SIGKILL);
            let status = host.wait_for_exit(KILL_REAP_WAIT);
            mark_dead(
                &store,
                &config.paths,
                id,
                DeadReason::HostExited,
                status.and_then(|status| status.code()),
                "muse host closed stdout",
                false,
                &fatal_write,
            );
            thread::sleep(dead_reply_grace(&shared));
            break 0;
        }
        let _ = store.wait_until(|state| state.status == Status::Dead, ACCEPT_POLL);
    };

    shared.shutdown.store(true, Ordering::SeqCst);
    cleanup_after_host(
        shared,
        &socket,
        Some(writer_thread),
        Some(reader_thread),
        Some(accept_thread),
        &mut guard,
        code,
    )
}

fn child_stdin(host: &HostControl) -> Option<ChildStdin> {
    lock(&host.child).stdin.take()
}

fn child_stdout(host: &HostControl) -> Option<std::process::ChildStdout> {
    lock(&host.child).stdout.take()
}

fn start_host(shared: &Arc<Shared>, initial: &State, brief: &str) -> Result<(), CallFailure> {
    let initialize = json!({
        "clientInfo": {
            "name":"delegate",
            "version":env!("CARGO_PKG_VERSION"),
            "title":"delegate session"
        }
    });
    call(shared, "initialize", initialize)?;
    write_notification(
        shared,
        msp::notification("initialized"),
        shared.config.rpc_timeout,
    )?;
    let model_id = initial
        .model
        .strip_prefix("muse/")
        .unwrap_or(&initial.model);
    call(
        shared,
        "session/start",
        msp::session_start_params(&initial.cwd, model_id, now_ms()),
    )?;

    let mut admitted = false;
    update_store(shared, |state| {
        admitted = state::begin_turn(state, now_ms());
        Vec::new()
    })
    .map_err(CallFailure::Failed)?;
    if !admitted {
        return Err(CallFailure::Failed(
            "session could not start its first turn".into(),
        ));
    }
    let session_id = shared.store.snapshot().muse_session_id.unwrap_or_default();
    call(
        shared,
        "turn/start",
        msp::turn_start_params(&session_id, brief, now_ms()),
    )?;
    Ok(())
}

#[derive(Debug)]
enum CallFailure {
    Rpc(RpcError),
    Failed(String),
}

impl CallFailure {
    fn message(&self) -> String {
        match self {
            Self::Rpc(error) => format!("{} ({})", error.message, error.code),
            Self::Failed(message) => message.clone(),
        }
    }
}

fn call(shared: &Arc<Shared>, method: &str, params: Value) -> Result<Value, CallFailure> {
    let id = shared.next_request_id.fetch_add(1, Ordering::SeqCst);
    let line = msp::request(id, method, params);
    let deadline = Instant::now()
        .checked_add(shared.config.rpc_timeout)
        .ok_or_else(|| CallFailure::Failed("RPC deadline overflow".into()))?;
    let (response_tx, response_rx) = mpsc::channel();
    lock(&shared.pending).insert(
        id,
        Pending {
            method: method.to_string(),
            response: response_tx,
        },
    );
    let (written_tx, written_rx) = mpsc::channel();
    if shared
        .writer
        .send(WriterMessage::Write {
            line,
            finished: Some(written_tx),
        })
        .is_err()
    {
        lock(&shared.pending).remove(&id);
        return Err(CallFailure::Failed("muse host writer stopped".into()));
    }
    match written_rx.recv_timeout(remaining(deadline)) {
        Ok(Ok(())) => {}
        Ok(Err(message)) => {
            lock(&shared.pending).remove(&id);
            timeout_host(shared, method, &message);
            return Err(CallFailure::Failed(message));
        }
        Err(RecvTimeoutError::Timeout) => {
            if let Ok(Ok(())) = written_rx.try_recv() {
                // The write finished as its deadline expired; still wait only for the remaining ack budget.
            } else {
                lock(&shared.pending).remove(&id);
                timeout_host(shared, method, "muse host stopped reading");
                return Err(CallFailure::Failed("muse host stopped reading".into()));
            }
        }
        Err(RecvTimeoutError::Disconnected) => {
            lock(&shared.pending).remove(&id);
            timeout_host(shared, method, "muse host writer stopped");
            return Err(CallFailure::Failed("muse host writer stopped".into()));
        }
    }
    let result = match response_rx.recv_timeout(remaining(deadline)) {
        Ok(result) => result,
        Err(RecvTimeoutError::Timeout) => match response_rx.try_recv() {
            Ok(result) => result,
            Err(_) => {
                lock(&shared.pending).remove(&id);
                timeout_host(shared, method, "muse host request timed out");
                return Err(CallFailure::Failed("muse host request timed out".into()));
            }
        },
        Err(RecvTimeoutError::Disconnected) => {
            lock(&shared.pending).remove(&id);
            timeout_host(shared, method, "muse host response channel closed");
            return Err(CallFailure::Failed(
                "muse host response channel closed".into(),
            ));
        }
    };
    result.map_err(CallFailure::Rpc)
}

fn write_notification(
    shared: &Arc<Shared>,
    line: String,
    timeout: Duration,
) -> Result<(), CallFailure> {
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| CallFailure::Failed("notification deadline overflow".into()))?;
    let (finished_tx, finished_rx) = mpsc::channel();
    shared
        .writer
        .send(WriterMessage::Write {
            line,
            finished: Some(finished_tx),
        })
        .map_err(|_| CallFailure::Failed("muse host writer stopped".into()))?;
    match finished_rx.recv_timeout(remaining(deadline)) {
        Ok(Ok(())) => Ok(()),
        Ok(Err(message)) => {
            timeout_host(shared, "notification", &message);
            Err(CallFailure::Failed(message))
        }
        Err(_) => {
            timeout_host(shared, "notification", "muse host notification timed out");
            Err(CallFailure::Failed(
                "muse host notification timed out".into(),
            ))
        }
    }
}

fn writer_loop(receiver: Receiver<WriterMessage>, mut stdin: ChildStdin) {
    while let Ok(message) = receiver.recv() {
        match message {
            WriterMessage::Write { line, finished } => {
                let result = stdin
                    .write_all(line.as_bytes())
                    .and_then(|()| stdin.write_all(b"\n"))
                    .map_err(|error| error.to_string());
                if let Some(finished) = finished {
                    let _ = finished.send(result.clone());
                }
                if result.is_err() {
                    break;
                }
            }
            WriterMessage::Close(finished) => {
                drop(stdin);
                let _ = finished.send(());
                return;
            }
        }
    }
}

fn reader_loop(stdout: std::process::ChildStdout, shared: Arc<Shared>) {
    let mut reader = BufReader::new(stdout);
    let mut bytes = Vec::new();
    loop {
        bytes.clear();
        match reader.read_until(b'\n', &mut bytes) {
            Ok(0) => break,
            Ok(_) => {
                if bytes.last() == Some(&b'\n') {
                    bytes.pop();
                }
                if bytes.last() == Some(&b'\r') {
                    bytes.pop();
                }
                let line = String::from_utf8_lossy(&bytes).into_owned();
                if line == "PANIC_LINE" && shared.panic_mode == Some(PanicMode::Reader) {
                    panic!("test panic in supervisor reader thread");
                }
                handle_host_line(&shared, &line);
            }
            Err(_) => break,
        }
    }
    shared.host_eof.store(true, Ordering::SeqCst);
}

fn handle_host_line(shared: &Arc<Shared>, line: &str) {
    match msp::parse_line(line) {
        Incoming::Response { id, result } => handle_response(shared, id, result),
        Incoming::Event(event) => handle_event(shared, event, line),
        Incoming::HostRequest { id, method } => {
            if update_store(shared, |_| {
                vec![json!({"kind":"host.refused","method":method.clone(),"id":id.clone()})]
            })
            .is_err()
            {
                return;
            }
            let refusal = msp::refusal(&id);
            let _ = shared.writer.send(WriterMessage::Write {
                line: refusal,
                finished: None,
            });
        }
        Incoming::Unparsed(text) => {
            if shared.panic_mode == Some(PanicMode::Apply) && text == "PANIC_LINE" {
                let _ = shared
                    .store
                    .update(|_| panic!("test panic in Store::update"));
                return;
            }
            let short: String = text.chars().take(200).collect();
            let _ = update_store(shared, |_| {
                vec![json!({"kind":"host.unparsed","line":short})]
            });
        }
    }
}

fn handle_response(shared: &Arc<Shared>, id: i64, result: Result<Value, RpcError>) {
    let pending = lock(&shared.pending).remove(&id);
    let Some(pending) = pending else {
        return;
    };
    if pending.method == "session/start"
        && let Ok(value) = &result
        && let Some(session_id) = value
            .get("session")
            .and_then(|session| session.get("sessionId"))
            .and_then(Value::as_str)
    {
        let session_id = session_id.to_string();
        if update_store(shared, |state| {
            state.muse_session_id = Some(session_id);
            Vec::new()
        })
        .is_err()
        {
            let _ = pending.response.send(Err(RpcError {
                code: -32000,
                kind: Some("stateWriteFailed".into()),
                message: "could not write session state".into(),
            }));
            return;
        }
    }
    if pending.method == "turn/start" {
        match &result {
            Ok(value) => {
                let turn_id = value
                    .get("turnId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let disposition = msp::ack_disposition(value);
                if update_store(shared, |state| {
                    state::apply_ack(state, &turn_id, disposition, now_ms())
                })
                .is_err()
                {
                    let _ = pending.response.send(Err(RpcError {
                        code: -32000,
                        kind: Some("stateWriteFailed".into()),
                        message: "could not write session state".into(),
                    }));
                    return;
                }
                shared.first_turn_acked.store(true, Ordering::SeqCst);
            }
            Err(_) => {
                if update_store(shared, |state| {
                    state::abort_turn(state, now_ms());
                    Vec::new()
                })
                .is_err()
                {
                    let _ = pending.response.send(Err(RpcError {
                        code: -32000,
                        kind: Some("stateWriteFailed".into()),
                        message: "could not write session state".into(),
                    }));
                    return;
                }
            }
        }
    }
    let _ = pending.response.send(result);
}

fn handle_event(shared: &Arc<Shared>, event: HostEvent, raw_line: &str) {
    if matches!(event, HostEvent::Ignored) {
        return;
    }
    if shared.panic_mode == Some(PanicMode::Apply) && raw_line == "PANIC_LINE" {
        let _ = shared
            .store
            .update(|_| panic!("test panic in Store::update"));
        return;
    }
    let before = shared.store.snapshot();
    let should_note_idle = match &event {
        HostEvent::TurnCompleted { turn_id, .. } => {
            before.status == Status::Running
                && before.active_turn_id.as_deref() == Some(turn_id.as_str())
        }
        _ => false,
    };
    let status_change = matches!(&event, HostEvent::StatusChanged { .. });
    let old_times = (before.updated_at, before.last_progress_at);
    if update_store(shared, |state| {
        let lines = state::apply_event(state, &event, now_ms());
        if status_change {
            state.updated_at = old_times.0;
            state.last_progress_at = old_times.1;
        }
        lines
    })
    .is_err()
    {
        return;
    }
    if should_note_idle {
        let after = shared.store.snapshot();
        if after.status == Status::Idle {
            note_inbox(shared, &after.inbox, Note::Idle);
        }
    }
}

fn accept_loop(listener: UnixListener, shared: Arc<Shared>) {
    let mut connections = Vec::new();
    while !shared.shutdown.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                let connection_shared = shared.clone();
                connections.push(thread::spawn(move || {
                    guard_thread(connection_shared.clone(), || {
                        handle_connection(stream, connection_shared)
                    });
                }));
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL);
            }
            Err(_) => break,
        }
    }
    for connection in connections {
        let _ = connection.join();
    }
}

fn handle_connection(mut stream: UnixStream, shared: Arc<Shared>) {
    if stream.set_nonblocking(false).is_err() {
        return;
    }
    let _ = stream.set_write_timeout(Some(shared.config.request_read));
    match read_request_line(&mut stream, shared.config.request_read, &shared.shutdown) {
        RequestLine::Timeout | RequestLine::Closed => (),
        RequestLine::TooLong => {
            let _ = write_reply(
                &mut stream,
                &error_reply("usage", "request line is too long"),
            );
        }
        RequestLine::Line(line) => {
            let request: Value = match serde_json::from_slice(&line) {
                Ok(value) => value,
                Err(_) => {
                    let _ = write_reply(&mut stream, &error_reply("usage", "invalid request"));
                    return;
                }
            };
            let reply = match request.get("op").and_then(Value::as_str) {
                Some("send") => match request.get("text").and_then(Value::as_str) {
                    Some(text) if !text.trim().is_empty() && text.len() <= MAX_TEXT => {
                        send_text(&shared, text)
                    }
                    Some(text) if text.len() > MAX_TEXT => {
                        error_reply("usage", "text exceeds MAX_TEXT")
                    }
                    _ => error_reply("usage", "text must not be empty"),
                },
                Some("stop") => match request.get("interrupt").and_then(Value::as_bool) {
                    Some(interrupt) => stop_session(&shared, interrupt),
                    None => error_reply("usage", "stop requires an interrupt boolean"),
                },
                _ => error_reply("usage", "unknown session operation"),
            };
            let _ = write_reply(&mut stream, &reply);
        }
    }
}

enum RequestLine {
    Line(Vec<u8>),
    TooLong,
    Timeout,
    Closed,
}

fn read_request_line(
    stream: &mut UnixStream,
    timeout: Duration,
    shutdown: &AtomicBool,
) -> RequestLine {
    let deadline = Instant::now() + timeout;
    let mut line = Vec::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        if shutdown.load(Ordering::SeqCst) {
            return RequestLine::Closed;
        }
        let remaining = remaining(deadline);
        if remaining.is_zero() {
            return RequestLine::Timeout;
        }
        if stream
            .set_read_timeout(Some(remaining.min(ACCEPT_POLL)))
            .is_err()
        {
            return RequestLine::Closed;
        }
        match stream.read(&mut buffer) {
            Ok(0) => return RequestLine::Closed,
            Ok(count) => {
                if let Some(newline) = buffer[..count].iter().position(|byte| *byte == b'\n') {
                    let length = line.len() + newline;
                    if length > MAX_LINE {
                        return RequestLine::TooLong;
                    }
                    line.extend_from_slice(&buffer[..newline]);
                    return RequestLine::Line(line);
                }
                line.extend_from_slice(&buffer[..count]);
                if line.len() > MAX_LINE {
                    return RequestLine::TooLong;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if Instant::now() >= deadline {
                    return RequestLine::Timeout;
                }
            }
            Err(_) => return RequestLine::Closed,
        }
    }
}

fn write_reply(stream: &mut UnixStream, value: &Value) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(value).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    stream.write_all(&bytes)
}

fn send_text(shared: &Arc<Shared>, text: &str) -> Value {
    if let Some(reply) = reject_stopping_or_dead(shared) {
        return reply;
    }
    let admission = lock(&shared.admission);
    if let Some(reply) = reject_stopping_or_dead(shared) {
        drop(admission);
        return reply;
    }

    let mut started = false;
    let mut active_turn = None;
    let mut rejected = None;
    if update_store(shared, |state| {
        if state.status == Status::Dead {
            rejected = Some(error_reply("dead", "session is dead"));
        } else if state.stopping {
            rejected = Some(error_reply("busy", "session is stopping"));
        } else if state::begin_turn(state, now_ms()) {
            started = true;
        } else if state.status == Status::Running {
            active_turn = state.active_turn_id.clone();
        } else {
            rejected = Some(error_reply("busy", "session is busy"));
        }
        Vec::new()
    })
    .is_err()
    {
        return error_reply("failed", "could not write session state");
    }
    if let Some(reply) = rejected {
        return reply;
    }
    if started {
        let result = start_turn(shared, text);
        drop(admission);
        return result;
    }
    let Some(turn_id) = active_turn else {
        drop(admission);
        return error_reply("failed", "active turn id is not available");
    };

    let params = msp::turn_steer_params(
        shared
            .store
            .snapshot()
            .muse_session_id
            .as_deref()
            .unwrap_or_default(),
        &turn_id,
        text,
        now_ms(),
    );
    let command_id = params["commandId"].as_str().unwrap_or_default().to_string();
    if update_store(shared, |state| {
        state::note_steer(state, &command_id);
        Vec::new()
    })
    .is_err()
    {
        drop(admission);
        return error_reply("failed", "could not write session state");
    }
    match call(shared, "turn/steer", params) {
        Ok(_) => {
            drop(admission);
            json!({"ok":true,"disposition":"steered"})
        }
        Err(CallFailure::Rpc(error)) => {
            drop_steer(shared, &command_id);
            if shared
                .store
                .wait_until(
                    |state| state.status == Status::Idle,
                    shared.config.steer_settle,
                )
                .is_some()
            {
                let mut started = false;
                if update_store(shared, |state| {
                    started = state::begin_turn(state, now_ms());
                    Vec::new()
                })
                .is_err()
                {
                    drop(admission);
                    return error_reply("failed", "could not write session state");
                }
                if started {
                    let reply = start_turn(shared, text);
                    drop(admission);
                    return reply;
                }
            }
            drop(admission);
            error_reply("failed", &format!("steer refused: {}", error.message))
        }
        Err(CallFailure::Failed(message)) => {
            drop_steer(shared, &command_id);
            drop(admission);
            error_reply("failed", &message)
        }
    }
}

fn start_turn(shared: &Arc<Shared>, text: &str) -> Value {
    let session_id = shared.store.snapshot().muse_session_id.unwrap_or_default();
    match call(
        shared,
        "turn/start",
        msp::turn_start_params(&session_id, text, now_ms()),
    ) {
        Ok(result) => match msp::ack_disposition(&result) {
            Disposition::Steered => json!({"ok":true,"disposition":"steered"}),
            Disposition::Started | Disposition::Queued | Disposition::Other => {
                json!({"ok":true,"disposition":"started"})
            }
        },
        Err(error) => error_reply("failed", &error.message()),
    }
}

fn stop_session(shared: &Arc<Shared>, interrupt: bool) -> Value {
    if let Some(reply) = reject_stopping_or_dead(shared) {
        return reply;
    }
    let mut no_op = false;
    let mut turn_id = None;
    let mut should_interrupt = false;
    let mut rejected = None;
    if update_store(shared, |state| {
        if state.status == Status::Dead {
            rejected = Some(error_reply("dead", "session is dead"));
        } else if state.stopping {
            rejected = Some(error_reply("busy", "session is stopping"));
        } else if interrupt && state.status == Status::Idle {
            no_op = true;
        } else {
            state.stopping = true;
            should_interrupt = state.status == Status::Running;
            turn_id = state.active_turn_id.clone();
        }
        Vec::new()
    })
    .is_err()
    {
        return error_reply("failed", "could not write session state");
    }
    if let Some(reply) = rejected {
        return reply;
    }
    if no_op {
        return json!({"ok":true,"interrupted":false});
    }

    let admission = lock(&shared.admission);
    if let Some(reply) = reject_dead(shared) {
        drop(admission);
        return reply;
    }
    let current = shared.store.snapshot();
    let should_interrupt = should_interrupt && current.status == Status::Running;
    if should_interrupt {
        let session_id = current.muse_session_id.unwrap_or_default();
        let params = msp::turn_interrupt_params(&session_id, turn_id.as_deref(), now_ms());
        let _ = call(shared, "turn/interrupt", params);
    }
    drop(admission);

    if interrupt {
        let ended = shared.store.wait_until(
            |state| state.status == Status::Idle || state.status == Status::Dead,
            shared.config.interrupt_wait,
        );
        if let Some(state) = ended {
            if state.status == Status::Dead {
                return error_reply("dead", "session is dead");
            }
            if update_store(shared, |state| {
                state.stopping = false;
                Vec::new()
            })
            .is_err()
            {
                return error_reply("failed", "could not write session state");
            }
            return json!({"ok":true,"interrupted":true});
        }
        terminate_host(&shared.host, shared.config.term_wait);
        mark_dead(
            &shared.store,
            &shared.paths,
            &shared.id,
            DeadReason::HostUnresponsive,
            None,
            "turn did not end after interrupt",
            true,
            &shared.fatal_write,
        );
        return error_reply("dead", "session is dead");
    }

    let _ = shared.store.wait_until(
        |state| state.status == Status::Idle || state.status == Status::Dead,
        shared.config.interrupt_wait,
    );
    if shared.store.snapshot().status != Status::Dead {
        close_host_stdin(shared);
        if shared
            .host
            .wait_for_exit(shared.config.stop_grace)
            .is_none()
        {
            shared.host.signal_group(libc::SIGTERM);
            if shared.host.wait_for_exit(shared.config.term_wait).is_none() {
                shared.host.signal_group(libc::SIGKILL);
                let _ = shared.host.wait_for_exit(KILL_REAP_WAIT);
            }
        }
        let exit_code = shared
            .host
            .try_wait()
            .ok()
            .flatten()
            .and_then(|status| status.code());
        mark_dead(
            &shared.store,
            &shared.paths,
            &shared.id,
            DeadReason::Stopped,
            exit_code,
            "session stopped",
            false,
            &shared.fatal_write,
        );
    }
    json!({"ok":true})
}

fn close_host_stdin(shared: &Arc<Shared>) {
    let (finished_tx, finished_rx) = mpsc::channel();
    if shared
        .writer
        .send(WriterMessage::Close(finished_tx))
        .is_ok()
    {
        let _ = finished_rx.recv_timeout(shared.config.rpc_timeout);
    }
}

fn reject_stopping_or_dead(shared: &Shared) -> Option<Value> {
    let state = shared.store.snapshot();
    if state.status == Status::Dead {
        Some(error_reply("dead", "session is dead"))
    } else if state.stopping {
        Some(error_reply("busy", "session is stopping"))
    } else {
        None
    }
}

fn reject_dead(shared: &Shared) -> Option<Value> {
    (shared.store.snapshot().status == Status::Dead).then(|| error_reply("dead", "session is dead"))
}

fn drop_steer(shared: &Shared, command_id: &str) {
    let _ = update_store(shared, |state| {
        state::drop_steer(state, command_id);
        Vec::new()
    });
}

fn timeout_host(shared: &Shared, method: &str, message: &str) {
    shared.host.signal_group(libc::SIGKILL);
    let reason = if shared.first_turn_acked.load(Ordering::SeqCst) {
        DeadReason::HostUnresponsive
    } else {
        DeadReason::StartFailed
    };
    mark_dead(
        &shared.store,
        &shared.paths,
        &shared.id,
        reason,
        None,
        &format!("{method}: {message}"),
        false,
        &shared.fatal_write,
    );
}

fn terminate_host(host: &HostControl, term_wait: Duration) {
    host.signal_group(libc::SIGTERM);
    if host.wait_for_exit(term_wait).is_none() {
        host.signal_group(libc::SIGKILL);
        let _ = host.wait_for_exit(KILL_REAP_WAIT);
    }
}

#[allow(clippy::too_many_arguments)]
fn mark_dead(
    store: &Store,
    paths: &Paths,
    id: &str,
    reason: DeadReason,
    exit_code: Option<i32>,
    message: &str,
    keep_stopping: bool,
    fatal_write: &AtomicBool,
) {
    if store.snapshot().status != Status::Dead {
        record_dead_event_once(store, id, fatal_write);
    }
    let mut changed = false;
    let result = store.update(|state| {
        if state.status != Status::Dead {
            state::mark_dead(state, reason, exit_code, message, now_ms());
            if keep_stopping {
                state.stopping = true;
            }
            changed = true;
        }
        Vec::new()
    });
    if result.is_err() {
        fatal_write.store(true, Ordering::SeqCst);
        return;
    }
    if changed && let Ok(state) = state::read_state(paths, id) {
        write_note_or_log(store, id, &state.inbox, Note::Dead, fatal_write);
    }
}

fn dead_event_ids() -> &'static Mutex<HashSet<String>> {
    static IDS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    IDS.get_or_init(|| Mutex::new(HashSet::new()))
}

fn record_dead_event_once(store: &Store, id: &str, fatal_write: &AtomicBool) {
    let mut ids = dead_event_ids()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    if ids.contains(id) {
        return;
    }
    if store
        .update(|_| vec![json!({"kind":"session.dead"})])
        .is_ok()
    {
        ids.insert(id.to_string());
    } else {
        fatal_write.store(true, Ordering::SeqCst);
    }
}

fn note_inbox(shared: &Shared, inbox_path: &str, note: Note) {
    write_note_or_log(
        &shared.store,
        &shared.id,
        inbox_path,
        note,
        &shared.fatal_write,
    );
}

fn write_note_or_log(
    store: &Store,
    id: &str,
    inbox_path: &str,
    note: Note,
    fatal_write: &AtomicBool,
) {
    if inbox_path.is_empty() {
        return;
    }
    if let Err(error) = inbox::notify(Path::new(inbox_path), id, note, now_ms())
        && store
            .update(|_| vec![json!({"kind":"inbox.failed","error":error.to_string()})])
            .is_err()
    {
        fatal_write.store(true, Ordering::SeqCst);
    }
}

fn update_store(
    shared: &Shared,
    update: impl FnOnce(&mut State) -> Vec<Value>,
) -> Result<(), String> {
    shared.store.update(update).map_err(|error| {
        shared.fatal_write.store(true, Ordering::SeqCst);
        error.to_string()
    })
}

fn finish_pre_spawn_failure(
    store: &Store,
    paths: &Paths,
    id: &str,
    reason: DeadReason,
    message: &str,
) -> i32 {
    let fatal_write = AtomicBool::new(false);
    mark_dead(store, paths, id, reason, None, message, false, &fatal_write);
    if fatal_write.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

fn cleanup_after_host(
    shared: Arc<Shared>,
    socket: &Path,
    writer_thread: Option<JoinHandle<()>>,
    reader_thread: Option<JoinHandle<()>>,
    accept_thread: Option<JoinHandle<()>>,
    guard: &mut RunGuard,
    code: i32,
) -> i32 {
    shared.shutdown.store(true, Ordering::SeqCst);
    let _ = shared.writer.send(WriterMessage::Close(mpsc::channel().0));
    if shared.host.try_wait().ok().flatten().is_none() {
        shared.host.signal_group(libc::SIGKILL);
        let _ = shared.host.wait_for_exit(KILL_REAP_WAIT);
    }
    if let Some(thread) = writer_thread {
        let _ = thread.join();
    }
    if let Some(thread) = reader_thread {
        let _ = thread.join();
    }
    if let Some(thread) = accept_thread {
        let _ = thread.join();
    }
    remove_socket(&shared.paths, &shared.id, socket);
    guard.disarm();
    if shared.fatal_write.load(Ordering::SeqCst) {
        1
    } else {
        code
    }
}

fn dead_reply_grace(shared: &Shared) -> Duration {
    shared.config.request_read.min(Duration::from_millis(300))
}

fn remove_socket(paths: &Paths, id: &str, socket: &Path) {
    let _ = fs::set_permissions(paths.dir(id), fs::Permissions::from_mode(0o700));
    let _ = fs::remove_file(socket);
}

fn isolate_child_descriptors(command: &mut std::process::Command) {
    // Keep Rust's exec-error pipe alive until exec, but close every inherited fd on success.
    unsafe {
        command.pre_exec(|| {
            #[cfg(target_os = "linux")]
            if libc::close_range(3, u32::MAX, libc::CLOSE_RANGE_CLOEXEC as libc::c_int) == 0 {
                return Ok(());
            }

            let mut limit = std::mem::MaybeUninit::<libc::rlimit>::uninit();
            if libc::getrlimit(libc::RLIMIT_NOFILE, limit.as_mut_ptr()) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            let max_fd = limit.assume_init().rlim_cur.min(libc::c_int::MAX as _) as libc::c_int;
            for fd in 3..max_fd {
                let flags = libc::fcntl(fd, libc::F_GETFD);
                if flags == -1 {
                    if std::io::Error::last_os_error().raw_os_error() == Some(libc::EBADF) {
                        continue;
                    }
                    return Err(std::io::Error::last_os_error());
                }
                if libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
}

fn open_host_stderr(path: &Path) -> std::io::Result<File> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

fn guard_thread(shared: Arc<Shared>, work: impl FnOnce()) {
    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)).is_err() {
        shared.thread_panicked.store(true, Ordering::SeqCst);
    }
}

fn catch_unwind_silent(work: impl FnOnce()) -> Result<(), ()> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)).map_err(|_| ())
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

fn remaining(deadline: Instant) -> Duration {
    deadline.saturating_duration_since(Instant::now())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn error_reply(code: &str, message: &str) -> Value {
    json!({"ok":false,"code":code,"message":message})
}
