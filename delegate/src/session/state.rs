use crate::session::msp::{Disposition, HostEvent, TurnError, log_line};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const STARTING_GRACE_MS: u64 = 60_000;
const SOCKET_PATH_LIMIT: usize = 100;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Running,
    Idle,
    Dead,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeadReason {
    Stopped,
    HostExited,
    HostUnresponsive,
    StartFailed,
    SupervisorDied,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub prompt_tokens: u64,
    pub output_tokens: u64,
    pub total_tokens: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LastTurn {
    pub turn_id: String,
    pub terminal: String,
    pub error: Option<TurnError>,
    pub ended_at: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeadInfo {
    pub reason: DeadReason,
    pub exit_code: Option<i32>,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub schema: u32,
    pub id: String,
    pub status: Status,
    pub stopping: bool,
    pub model: String,
    pub cwd: String,
    pub inbox: String,
    pub supervisor_pid: Option<i32>,
    pub host_pid: Option<i32>,
    pub muse_session_id: Option<String>,
    pub active_turn_id: Option<String>,
    pub turn_count: u64,
    pub started_at: u64,
    pub updated_at: u64,
    pub last_progress_at: u64,
    pub last_turn: Option<LastTurn>,
    pub usage: Usage,
    pub dead: Option<DeadInfo>,
    #[serde(skip)]
    pub(crate) pending_steers: Vec<String>,
}

pub fn new_state(id: &str, model: &str, cwd: &str, inbox: &str, now_ms: u64) -> State {
    State {
        schema: 1,
        id: id.to_string(),
        status: Status::Idle,
        stopping: false,
        model: model.to_string(),
        cwd: cwd.to_string(),
        inbox: inbox.to_string(),
        supervisor_pid: None,
        host_pid: None,
        muse_session_id: None,
        active_turn_id: None,
        turn_count: 0,
        started_at: now_ms,
        updated_at: now_ms,
        last_progress_at: now_ms,
        last_turn: None,
        usage: Usage::default(),
        dead: None,
        pending_steers: Vec::new(),
    }
}

#[derive(Clone, Debug)]
pub struct Paths {
    root: PathBuf,
}

impl Paths {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn default_root() -> PathBuf {
        crate::util::homedir().join(".cache/agents/sessions")
    }

    pub fn dir(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    pub fn state_file(&self, id: &str) -> PathBuf {
        self.dir(id).join("state.json")
    }

    pub fn events_file(&self, id: &str) -> PathBuf {
        self.dir(id).join("events.jsonl")
    }

    pub fn host_stderr(&self, id: &str) -> PathBuf {
        self.dir(id).join("host.stderr")
    }

    pub fn brief_file(&self, id: &str) -> PathBuf {
        self.dir(id).join("brief.txt")
    }

    pub fn socket_path(&self, id: &str) -> Result<PathBuf, StateError> {
        if !valid_id(id) {
            return Err(StateError::Unreadable("invalid session id".into()));
        }
        let path = self.dir(id).join("sock");
        // debt: one 100-byte socket path, move sockets to a short runtime dir if a real home exceeds it.
        use std::os::unix::ffi::OsStrExt;
        if path.as_os_str().as_bytes().len() > SOCKET_PATH_LIMIT {
            return Err(StateError::SocketPath(format!(
                "unix socket path exceeds {SOCKET_PATH_LIMIT} bytes"
            )));
        }
        Ok(path)
    }
}

pub fn create_session_dir(paths: &Paths, id: &str) -> std::io::Result<PathBuf> {
    if !valid_id(id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "invalid session id",
        ));
    }
    fs::create_dir_all(&paths.root)?;
    let dir = paths.dir(id);
    match fs::create_dir(&dir) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists && dir.is_dir() => {}
        Err(error) => return Err(error),
    }
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

pub fn valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    if bytes.len() != 36 {
        return false;
    }
    bytes.iter().enumerate().all(|(index, byte)| {
        if [8, 13, 18, 23].contains(&index) {
            *byte == b'-'
        } else {
            byte.is_ascii_digit() || (b'a'..=b'f').contains(byte)
        }
    })
}

#[derive(Debug)]
pub enum StateError {
    Missing,
    Unreadable(String),
    SocketPath(String),
    Io(std::io::Error),
}

impl std::fmt::Display for StateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Missing => write!(f, "session state is missing"),
            Self::Unreadable(message) => write!(f, "unreadable session state: {message}"),
            Self::SocketPath(message) => write!(f, "{message}"),
            Self::Io(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for StateError {}

impl From<std::io::Error> for StateError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

pub fn read_state(paths: &Paths, id: &str) -> Result<State, StateError> {
    if !valid_id(id) {
        return Err(StateError::Unreadable("invalid session id".into()));
    }
    let bytes = match fs::read(paths.state_file(id)) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(StateError::Missing);
        }
        Err(error) => return Err(StateError::Io(error)),
    };
    let state: State = serde_json::from_slice(&bytes)
        .map_err(|error| StateError::Unreadable(error.to_string()))?;
    if state.schema != 1 {
        return Err(StateError::Unreadable(format!(
            "unsupported schema {}",
            state.schema
        )));
    }
    if state.id != id {
        return Err(StateError::Unreadable(
            "state id does not match directory".into(),
        ));
    }
    Ok(state)
}

pub fn write_state(paths: &Paths, state: &State) -> std::io::Result<()> {
    if !valid_id(&state.id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "invalid session id",
        ));
    }
    let dir = paths.dir(&state.id);
    if !dir.is_dir() {
        create_session_dir(paths, &state.id)?;
    }
    let bytes = serde_json::to_vec(state).map_err(std::io::Error::other)?;
    let tmp = dir.join(format!(".state-{}.tmp", crate::util::random_uuid()));
    use std::os::unix::fs::OpenOptionsExt;
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&bytes)?;
        fs::rename(&tmp, paths.state_file(&state.id))
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}

struct StoreInner {
    state: State,
    events: File,
    next_seq: u64,
}

pub struct Store {
    paths: Paths,
    inner: Mutex<StoreInner>,
    changed: Condvar,
}

impl Store {
    pub fn open(paths: Paths, state: State) -> std::io::Result<Self> {
        create_session_dir(&paths, &state.id)?;
        write_state(&paths, &state)?;
        let events_path = paths.events_file(&state.id);
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let events = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&events_path)?;
        fs::set_permissions(&events_path, fs::Permissions::from_mode(0o600))?;
        let next_seq = 1;
        Ok(Self {
            paths,
            inner: Mutex::new(StoreInner {
                state,
                events,
                next_seq,
            }),
            changed: Condvar::new(),
        })
    }

    fn lock(&self) -> MutexGuard<'_, StoreInner> {
        self.inner.lock().unwrap_or_else(|error| error.into_inner())
    }

    pub fn update(&self, update: impl FnOnce(&mut State) -> Vec<Value>) -> std::io::Result<()> {
        let mut guard = self.lock();
        let mut next = guard.state.clone();
        let lines = update(&mut next);
        write_state(&self.paths, &next)?;

        let mut seq = guard.next_seq;
        let now = epoch_ms();
        let mut output = Vec::new();
        for line in lines {
            let mut object = match line {
                Value::Object(object) => object,
                value => Map::from_iter([("value".into(), value)]),
            };
            object.insert("seq".into(), json!(seq));
            object.insert("at".into(), json!(now));
            serde_json::to_writer(&mut output, &Value::Object(object))?;
            output.push(b'\n');
            seq = seq.saturating_add(1);
        }
        if !output.is_empty() {
            let _ = guard.events.write_all(&output);
        }
        guard.next_seq = seq;
        guard.state = next;
        self.changed.notify_all();
        Ok(())
    }

    pub fn snapshot(&self) -> State {
        self.lock().state.clone()
    }

    pub fn wait_until(
        &self,
        predicate: impl Fn(&State) -> bool,
        timeout: Duration,
    ) -> Option<State> {
        let deadline = Instant::now().checked_add(timeout)?;
        let mut guard = self.lock();
        loop {
            if predicate(&guard.state) {
                return Some(guard.state.clone());
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            let (next, result) = self
                .changed
                .wait_timeout(guard, deadline.saturating_duration_since(now))
                .unwrap_or_else(|error| error.into_inner());
            guard = next;
            if result.timed_out() && !predicate(&guard.state) {
                return None;
            }
        }
    }
}

fn epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

pub fn begin_turn(state: &mut State, now_ms: u64) -> bool {
    if state.status != Status::Idle || state.stopping {
        return false;
    }
    state.status = Status::Running;
    state.active_turn_id = None;
    state.updated_at = now_ms;
    state.last_progress_at = now_ms;
    true
}

pub fn abort_turn(state: &mut State, now_ms: u64) {
    if state.status == Status::Running && state.active_turn_id.is_none() {
        state.status = Status::Idle;
        state.updated_at = now_ms;
        state.last_progress_at = now_ms;
    }
}

pub fn apply_ack(
    state: &mut State,
    turn_id: &str,
    disposition: Disposition,
    now_ms: u64,
) -> Vec<Value> {
    if state.status == Status::Dead {
        return Vec::new();
    }
    if disposition == Disposition::Started {
        if state.status == Status::Running && state.active_turn_id.is_none() {
            state.active_turn_id = Some(turn_id.to_string());
            state.turn_count += 1;
            state.updated_at = now_ms;
            state.last_progress_at = now_ms;
        }
        return Vec::new();
    }
    if state.status == Status::Running && state.active_turn_id.is_none() {
        state.status = Status::Idle;
        state.updated_at = now_ms;
        state.last_progress_at = now_ms;
    }
    let disposition_name = match disposition {
        Disposition::Queued => "queued",
        Disposition::Steered => "steered",
        Disposition::Other => "other",
        Disposition::Started => unreachable!(),
    };
    vec![json!({"kind":"ack.unexpected","turnId":turn_id,"disposition":disposition_name})]
}

pub fn note_steer(state: &mut State, command_id: &str) {
    if state.status != Status::Dead {
        state.pending_steers.push(command_id.to_string());
    }
}

pub fn drop_steer(state: &mut State, command_id: &str) {
    state.pending_steers.retain(|pending| pending != command_id);
}

pub fn apply_event(state: &mut State, event: &HostEvent, now_ms: u64) -> Vec<Value> {
    if state.status == Status::Dead {
        return Vec::new();
    }
    let Some(mut line) = log_line(event) else {
        return Vec::new();
    };
    if let HostEvent::TurnCompleted {
        turn_id,
        terminal,
        error,
    } = event
    {
        if state.active_turn_id.as_deref() != Some(turn_id.as_str()) {
            line["stale"] = json!(true);
            return vec![line];
        }
        state.status = Status::Idle;
        state.active_turn_id = None;
        state.last_turn = Some(LastTurn {
            turn_id: turn_id.clone(),
            terminal: terminal.clone(),
            error: error.clone(),
            ended_at: now_ms,
        });
        state.updated_at = now_ms;
        state.last_progress_at = now_ms;
        let mut lines = vec![line];
        if !state.pending_steers.is_empty() {
            lines.push(json!({"kind":"steer.unconsumed","turnId":turn_id,"commandIds":state.pending_steers}));
            state.pending_steers.clear();
        }
        return lines;
    }
    match event {
        HostEvent::SessionStarted { session_id } => {
            state.muse_session_id = Some(session_id.clone())
        }
        HostEvent::TurnStarted { turn_id }
            if state.status == Status::Idle && state.active_turn_id.is_none() =>
        {
            state.status = Status::Running;
            state.active_turn_id = Some(turn_id.clone());
            state.turn_count += 1;
        }
        HostEvent::UserMessage {
            command_id: Some(command_id),
            ..
        } => {
            drop_steer(state, command_id);
        }
        HostEvent::TokenUsage {
            prompt,
            output,
            total,
        } => {
            state.usage = Usage {
                prompt_tokens: *prompt,
                output_tokens: *output,
                total_tokens: *total,
            };
        }
        _ => {}
    }
    state.updated_at = now_ms;
    state.last_progress_at = now_ms;
    vec![line]
}

pub fn mark_dead(
    state: &mut State,
    reason: DeadReason,
    exit_code: Option<i32>,
    message: &str,
    now_ms: u64,
) {
    if state.status == Status::Dead || state.dead.is_some() {
        return;
    }
    state.status = Status::Dead;
    state.stopping = false;
    state.active_turn_id = None;
    state.dead = Some(DeadInfo {
        reason,
        exit_code,
        message: message.to_string(),
    });
    state.updated_at = now_ms;
    state.last_progress_at = now_ms;
}

pub fn settle_dead_supervisor(
    paths: &Paths,
    id: &str,
    now_ms: u64,
) -> Result<Option<State>, StateError> {
    let current = read_state(paths, id)?;
    if current.status == Status::Dead {
        return Ok(None);
    }
    let (reason, message) = match current.supervisor_pid {
        Some(pid) if pid <= 1 => (DeadReason::SupervisorDied, "corrupt supervisorPid"),
        Some(pid) if process_missing(pid) => (DeadReason::SupervisorDied, "supervisor exited"),
        Some(_) => return Ok(None),
        None if now_ms.saturating_sub(current.started_at) > STARTING_GRACE_MS => {
            (DeadReason::StartFailed, "supervisor never started")
        }
        None => return Ok(None),
    };
    let mut fresh = read_state(paths, id)?;
    if fresh.status == Status::Dead || fresh.supervisor_pid != current.supervisor_pid {
        return Ok(None);
    }
    mark_dead(&mut fresh, reason, None, message, now_ms);
    write_state(paths, &fresh)?;
    if let Some(host_pid) = fresh.host_pid
        && !matches!(fresh.supervisor_pid, Some(pid) if pid <= 1)
    {
        reap_host(host_pid);
    }
    Ok(Some(fresh))
}

// debt: pid-only liveness, add a heartbeat-age check when a reused supervisor pid shows up.
fn process_missing(pid: i32) -> bool {
    let result = unsafe { libc::kill(pid, 0) };
    result != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

pub fn is_host_command(command: &str) -> bool {
    let tokens: Vec<_> = command.split_whitespace().collect();
    tokens.windows(6).any(|argv| {
        argv[0] == "serve"
            && argv[1] == "--provider"
            && argv[2] == "meta"
            && argv[3] == "--model"
            && !argv[4].is_empty()
            && argv[5] == "--disable-sandbox"
    })
}

pub fn reap_host(host_pid: i32) {
    if host_pid <= 1 {
        return;
    }
    let output = std::process::Command::new("ps")
        .args(["-o", "command=", "-p", &host_pid.to_string()])
        .output();
    let Ok(output) = output else { return };
    if !output.status.success() || !is_host_command(&String::from_utf8_lossy(&output.stdout)) {
        return;
    }
    unsafe { libc::kill(-host_pid, libc::SIGTERM) };
    let deadline = Instant::now() + Duration::from_millis(250);
    while !process_missing(host_pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    if !process_missing(host_pid) {
        unsafe { libc::kill(-host_pid, libc::SIGKILL) };
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ListEntry {
    Session(State),
    Unreadable { id: String },
}

pub fn list(paths: &Paths, now_ms: u64) -> Vec<ListEntry> {
    let Ok(entries) = fs::read_dir(&paths.root) else {
        return Vec::new();
    };
    let mut sessions = Vec::new();
    for entry in entries.flatten() {
        let id = entry.file_name().to_string_lossy().into_owned();
        if !entry.file_type().is_ok_and(|kind| kind.is_dir()) || !valid_id(&id) {
            continue;
        }
        let _ = settle_dead_supervisor(paths, &id, now_ms);
        match read_state(paths, &id) {
            Ok(state) => sessions.push(ListEntry::Session(state)),
            Err(_) => sessions.push(ListEntry::Unreadable { id }),
        }
    }
    sessions.sort_by(|left, right| {
        let key = |entry: &ListEntry| match entry {
            ListEntry::Session(state) => (state.started_at, state.id.clone()),
            ListEntry::Unreadable { id } => (u64::MAX, id.clone()),
        };
        key(left).cmp(&key(right))
    });
    sessions
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::msp::{Disposition, HostEvent, ack_disposition, parse_line};
    use serde_json::{Value, json};
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::process::{Child, Command, Stdio};
    use std::sync::{Arc, Condvar, Mutex, mpsc};
    use std::time::{Duration, Instant};

    struct Scratch {
        paths: Paths,
        id: String,
    }

    impl Scratch {
        fn new() -> Self {
            let root = std::env::temp_dir()
                .join(format!("delegate-session-{}", crate::util::random_uuid()));
            std::fs::create_dir_all(&root).unwrap();
            let paths = Paths::new(root);
            let id = crate::util::random_uuid();
            Self { paths, id }
        }

        fn state(&self) -> State {
            new_state(
                &self.id,
                "muse/muse-spark-1.3-contributor",
                "/work",
                "/inbox",
                1000,
            )
        }

        fn store(&self) -> Store {
            Store::open(self.paths.clone(), self.state()).unwrap()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.paths.root);
        }
    }

    fn fixture(path: &str) -> &'static str {
        match path {
            "client.jsonl" => include_str!("../../tests/fixtures/contract/muse-serve/client.jsonl"),
            "client-abort-race.jsonl" => {
                include_str!("../../tests/fixtures/contract/muse-serve/client-abort-race.jsonl")
            }
            "bad-model.jsonl" => {
                include_str!("../../tests/fixtures/contract/muse-serve/bad-model.jsonl")
            }
            _ => unreachable!(),
        }
    }

    fn replay(transcript: &str, state: &mut State) -> Vec<(usize, HostEvent, Vec<Value>, State)> {
        let mut pending = HashMap::new();
        let mut logs = Vec::new();
        let mut now = 1001;
        for (index, line) in transcript.lines().enumerate() {
            if let Some(request) = line.strip_prefix("> ") {
                let request: Value = serde_json::from_str(request).unwrap();
                if request["method"] == "turn/start" {
                    assert!(
                        begin_turn(state, now),
                        "turn/start request at line {} was not admitted",
                        index + 1
                    );
                    pending.insert(request["id"].as_i64().unwrap(), ());
                } else if request["method"] == "turn/steer" {
                    note_steer(state, request["params"]["commandId"].as_str().unwrap());
                }
                continue;
            }
            let Some(frame) = line.strip_prefix("< ") else {
                continue;
            };
            match parse_line(frame) {
                crate::session::msp::Incoming::Response {
                    id,
                    result: Ok(result),
                } if pending.remove(&id).is_some() => {
                    let turn_id = result["turnId"].as_str().unwrap();
                    let lines = apply_ack(state, turn_id, ack_disposition(&result), now);
                    logs.extend(
                        lines
                            .into_iter()
                            .map(|line| (index + 1, HostEvent::Ignored, vec![line], state.clone())),
                    );
                }
                crate::session::msp::Incoming::Event(ev) => {
                    let lines = apply_event(state, &ev, now);
                    logs.push((index + 1, ev, lines, state.clone()));
                }
                crate::session::msp::Incoming::Unparsed(line) => {
                    panic!("unparsed fixture line {}: {line}", index + 1)
                }
                _ => {}
            }
            now += 1;
        }
        assert!(
            pending.is_empty(),
            "fixture has unmatched turn/start requests: {pending:?}"
        );
        logs
    }

    fn group_shell(label: Option<&str>, host: bool) -> Child {
        spawn_group_shell(label, host, false)
    }

    fn ready_group_shell(label: Option<&str>, host: bool) -> Child {
        spawn_group_shell(label, host, true)
    }

    fn spawn_group_shell(label: Option<&str>, host: bool, signal_ready: bool) -> Child {
        let mut command = Command::new("sh");
        let script = if signal_ready {
            "printf 'ready\\n'; sleep 30; :"
        } else {
            "sleep 30; :"
        };
        command.args(["-c", script]);
        if let Some(label) = label {
            command.arg(label);
        }
        if host {
            command.args(["--provider", "meta", "--model", "x", "--disable-sandbox"]);
        }
        use std::os::unix::process::CommandExt;
        command.process_group(0);
        command.stdin(Stdio::null()).stderr(Stdio::null());
        command.stdout(if signal_ready {
            Stdio::piped()
        } else {
            Stdio::null()
        });
        let mut child = command.spawn().unwrap();
        if signal_ready {
            use std::io::BufRead;
            let mut ready = String::new();
            std::io::BufReader::new(child.stdout.take().unwrap())
                .read_line(&mut ready)
                .expect("read child readiness");
            assert_eq!(ready, "ready\n");
        }
        child
    }

    fn finish_child(child: &mut Child) {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if child.try_wait().unwrap().is_some() {
                return;
            }
            if Instant::now() >= deadline {
                unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL) };
                panic!("child did not exit before its deadline");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    const WORKER_DEADLINE: Duration = Duration::from_secs(5);
    const TICKS_PER_WORKER: usize = 40;
    const OLD_TICKS_PER_WORKER: usize = 500;
    const SLOW_UPDATE_LATENCY: Duration = Duration::from_millis(10);
    // The 5 s guard is a hang guard, not a tunable: fail the build if it moves.
    const _: () = assert!(WORKER_DEADLINE.as_millis() == 5_000);
    // At the controlled per-update latency the old 500-per-worker workload
    // cannot finish inside the guard, so the slow-update proof stays valid.
    const _: () = assert!(
        2 * OLD_TICKS_PER_WORKER as u128 * SLOW_UPDATE_LATENCY.as_millis()
            > WORKER_DEADLINE.as_millis()
    );
    // The reduced workload at that latency stays under a quarter of the guard,
    // so raising the count back toward 500 fails the build.
    const _: () = assert!(
        2 * TICKS_PER_WORKER as u128 * SLOW_UPDATE_LATENCY.as_millis() * 4
            < WORKER_DEADLINE.as_millis()
    );

    fn threads_finish_within(handles: &[std::thread::JoinHandle<()>], budget: Duration) -> bool {
        let deadline = Instant::now() + budget;
        while handles.iter().any(|handle| !handle.is_finished()) {
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::yield_now();
        }
        true
    }

    fn wait_threads(handles: Vec<std::thread::JoinHandle<()>>) {
        assert!(
            threads_finish_within(&handles, WORKER_DEADLINE),
            "worker thread exceeded its deadline"
        );
        for handle in handles {
            handle.join().unwrap();
        }
    }

    fn run_tick_workers(
        store: &Arc<Store>,
        per_worker: usize,
        hook: Arc<dyn Fn() + Send + Sync>,
    ) -> Vec<std::thread::JoinHandle<()>> {
        let barrier = pair_barrier();
        let mut handles = Vec::new();
        for worker in 0..2 {
            let store = Arc::clone(store);
            let barrier = Arc::clone(&barrier);
            let hook = Arc::clone(&hook);
            handles.push(std::thread::spawn(move || {
                meet_pair(&barrier);
                for index in 0..per_worker {
                    store
                        .update(|state| {
                            hook();
                            state.updated_at += 1;
                            vec![json!({"kind":"tick","worker":worker,"index":index})]
                        })
                        .unwrap();
                }
            }));
        }
        handles
    }

    fn assert_tick_log(scratch: &Scratch, store: &Store, total: usize) {
        let disk = read_state(&scratch.paths, &scratch.id).unwrap();
        assert_eq!(disk, store.snapshot());
        let lines: Vec<Value> = std::fs::read_to_string(scratch.paths.events_file(&scratch.id))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        // Contract: delegate/README.md:62-63.
        assert_eq!(lines.len(), total);
        for (index, line) in lines.iter().enumerate() {
            // Contract: delegate/README.md:62-63.
            assert_eq!(line["seq"], json!(index + 1));
            if index > 0 {
                assert!(lines[index - 1]["seq"].as_u64().unwrap() < line["seq"].as_u64().unwrap());
            }
        }
    }

    fn pair_barrier() -> Arc<(Mutex<usize>, Condvar)> {
        Arc::new((Mutex::new(0), Condvar::new()))
    }

    fn meet_pair(barrier: &Arc<(Mutex<usize>, Condvar)>) {
        let deadline = Instant::now() + Duration::from_secs(3);
        let (lock, changed) = &**barrier;
        let mut count = lock.lock().unwrap_or_else(|e| e.into_inner());
        *count += 1;
        if *count == 2 {
            changed.notify_all();
            return;
        }
        while *count < 2 {
            let now = Instant::now();
            assert!(now < deadline, "barrier deadline expired");
            let (next, result) = changed
                .wait_timeout(count, deadline.saturating_duration_since(now))
                .unwrap_or_else(|e| e.into_inner());
            count = next;
            assert!(
                !result.timed_out() || *count == 2,
                "barrier deadline expired"
            );
        }
    }

    #[test]
    fn ids_are_canonical_lowercase_uuids_not_paths() {
        assert!(valid_id(&crate::util::random_uuid()));
        assert!(!valid_id("../x"));
        assert!(!valid_id("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"));
        assert!(!valid_id("short"));
        assert!(!valid_id(""));
        assert!(!valid_id("00000000-0000-4000-8000-00000000000g"));
    }

    #[test]
    fn state_io_roundtrips_and_reports_missing_or_corrupt_state() {
        let scratch = Scratch::new();
        create_session_dir(&scratch.paths, &scratch.id).unwrap();
        let mut state = scratch.state();
        state.pending_steers.push("not-on-disk".into());
        write_state(&scratch.paths, &state).unwrap();
        assert_eq!(
            read_state(&scratch.paths, &scratch.id).unwrap(),
            state_with_no_pending(state.clone())
        );
        assert!(
            serde_json::to_value(&state)
                .unwrap()
                .get("pendingSteers")
                .is_none()
        );
        assert!(
            std::fs::read_dir(scratch.paths.dir(&scratch.id))
                .unwrap()
                .all(|entry| !entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp"))
        );

        let missing = crate::util::random_uuid();
        assert!(matches!(
            read_state(&scratch.paths, &missing),
            Err(StateError::Missing)
        ));
        std::fs::write(scratch.paths.state_file(&scratch.id), b"{\"schema\":").unwrap();
        assert!(matches!(
            read_state(&scratch.paths, &scratch.id),
            Err(StateError::Unreadable(_))
        ));
        let mut value = serde_json::to_value(scratch.state()).unwrap();
        value["schema"] = json!(2);
        std::fs::write(
            scratch.paths.state_file(&scratch.id),
            serde_json::to_vec(&value).unwrap(),
        )
        .unwrap();
        assert!(matches!(
            read_state(&scratch.paths, &scratch.id),
            Err(StateError::Unreadable(_))
        ));
    }

    fn state_with_no_pending(mut state: State) -> State {
        state.pending_steers.clear();
        state
    }

    #[test]
    fn begin_turn_admits_only_idle_non_stopping_sessions() {
        let scratch = Scratch::new();
        let mut idle = scratch.state();
        assert!(begin_turn(&mut idle, 10));
        assert_eq!(idle.status, Status::Running);
        assert_eq!(idle.active_turn_id, None);

        let mut running = idle.clone();
        running.active_turn_id = Some("turn".into());
        let before = running.clone();
        assert!(!begin_turn(&mut running, 11));
        assert_eq!(running, before);

        let mut stopping = scratch.state();
        stopping.stopping = true;
        let before = stopping.clone();
        assert!(!begin_turn(&mut stopping, 12));
        assert_eq!(stopping, before);

        let mut dead = scratch.state();
        dead.status = Status::Dead;
        let before = dead.clone();
        assert!(!begin_turn(&mut dead, 13));
        assert_eq!(dead, before);
    }

    #[test]
    fn abort_turn_returns_a_pending_start_to_idle_only() {
        let scratch = Scratch::new();
        let mut pending = scratch.state();
        assert!(begin_turn(&mut pending, 1));
        abort_turn(&mut pending, 2);
        assert_eq!(pending.status, Status::Idle);
        assert_eq!(pending.active_turn_id, None);

        assert!(begin_turn(&mut pending, 3));
        apply_ack(&mut pending, "active", Disposition::Started, 4);
        let before = pending.clone();
        abort_turn(&mut pending, 5);
        assert_eq!(pending, before);
    }

    #[test]
    fn simultaneous_begin_turn_admits_exactly_one_caller_for_200_rounds() {
        let scratch = Scratch::new();
        let store = Arc::new(scratch.store());
        for _ in 0..200 {
            store
                .update(|state| {
                    state.status = Status::Idle;
                    state.active_turn_id = None;
                    state.stopping = false;
                    Vec::new()
                })
                .unwrap();
            let barrier = pair_barrier();
            let (tx, rx) = mpsc::channel();
            let mut handles = Vec::new();
            for _ in 0..2 {
                let store = Arc::clone(&store);
                let barrier = Arc::clone(&barrier);
                let tx = tx.clone();
                handles.push(std::thread::spawn(move || {
                    meet_pair(&barrier);
                    let mut began = false;
                    store
                        .update(|state| {
                            began = begin_turn(state, 20);
                            Vec::new()
                        })
                        .unwrap();
                    tx.send(began).unwrap();
                }));
            }
            drop(tx);
            let one = rx.recv_timeout(Duration::from_secs(4)).unwrap();
            let two = rx.recv_timeout(Duration::from_secs(4)).unwrap();
            wait_threads(handles);
            assert_eq!(usize::from(one) + usize::from(two), 1);
        }
    }

    #[test]
    fn client_fixture_replay_waits_for_turn_completed_not_status_idle() {
        let scratch = Scratch::new();
        let mut state = scratch.state();
        let logs = replay(fixture("client.jsonl"), &mut state);
        // Contract: delegate/README.md:57.
        for pair in logs.windows(2) {
            if matches!(pair[0].1, HostEvent::StatusChanged { ref status } if status == "idle") {
                assert_eq!(
                    pair[0].3.status,
                    Status::Running,
                    "statusChanged idle must not end the turn"
                );
                assert!(matches!(pair[1].1, HostEvent::TurnCompleted { .. }));
                assert_eq!(
                    pair[1].3.status,
                    Status::Idle,
                    "turn/completed ends the matching turn"
                );
            }
        }
        let cancelled = logs.iter().find(|(_, event, _, _)| matches!(event, HostEvent::TurnCompleted { terminal, .. } if terminal == "cancelled")).unwrap();
        assert_eq!(
            cancelled.3.last_turn.as_ref().unwrap().terminal,
            "cancelled"
        );
        // Contract: delegate/README.md:49.
        assert_eq!(state.turn_count, 5);
        assert_eq!(state.last_turn.as_ref().unwrap().terminal, "completed");
        assert_eq!(state.usage.total_tokens, 320_711);
        assert!(
            logs.iter()
                .flat_map(|(_, _, lines, _)| lines)
                .all(|line| line["kind"] != "steer.unconsumed")
        );
    }

    #[test]
    fn abort_race_fixture_rolls_back_queued_ack_and_starts_host_turn() {
        let scratch = Scratch::new();
        let mut state = scratch.state();
        let logs = replay(fixture("client-abort-race.jsonl"), &mut state);
        let queued_line = fixture("client-abort-race.jsonl").lines().nth(81).unwrap();
        let queued: Value = serde_json::from_str(queued_line.strip_prefix("< ").unwrap()).unwrap();
        assert_eq!(ack_disposition(&queued["result"]), Disposition::Queued);
        assert_eq!(state.status, Status::Idle);
        assert_eq!(state.active_turn_id, None);
        // Contract: delegate/README.md:49.
        assert_eq!(state.turn_count, 5);
        assert!(
            logs.iter()
                .all(|(_, _, lines, _)| lines.iter().all(|line| line["stale"] != true))
        );
        let queued = logs.iter().find(|(line, _, _, _)| *line == 82).unwrap();
        assert_eq!(queued.3.status, Status::Idle);
        let started = logs
            .iter()
            .find(|(line, event, _, _)| {
                *line == 84 && matches!(event, HostEvent::TurnStarted { .. })
            })
            .unwrap();
        assert_eq!(started.3.status, Status::Running);
        assert_eq!(
            started.3.active_turn_id.as_deref(),
            Some("01a16611-50ba-7d9d-9ec1-9e652c9de675")
        );
        for line in [105, 123] {
            let completion = logs
                .iter()
                .find(|(n, event, _, _)| {
                    *n == line && matches!(event, HostEvent::TurnCompleted { .. })
                })
                .unwrap();
            assert_eq!(completion.3.status, Status::Idle);
        }
        assert!(logs.iter().any(|(_, event, _, _)| matches!(
            event,
            HostEvent::TurnCompleted { terminal, .. } if terminal == "completed"
        )));
        assert!(logs.iter().any(|(_, event, _, _)| matches!(
            event,
            HostEvent::TurnCompleted { terminal, .. } if terminal == "cancelled"
        )));
    }

    #[test]
    fn bad_model_turn_is_failed_but_session_returns_idle() {
        let scratch = Scratch::new();
        let mut state = scratch.state();
        replay(fixture("bad-model.jsonl"), &mut state);
        assert_eq!(state.status, Status::Idle);
        let last = state.last_turn.unwrap();
        assert_eq!(last.terminal, "failed");
        assert_eq!(last.error.unwrap().kind, "modelError");
    }

    #[test]
    fn acknowledgements_and_matching_completion_resolve_the_sender_reader_race() {
        let scratch = Scratch::new();
        let mut state = scratch.state();
        assert!(begin_turn(&mut state, 10));
        assert!(apply_ack(&mut state, "turn", Disposition::Started, 11).is_empty());
        apply_event(
            &mut state,
            &HostEvent::TurnCompleted {
                turn_id: "turn".into(),
                terminal: "completed".into(),
                error: None,
            },
            12,
        );
        assert_eq!(state.status, Status::Idle);
        assert_eq!(state.active_turn_id, None);
    }

    #[test]
    fn stale_completions_log_without_changing_state() {
        let scratch = Scratch::new();
        let mut state = scratch.state();
        assert!(begin_turn(&mut state, 10));
        apply_ack(&mut state, "active", Disposition::Started, 11);
        for stale_id in ["other", ""] {
            let before = state.clone();
            let logs = apply_event(
                &mut state,
                &HostEvent::TurnCompleted {
                    turn_id: stale_id.into(),
                    terminal: "completed".into(),
                    error: None,
                },
                12,
            );
            assert_eq!(state, before);
            assert_eq!(logs[0]["stale"], true);
        }
        state.active_turn_id = None;
        state.status = Status::Idle;
        let before = state.clone();
        let logs = apply_event(
            &mut state,
            &HostEvent::TurnCompleted {
                turn_id: "orphan".into(),
                terminal: "completed".into(),
                error: None,
            },
            13,
        );
        assert_eq!(state, before);
        assert_eq!(logs[0]["stale"], true);
    }

    #[test]
    fn dead_state_absorbs_frames_acks_and_new_turns() {
        // Contract: delegate/README.md:58.
        let scratch = Scratch::new();
        let mut state = scratch.state();
        assert!(begin_turn(&mut state, 10));
        apply_ack(&mut state, "turn", Disposition::Started, 11);
        mark_dead(&mut state, DeadReason::Stopped, None, "stopped", 12);
        assert_eq!(state.status, Status::Dead);
        assert_eq!(state.active_turn_id, None);
        let before = state.clone();
        assert!(
            apply_event(
                &mut state,
                &HostEvent::TurnCompleted {
                    turn_id: "turn".into(),
                    terminal: "cancelled".into(),
                    error: None
                },
                13,
            )
            .is_empty()
        );
        assert!(
            apply_event(
                &mut state,
                &HostEvent::TurnStarted {
                    turn_id: "new".into()
                },
                14
            )
            .is_empty()
        );
        assert!(apply_ack(&mut state, "new", Disposition::Started, 15).is_empty());
        assert!(!begin_turn(&mut state, 16));
        assert_eq!(state, before);
    }

    #[test]
    fn queued_steered_and_unknown_ack_dispositions_roll_back_pending_turns() {
        let scratch = Scratch::new();
        for disposition in [
            Disposition::Queued,
            Disposition::Steered,
            Disposition::Other,
        ] {
            let mut state = scratch.state();
            assert!(begin_turn(&mut state, 1));
            let lines = apply_ack(&mut state, "turn", disposition, 2);
            assert_eq!(state.status, Status::Idle);
            assert_eq!(state.active_turn_id, None);
            // Contract: delegate/README.md:49.
            assert_eq!(state.turn_count, 0);
            assert_eq!(lines[0]["kind"], "ack.unexpected");
        }
    }

    #[test]
    fn turn_started_after_queued_ack_counts_the_host_turn_once() {
        let scratch = Scratch::new();
        let mut state = scratch.state();
        assert!(begin_turn(&mut state, 1));
        let lines = apply_ack(&mut state, "queued-turn", Disposition::Queued, 2);
        assert_eq!(state.status, Status::Idle);
        // Contract: delegate/README.md:49.
        assert_eq!(state.turn_count, 0);
        assert_eq!(lines[0]["kind"], "ack.unexpected");
        apply_event(
            &mut state,
            &HostEvent::TurnStarted {
                turn_id: "actual-turn".into(),
            },
            3,
        );
        assert_eq!(state.status, Status::Running);
        assert_eq!(state.active_turn_id.as_deref(), Some("actual-turn"));
        // Contract: delegate/README.md:49.
        assert_eq!(state.turn_count, 1);
    }

    #[test]
    fn mark_dead_keeps_first_reason_and_message() {
        // Contract: delegate/README.md:58.
        let scratch = Scratch::new();
        let mut state = scratch.state();
        mark_dead(&mut state, DeadReason::Stopped, Some(7), "first", 20);
        let dead = state.dead.clone();
        mark_dead(&mut state, DeadReason::HostExited, Some(9), "second", 21);
        assert_eq!(state.dead, dead);
        assert_eq!(state.dead.unwrap().message, "first");
    }

    #[test]
    fn pending_steers_are_consumed_or_reported_at_completion() {
        let scratch = Scratch::new();
        let mut state = scratch.state();
        assert!(begin_turn(&mut state, 1));
        apply_ack(&mut state, "turn", Disposition::Started, 2);
        note_steer(&mut state, "cmd");
        apply_event(
            &mut state,
            &HostEvent::UserMessage {
                turn_id: "turn".into(),
                text: "steer".into(),
                command_id: Some("cmd".into()),
            },
            3,
        );
        assert!(state.pending_steers.is_empty());
        let logs = apply_event(
            &mut state,
            &HostEvent::TurnCompleted {
                turn_id: "turn".into(),
                terminal: "completed".into(),
                error: None,
            },
            4,
        );
        // Contract: delegate/README.md:54.
        assert_eq!(logs.len(), 1);

        assert!(begin_turn(&mut state, 5));
        apply_ack(&mut state, "turn-2", Disposition::Started, 6);
        note_steer(&mut state, "unread");
        let logs = apply_event(
            &mut state,
            &HostEvent::TurnCompleted {
                turn_id: "turn-2".into(),
                terminal: "completed".into(),
                error: None,
            },
            7,
        );
        // Contract: delegate/README.md:54.
        assert_eq!(logs.len(), 2);
        assert_eq!(logs[1]["kind"], "steer.unconsumed");
        assert_eq!(logs[1]["commandIds"], json!(["unread"]));
        assert!(state.pending_steers.is_empty());
    }

    #[test]
    fn steer_user_message_can_arrive_before_ack_and_rejected_steer_drops_pending() {
        let scratch = Scratch::new();
        let mut state = scratch.state();
        assert!(begin_turn(&mut state, 1));
        apply_ack(&mut state, "turn", Disposition::Started, 2);
        note_steer(&mut state, "early");
        apply_event(
            &mut state,
            &HostEvent::UserMessage {
                turn_id: "turn".into(),
                text: "early".into(),
                command_id: Some("early".into()),
            },
            3,
        );
        assert!(state.pending_steers.is_empty());
        let logs = apply_event(
            &mut state,
            &HostEvent::TurnCompleted {
                turn_id: "turn".into(),
                terminal: "completed".into(),
                error: None,
            },
            4,
        );
        // Contract: delegate/README.md:54.
        assert_eq!(logs.len(), 1);

        assert!(begin_turn(&mut state, 5));
        apply_ack(&mut state, "next", Disposition::Started, 6);
        note_steer(&mut state, "rejected");
        drop_steer(&mut state, "rejected");
        let logs = apply_event(
            &mut state,
            &HostEvent::TurnCompleted {
                turn_id: "next".into(),
                terminal: "completed".into(),
                error: None,
            },
            7,
        );
        // Contract: delegate/README.md:54.
        assert_eq!(logs.len(), 1);
    }

    #[test]
    fn paths_enforce_the_socket_length_boundary() {
        let id = "00000000-0000-4000-8000-000000000000";
        let at_limit = Paths::new(PathBuf::from(format!("/{}", "r".repeat(57))));
        assert_eq!(
            at_limit
                .socket_path(id)
                .unwrap()
                .as_os_str()
                .as_encoded_bytes()
                .len(),
            100
        );
        let under_limit = Paths::new(PathBuf::from(format!("/{}", "r".repeat(56))));
        assert!(under_limit.socket_path(id).is_ok());
        let over_limit = Paths::new(PathBuf::from(format!("/{}", "r".repeat(58))));
        let error = over_limit.socket_path(id).unwrap_err().to_string();
        assert!(error.contains("100"));
    }

    #[test]
    fn state_and_session_file_modes_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let scratch = Scratch::new();
        let dir = create_session_dir(&scratch.paths, &scratch.id).unwrap();
        assert_eq!(
            std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        write_state(&scratch.paths, &scratch.state()).unwrap();
        assert_eq!(
            std::fs::metadata(scratch.paths.state_file(&scratch.id))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let store = Store::open(scratch.paths.clone(), scratch.state()).unwrap();
        assert_eq!(
            std::fs::metadata(scratch.paths.events_file(&scratch.id))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        store.update(|_| vec![json!({"kind":"test"})]).unwrap();
        assert!(std::fs::read_dir(dir).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp")
        }));
    }

    #[test]
    fn store_commits_state_before_logs_under_one_lock() {
        let scratch = Scratch::new();
        let store = Arc::new(scratch.store());
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (a_done_tx, a_done_rx) = mpsc::channel();
        let a_store = Arc::clone(&store);
        let a = std::thread::spawn(move || {
            a_store
                .update(|state| {
                    state.cwd = "/committed-by-a".into();
                    entered_tx.send(()).unwrap();
                    release_rx
                        .recv_timeout(Duration::from_secs(4))
                        .expect("release deadline");
                    vec![json!({"kind":"a"})]
                })
                .unwrap();
            a_done_tx.send(()).unwrap();
        });
        entered_rx.recv_timeout(Duration::from_secs(3)).unwrap();

        let (attempt_tx, attempt_rx) = mpsc::channel();
        let (continue_tx, continue_rx) = mpsc::channel();
        let (b_entered_tx, b_entered_rx) = mpsc::channel();
        let b_store = Arc::clone(&store);
        let paths = scratch.paths.clone();
        let id = scratch.id.clone();
        let b = std::thread::spawn(move || {
            assert!(matches!(
                b_store.inner.try_lock(),
                Err(std::sync::TryLockError::WouldBlock)
            ));
            attempt_tx.send(()).unwrap();
            continue_rx
                .recv_timeout(Duration::from_secs(4))
                .expect("release lock-attempt pause");
            b_store
                .update(|_| {
                    a_done_rx
                        .recv_timeout(Duration::from_secs(4))
                        .expect("A returned from its update");
                    let disk = read_state(&paths, &id).unwrap();
                    // Contract: delegate/README.md:50.
                    assert_eq!(disk.cwd, "/committed-by-a");
                    b_entered_tx.send(()).unwrap();
                    vec![json!({"kind":"b"})]
                })
                .unwrap();
        });
        attempt_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        continue_tx.send(()).unwrap();
        release_tx.send(()).unwrap();
        b_entered_rx.recv_timeout(Duration::from_secs(4)).unwrap();
        wait_threads(vec![a, b]);
    }

    #[test]
    fn store_updates_remain_atomic_with_ordered_gap_free_sequences() {
        let scratch = Scratch::new();
        let store = Arc::new(scratch.store());
        let noop: Arc<dyn Fn() + Send + Sync> = Arc::new(|| {});
        let handles = run_tick_workers(&store, TICKS_PER_WORKER, noop);
        wait_threads(handles);
        assert_tick_log(&scratch, &store, 2 * TICKS_PER_WORKER);
    }

    #[test]
    fn worker_deadline_trips_on_held_update_while_sequence_property_holds() {
        let scratch = Scratch::new();
        let store = Arc::new(scratch.store());
        let (release_tx, release_rx) = mpsc::channel();
        let holder: Arc<Mutex<Option<mpsc::Receiver<()>>>> = Arc::new(Mutex::new(Some(release_rx)));
        // The hook runs inside the update closure under the store lock, so the
        // first update to reach it holds both workers until the release send.
        let hook: Arc<dyn Fn() + Send + Sync> = Arc::new({
            let holder = Arc::clone(&holder);
            move || {
                if let Some(rx) = holder
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .take()
                {
                    rx.recv_timeout(Duration::from_secs(4))
                        .expect("release deadline");
                }
            }
        });
        let handles = run_tick_workers(&store, TICKS_PER_WORKER, hook);
        let tripped = !threads_finish_within(&handles, Duration::from_millis(50));
        let _ = release_tx.send(());
        wait_threads(handles);
        assert!(tripped);
        assert_tick_log(&scratch, &store, 2 * TICKS_PER_WORKER);
    }

    #[test]
    fn reduced_tick_workload_stays_inside_the_guard_at_controlled_update_latency() {
        let scratch = Scratch::new();
        let store = Arc::new(scratch.store());
        // The sleep runs inside the update closure under the store lock, so
        // the 80 sleeps serialise: at least 800 ms, far inside the 5 s guard.
        let hook: Arc<dyn Fn() + Send + Sync> =
            Arc::new(|| std::thread::sleep(SLOW_UPDATE_LATENCY));
        let handles = run_tick_workers(&store, TICKS_PER_WORKER, hook);
        wait_threads(handles);
        assert_tick_log(&scratch, &store, 2 * TICKS_PER_WORKER);
    }

    #[test]
    fn failed_state_write_leaves_memory_log_and_sequence_unchanged() {
        use std::os::unix::fs::PermissionsExt;
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let scratch = Scratch::new();
        let store = scratch.store();
        store.update(|_| vec![json!({"kind":"before"})]).unwrap();
        let before = store.snapshot();
        let events_before =
            std::fs::read_to_string(scratch.paths.events_file(&scratch.id)).unwrap();
        let dir = scratch.paths.dir(&scratch.id);
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
        let failed = store.update(|state| {
            state.cwd = "/must-not-commit".into();
            vec![json!({"kind":"failed"})]
        });
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(failed.is_err());
        assert_eq!(store.snapshot(), before);
        assert_eq!(
            std::fs::read_to_string(scratch.paths.events_file(&scratch.id)).unwrap(),
            events_before
        );
        store
            .update(|state| {
                state.cwd = "/committed".into();
                vec![json!({"kind":"after"})]
            })
            .unwrap();
        let events = std::fs::read_to_string(scratch.paths.events_file(&scratch.id)).unwrap();
        let last: Value = serde_json::from_str(events.lines().last().unwrap()).unwrap();
        // Contract: delegate/README.md:50.
        assert_eq!(last["seq"], json!(2));
    }

    #[test]
    fn panicking_update_does_not_poison_or_commit_the_store() {
        let scratch = Scratch::new();
        let store = scratch.store();
        let before = store.snapshot();
        let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = store.update(|state| {
                state.cwd = "/uncommitted".into();
                panic!("test panic inside transaction");
            });
        }));
        assert!(panic.is_err());
        assert_eq!(store.snapshot(), before);
        store
            .update(|state| {
                state.cwd = "/committed".into();
                Vec::new()
            })
            .unwrap();
        assert_eq!(
            store
                .wait_until(|state| state.cwd == "/committed", Duration::from_secs(1))
                .unwrap()
                .cwd,
            "/committed"
        );
    }

    #[test]
    fn dead_supervisor_settle_handles_missing_live_and_starting_pids() {
        let scratch = Scratch::new();
        let id = scratch.id.clone();
        create_session_dir(&scratch.paths, &id).unwrap();
        let mut child = Command::new("sh").args(["-c", "exit 0"]).spawn().unwrap();
        let dead_pid = child.id() as i32;
        finish_child(&mut child);
        let mut dead = scratch.state();
        dead.supervisor_pid = Some(dead_pid);
        dead.host_pid = Some(1);
        write_state(&scratch.paths, &dead).unwrap();
        let settled = settle_dead_supervisor(&scratch.paths, &id, 2000)
            .unwrap()
            .unwrap();
        assert_eq!(settled.status, Status::Dead);
        assert_eq!(
            settled.dead.as_ref().unwrap().reason,
            DeadReason::SupervisorDied
        );
        assert_eq!(
            settle_dead_supervisor(&scratch.paths, &id, 2001).unwrap(),
            None
        );

        let live_id = crate::util::random_uuid();
        let mut live = new_state(&live_id, "muse/m", "/work", "/inbox", 1000);
        live.supervisor_pid = Some(std::process::id() as i32);
        create_session_dir(&scratch.paths, &live_id).unwrap();
        write_state(&scratch.paths, &live).unwrap();
        assert_eq!(
            settle_dead_supervisor(&scratch.paths, &live_id, 2000).unwrap(),
            None
        );

        let starting_id = crate::util::random_uuid();
        let mut starting = new_state(&starting_id, "muse/m", "/work", "/inbox", 1000);
        starting.started_at = 5000;
        create_session_dir(&scratch.paths, &starting_id).unwrap();
        write_state(&scratch.paths, &starting).unwrap();
        assert_eq!(
            settle_dead_supervisor(&scratch.paths, &starting_id, 5000 + STARTING_GRACE_MS).unwrap(),
            None
        );
        let too_old =
            settle_dead_supervisor(&scratch.paths, &starting_id, 5000 + STARTING_GRACE_MS + 1)
                .unwrap()
                .unwrap();
        assert_eq!(too_old.status, Status::Dead);
        assert_eq!(too_old.dead.unwrap().reason, DeadReason::StartFailed);

        let already_id = crate::util::random_uuid();
        let mut already = new_state(&already_id, "muse/m", "/work", "/inbox", 0);
        mark_dead(&mut already, DeadReason::Stopped, None, "stopped", 1);
        create_session_dir(&scratch.paths, &already_id).unwrap();
        write_state(&scratch.paths, &already).unwrap();
        assert_eq!(
            settle_dead_supervisor(&scratch.paths, &already_id, STARTING_GRACE_MS + 2).unwrap(),
            None
        );
    }

    #[test]
    fn corrupt_supervisor_pids_settle_without_reaping() {
        let scratch = Scratch::new();
        let mut host = group_shell(Some("serve"), true);
        let host_pid = host.id() as i32;
        for pid in [0, 1] {
            let id = crate::util::random_uuid();
            let mut state = new_state(&id, "muse/m", "/work", "/inbox", 0);
            state.supervisor_pid = Some(pid);
            state.host_pid = Some(host_pid);
            create_session_dir(&scratch.paths, &id).unwrap();
            write_state(&scratch.paths, &state).unwrap();
            let settled = settle_dead_supervisor(&scratch.paths, &id, 1)
                .unwrap()
                .unwrap();
            assert_eq!(settled.status, Status::Dead);
            assert_eq!(
                settled.dead.as_ref().unwrap().reason,
                DeadReason::SupervisorDied
            );
            assert_eq!(settled.dead.unwrap().message, "corrupt supervisorPid");
            assert!(
                host.try_wait().unwrap().is_none(),
                "corrupt supervisor pid reaped its host"
            );
        }
        for pid in [0, 1, -5] {
            reap_host(pid);
            assert!(
                host.try_wait().unwrap().is_none(),
                "invalid host pid signalled the valid host group"
            );
        }
        unsafe { libc::kill(-(host.id() as i32), libc::SIGKILL) };
        finish_child(&mut host);
    }

    #[test]
    fn host_guard_requires_every_exact_argv_token_and_reaps_only_matching_groups() {
        let argv = crate::session::msp::host_argv("x");
        assert!(is_host_command(&argv.join(" ")));
        for missing in 0..argv.len() {
            let command = argv
                .iter()
                .enumerate()
                .filter_map(|(i, token)| (i != missing).then_some(token.as_str()))
                .collect::<Vec<_>>()
                .join(" ");
            assert!(
                !is_host_command(&command),
                "accepted argv with token removed: {missing}"
            );
        }
        assert!(!is_host_command(
            "sh -c 'sleep 30; :' observe --provider meta --model x --disable-sandbox"
        ));
        assert!(!is_host_command(
            "sh -c 'sleep 30; :' preserve --provider meta --model x --disable-sandbox"
        ));

        let mut host = ready_group_shell(Some("serve"), true);
        reap_host(host.id() as i32);
        finish_child(&mut host);

        for (label, with_host_tokens) in [
            (None, false),
            (Some("observe"), true),
            (Some("preserve"), true),
        ] {
            let mut unrelated = ready_group_shell(label, with_host_tokens);
            reap_host(unrelated.id() as i32);
            assert!(
                unrelated.try_wait().unwrap().is_none(),
                "unrelated process group was reaped"
            );
            unsafe { libc::kill(-(unrelated.id() as i32), libc::SIGKILL) };
            finish_child(&mut unrelated);
        }
    }

    #[test]
    fn list_sorts_sessions_and_reports_corrupt_state_but_skips_invalid_ids() {
        let scratch = Scratch::new();
        let mut states = Vec::new();
        for started_at in [30, 10, 10] {
            let id = crate::util::random_uuid();
            let mut state = new_state(&id, "muse/m", "/work", "/inbox", started_at);
            state.started_at = started_at;
            create_session_dir(&scratch.paths, &id).unwrap();
            write_state(&scratch.paths, &state).unwrap();
            states.push(state);
        }
        let unreadable_id = crate::util::random_uuid();
        let dir = create_session_dir(&scratch.paths, &unreadable_id).unwrap();
        std::fs::write(dir.join("state.json"), b"not json").unwrap();
        std::fs::create_dir_all(scratch.paths.root.join("not-an-id")).unwrap();
        let entries = list(&scratch.paths, 0);
        let ordered: Vec<_> = entries
            .iter()
            .filter_map(|entry| match entry {
                ListEntry::Session(state) => Some((state.started_at, state.id.clone())),
                _ => None,
            })
            .collect();
        let mut expected: Vec<_> = states
            .iter()
            .map(|state| (state.started_at, state.id.clone()))
            .collect();
        expected.sort();
        // Contract: delegate/README.md:52.
        assert_eq!(ordered, expected);
        assert!(
            entries
                .iter()
                .any(|entry| matches!(entry, ListEntry::Unreadable { id } if id == &unreadable_id))
        );
        assert!(
            !entries
                .iter()
                .any(|entry| matches!(entry, ListEntry::Unreadable { id } if id == "not-an-id"))
        );
    }
}
