//! Supervised hub client for the Fiber door (see #682).
//!
//! A program that drives sessions is a client of the hub: it connects to
//! `<FIBER_HOME>/run/hub`, starts a supervised session, drives it with the
//! driver commands and ends it with `close`, reading `fiber_exited` as the
//! verdict. Every read on the socket is a plain blocking read: no timeout,
//! no poll loop and no second thread.

use super::super::types::{BackendResult, Event, EventFn, ProgressSnapshotRaw};
use super::{finish, handle_line};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

/// A socket path is limited to 103 bytes on macOS.
const MAX_SOCKET_PATH: usize = 103;

/// Fixed closing sentence on every error text the client builds, so no text
/// the client builds ever ends in a hub or model `STATUS:` line.
const FIXED: &str = "The delegate hub client ended the run with an error.";

fn crash_text(body: String) -> String {
    format!("{body}\n{FIXED}")
}

/// What went wrong reading one hub line: EOF or a read error means the
/// connection is lost. Hub lines carry no cap, only client lines do: the hub
/// is local, so a line is read to its newline whatever its size.
#[derive(Debug, PartialEq)]
enum ReadErr {
    Lost(String),
}

/// Read one newline-terminated hub line, keeping partial bytes across reads.
fn read_line<R: BufRead>(reader: &mut R) -> Result<Vec<u8>, ReadErr> {
    enum Next {
        Done(usize),
        More(usize),
    }
    let mut line = Vec::new();
    loop {
        let next = {
            let buf = reader
                .fill_buf()
                .map_err(|e| ReadErr::Lost(e.to_string()))?;
            if buf.is_empty() {
                return Err(ReadErr::Lost("connection closed".to_string()));
            }
            match buf.iter().position(|&b| b == b'\n') {
                Some(nl) => {
                    line.extend_from_slice(&buf[..nl]);
                    Next::Done(nl + 1)
                }
                None => {
                    line.extend_from_slice(buf);
                    Next::More(buf.len())
                }
            }
        };
        match next {
            Next::Done(n) => {
                reader.consume(n);
                return Ok(line);
            }
            Next::More(n) => reader.consume(n),
        }
    }
}

/// Write one whole newline JSON command line.
fn write_line<W: Write>(writer: &mut W, line: &str) -> std::io::Result<()> {
    writer.write_all(line.as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()
}

/// First 80 bytes of a line, for `protocol error` crash texts.
fn first80(raw: &[u8]) -> String {
    String::from_utf8_lossy(&raw[..raw.len().min(80)]).into_owned()
}

/// An open hub connection: the reader owns the socket, the writer is a
/// clone of it. Reads and writes stay on the one calling thread.
#[derive(Debug)]
struct HubConn {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
}

/// Connect to the hub socket, read `hub_hello` and return the connection
/// with the hub's `fiber_version`.
fn connect(socket_path: &Path) -> Result<(HubConn, String), String> {
    let show = socket_path.display().to_string();
    let stream = UnixStream::connect(socket_path)
        .map_err(|e| crash_text(format!("cannot connect to hub socket {show}: {e}")))?;
    let writer = stream
        .try_clone()
        .map_err(|e| crash_text(format!("cannot clone hub socket {show}: {e}")))?;
    let mut conn = HubConn {
        reader: BufReader::new(stream),
        writer,
    };
    let raw = read_line(&mut conn.reader).map_err(|e| match e {
        ReadErr::Lost(detail) => crash_text(format!("cannot read hub_hello from {show}: {detail}")),
    })?;
    let hello: serde_json::Value = serde_json::from_slice(&raw).map_err(|_| {
        crash_text(format!(
            "protocol error: first hub line is not JSON: {}",
            first80(&raw)
        ))
    })?;
    let kind = hello.get("kind").and_then(|k| k.as_str()).unwrap_or("");
    if kind != "hub_hello" {
        return Err(crash_text(format!(
            "protocol error: first hub line is not hub_hello (kind {kind:?}): {}",
            first80(&raw)
        )));
    }
    let version = hello.get("schema_version");
    if version.and_then(|v| v.as_i64()) != Some(1) {
        let seen = version
            .map(|v| v.to_string())
            .unwrap_or_else(|| "missing".to_string());
        let fiber_version = hello_fiber_version(&hello);
        return Err(crash_text(format!(
            "the hub speaks schema_version {seen}; delegate reads 1; fiber_version {fiber_version}"
        )));
    }
    Ok((conn, hello_fiber_version(&hello).to_string()))
}

fn hello_fiber_version(hello: &serde_json::Value) -> &str {
    hello
        .get("payload")
        .and_then(|p| p.get("fiber_version"))
        .and_then(|v| v.as_str())
        .or_else(|| hello.get("fiber_version").and_then(|v| v.as_str()))
        .unwrap_or("unknown")
}

/// `FIBER_HOME` when it is set and absolute, `<homedir>/.fiber` when it is
/// unset. An empty, relative or non-UTF-8 value is an error naming
/// `FIBER_HOME`, with no `~/.fiber` fallback. Read with `var_os`, so a
/// non-UTF-8 value is the error and never reads as unset.
pub fn fiber_home() -> Result<PathBuf, String> {
    match std::env::var_os("FIBER_HOME") {
        None => Ok(crate::util::homedir().join(".fiber")),
        Some(v) if v.is_empty() => {
            Err("FIBER_HOME is set but empty; set it to an absolute path or unset it".to_string())
        }
        Some(v) => {
            let path = PathBuf::from(&v);
            if path.is_absolute() {
                Ok(path)
            } else {
                Err(format!(
                    "FIBER_HOME is relative ({}); set it to an absolute path or unset it",
                    v.to_string_lossy()
                ))
            }
        }
    }
}

/// `<fiber_home>/run/hub`, failing when the socket path passes the
/// 103-byte limit macOS sets.
pub fn hub_socket_path(fiber_home: &Path) -> Result<PathBuf, String> {
    let path = fiber_home.join("run/hub");
    let len = path.to_string_lossy().len();
    if len > MAX_SOCKET_PATH {
        return Err(format!(
            "FIBER_HOME socket path is {len} bytes, over the 103-byte limit: {}",
            path.display()
        ));
    }
    Ok(path)
}

/// A client-minted command id: `c_` plus 16 lowercase hex from
/// `random_uuid`. A collision between two ids in one run is accepted.
fn new_command_id() -> String {
    let hex: String = crate::util::random_uuid()
        .chars()
        .filter(|c| *c != '-')
        .take(16)
        .collect();
    format!("c_{hex}")
}

/// Exact driver-command bytes. `start` carries no `session_id` and no
/// content; `subscribe`, `prompt` and `close` name the session. No `cancel`
/// or `reply` builder exists: the client never sends them.
fn start_command(id: &str, workspace: &str, model: &str) -> String {
    serde_json::json!({
        "id": id,
        "command": "start",
        "args": {"workspace": workspace, "model": model, "supervised": true},
    })
    .to_string()
}

fn subscribe_command(id: &str, session_id: &str) -> String {
    serde_json::json!({
        "id": id,
        "command": "subscribe",
        "session_id": session_id,
        "args": {"level": "full"},
    })
    .to_string()
}

fn prompt_command(id: &str, session_id: &str, prompt: &str) -> String {
    serde_json::json!({
        "id": id,
        "command": "prompt",
        "session_id": session_id,
        "args": {"content": [{"type": "text", "text": prompt}]},
    })
    .to_string()
}

fn close_command(id: &str, session_id: &str) -> String {
    serde_json::json!({
        "id": id,
        "command": "close",
        "session_id": session_id,
    })
    .to_string()
}

fn close_now_command(id: &str, session_id: &str) -> String {
    serde_json::json!({
        "id": id,
        "command": "close",
        "session_id": session_id,
        "args": {"now": true},
    })
    .to_string()
}

/// The hub's answer to one awaited command.
#[derive(Debug)]
enum Ack {
    Accepted { result: serde_json::Value },
    Rejected { code: String, message: String },
}

/// What one handler step decides: keep reading, send `close` once, end the
/// run, or crash it. `Fail` already holds the final crash text and runs the
/// `close now` cleanup when a session is open; `FailQuiet` never cleans up.
#[derive(Debug)]
enum Step {
    Continue,
    CloseOnce,
    End(BackendResult),
    Fail(String),
    FailQuiet(String),
}

/// Why waiting for an answer stopped: the answer, a handler stop, or a lost
/// connection. A loss names the wait it was in by context: the start id when
/// the `start` is unanswered, the session id after it.
#[derive(Debug)]
enum WaitOutcome {
    Ack(Ack),
    Stopped(Step),
    Lost,
}

impl HubConn {
    fn send(&mut self, line: &str) -> std::io::Result<()> {
        write_line(&mut self.writer, line)
    }

    /// Read until a `command_accepted` or `command_rejected` whose
    /// `payload.command_id` equals `id`. Every other line passes to
    /// `on_other` in arrival order, so no line is lost while waiting.
    fn await_ack(
        &mut self,
        id: &str,
        mut on_other: impl FnMut(&[u8]) -> Option<Step>,
    ) -> WaitOutcome {
        loop {
            let raw = match read_line(&mut self.reader) {
                Ok(raw) => raw,
                Err(ReadErr::Lost(_)) => return WaitOutcome::Lost,
            };
            let parsed: serde_json::Value = match serde_json::from_slice(&raw) {
                Ok(v) => v,
                Err(_) => {
                    if let Some(stop) = on_other(&raw) {
                        return WaitOutcome::Stopped(stop);
                    }
                    continue;
                }
            };
            let kind = parsed.get("kind").and_then(|k| k.as_str()).unwrap_or("");
            if kind != "command_accepted" && kind != "command_rejected" {
                if let Some(stop) = on_other(&raw) {
                    return WaitOutcome::Stopped(stop);
                }
                continue;
            }
            let cid = parsed
                .get("payload")
                .and_then(|p| p.get("command_id"))
                .and_then(|c| c.as_str());
            let Some(cid) = cid else {
                return WaitOutcome::Stopped(Step::Fail(crash_text(format!(
                    "protocol error: hub answer without command_id: {}",
                    first80(&raw)
                ))));
            };
            if cid != id {
                return WaitOutcome::Stopped(Step::Fail(crash_text(format!(
                    "protocol error: hub answer for unknown command {cid}"
                ))));
            }
            if kind == "command_accepted" {
                let result = parsed
                    .get("payload")
                    .and_then(|p| p.get("result"))
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                return WaitOutcome::Ack(Ack::Accepted { result });
            }
            let code = parsed
                .get("payload")
                .and_then(|p| p.get("code"))
                .and_then(|c| c.as_str())
                .unwrap_or("unknown")
                .to_string();
            let message = parsed
                .get("payload")
                .and_then(|p| p.get("message"))
                .and_then(|m| m.as_str())
                .unwrap_or("")
                .to_string();
            return WaitOutcome::Ack(Ack::Rejected { code, message });
        }
    }
}

/// The `session_id` a `start` answer carries. Anything else is a crash:
/// without a session the run cannot continue.
fn start_session(result: &serde_json::Value) -> Result<String, String> {
    match result
        .get("session_id")
        .and_then(|s| s.as_str())
        .filter(|s| !s.is_empty())
    {
        Some(s) => Ok(s.to_string()),
        None => Err(crash_text(
            "protocol error: start accepted with no session_id".to_string(),
        )),
    }
}

/// The fold point a `subscribe` answer carries, when it carries a numeric
/// one. A missing or non-numeric `last_seq` means every later line is live.
fn last_seq_of(result: &serde_json::Value) -> Option<u64> {
    result.get("last_seq")?.as_u64()
}

/// One supervised turn through the hub: connect, `start` with
/// `supervised: true`, `subscribe` at `full`, one `prompt`, read to
/// `turn_completed`, `close`, read `fiber_exited` as the verdict. There is
/// no `bin` field: nothing here spawns anything.
pub struct HubRequest {
    pub cwd: String,
    pub model: String,
    pub prompt: String,
}

/// Drive one supervised turn to a verdict. The client sends `prompt` itself
/// so it knows the command id C, never answers an approval, and ends the
/// session with `close`, reading `fiber_exited` as the verdict.
pub fn run_turn(req: &HubRequest, socket: &Path, on: EventFn<'_>) -> BackendResult {
    let model = super::model_reference(&req.model).to_string();
    let (mut conn, _) = match connect(socket) {
        Ok(ok) => ok,
        Err(text) => return crash_result(None, Vec::new(), text),
    };
    let mut rest = Rest::new(on);
    // start: no session_id, no content, supervised.
    let start_id = new_command_id();
    if conn
        .send(&start_command(&start_id, &req.cwd, &model))
        .is_err()
    {
        return rest.crash(lost_before_start_text(&start_id));
    }
    rest.start_id = start_id.clone();
    let session_id = match conn.await_ack(&start_id, |raw| as_history(&mut rest, raw)) {
        WaitOutcome::Ack(Ack::Accepted { result }) => match start_session(&result) {
            Ok(session_id) => session_id,
            Err(text) => return rest.crash(text),
        },
        WaitOutcome::Ack(Ack::Rejected { code, message }) => {
            return rest.crash(crash_text(format!("hub rejected start: {code}: {message}")));
        }
        WaitOutcome::Stopped(step) => {
            if let Some(done) = apply_step(&mut conn, &mut rest, step) {
                return done;
            }
            return rest.crash(crash_text(
                "protocol error: start wait stopped without an answer".to_string(),
            ));
        }
        WaitOutcome::Lost => return rest.crash(lost_before_start_text(&start_id)),
    };
    rest.session_id = Some(session_id.clone());
    // subscribe at full.
    let sub_id = new_command_id();
    if conn.send(&subscribe_command(&sub_id, &session_id)).is_err() {
        return rest.crash(lost_text(&session_id));
    }
    rest.sub_id = sub_id.clone();
    match conn.await_ack(&sub_id, |raw| as_history(&mut rest, raw)) {
        WaitOutcome::Ack(Ack::Accepted { result }) => {
            rest.last_seq = last_seq_of(&result);
        }
        WaitOutcome::Ack(Ack::Rejected { code, message }) => {
            return fail_with_cleanup(
                &mut conn,
                &mut rest,
                crash_text(format!("hub rejected subscribe: {code}: {message}")),
            );
        }
        WaitOutcome::Stopped(step) => {
            if let Some(done) = apply_step(&mut conn, &mut rest, step) {
                return done;
            }
            return fail_with_cleanup(
                &mut conn,
                &mut rest,
                crash_text("protocol error: subscribe wait stopped without an answer".to_string()),
            );
        }
        WaitOutcome::Lost => return rest.crash(lost_text(&session_id)),
    }
    // prompt with the client-minted id C.
    let prompt_id = new_command_id();
    if conn
        .send(&prompt_command(&prompt_id, &session_id, &req.prompt))
        .is_err()
    {
        return rest.crash(lost_text(&session_id));
    }
    rest.prompt_id = prompt_id.clone();
    match conn.await_ack(&prompt_id, |raw| as_live(&mut rest, raw)) {
        WaitOutcome::Ack(Ack::Accepted { .. }) => {}
        WaitOutcome::Ack(Ack::Rejected { code, message }) => {
            return fail_with_cleanup(
                &mut conn,
                &mut rest,
                crash_text(format!("hub rejected prompt: {code}: {message}")),
            );
        }
        WaitOutcome::Stopped(step) => {
            if let Some(done) = apply_step(&mut conn, &mut rest, step) {
                return done;
            }
            return fail_with_cleanup(
                &mut conn,
                &mut rest,
                crash_text("protocol error: prompt wait stopped without an answer".to_string()),
            );
        }
        WaitOutcome::Lost => return rest.crash(lost_text(&session_id)),
    }
    // Read to the verdict, which stops the run at once.
    loop {
        let raw = match read_line(&mut conn.reader) {
            Ok(raw) => raw,
            Err(ReadErr::Lost(_)) => return rest.crash(lost_text(&session_id)),
        };
        let step = rest.handle_live(&raw);
        if let Some(done) = apply_step(&mut conn, &mut rest, step) {
            return done;
        }
    }
}

/// The run's fold and gate state. The connection stays outside, so the ack
/// handlers can borrow both without aliasing.
struct Rest<'a> {
    state: super::FiberState,
    on: EventFn<'a>,
    session_id: Option<String>,
    start_id: String,
    sub_id: String,
    prompt_id: String,
    close_id: Option<String>,
    closed: bool,
    last_seq: Option<u64>,
    turn_started: bool,
    completed_ok: bool,
    bad_outcome: Option<String>,
    questions: Option<String>,
}

impl<'a> Rest<'a> {
    fn new(on: EventFn<'a>) -> Self {
        Rest {
            state: super::FiberState::default(),
            on,
            session_id: None,
            start_id: String::new(),
            sub_id: String::new(),
            prompt_id: String::new(),
            close_id: None,
            closed: false,
            last_seq: None,
            turn_started: false,
            completed_ok: false,
            bad_outcome: None,
            questions: None,
        }
    }

    fn crash(&mut self, text: String) -> BackendResult {
        crash_result(self.session_id.clone(), self.state.denial_list(), text)
    }

    /// Lines read while waiting for the `start` and `subscribe` acks are
    /// history and dropped. They still pass the JSON and kind check, and a
    /// repository offer is never dropped as history.
    fn handle_history(&mut self, raw: &[u8]) -> Step {
        let (kind, _) = match parse_line(raw) {
            Ok(parsed) => parsed,
            Err(text) => return Step::Fail(text),
        };
        if kind == "repository_code_offered" {
            return Step::Fail(repository_offer_text());
        }
        Step::Continue
    }

    /// Lines read once the fold point is known.
    fn handle_live(&mut self, raw: &[u8]) -> Step {
        let (kind, value) = match parse_line(raw) {
            Ok(parsed) => parsed,
            Err(text) => return Step::Fail(text),
        };
        match kind.as_str() {
            "repository_code_offered" => Step::Fail(repository_offer_text()),
            "command_accepted" => match accepted_id(&value) {
                None => Step::Fail(crash_text(format!(
                    "protocol error: hub answer without command_id: {}",
                    first80(raw)
                ))),
                Some(cid) if self.close_id.as_deref() == Some(cid) => Step::Continue,
                Some(cid) => Step::Fail(crash_text(format!(
                    "protocol error: hub answer for unknown command {cid}"
                ))),
            },
            "command_rejected" => {
                let payload = value.get("payload");
                let cid = payload
                    .and_then(|p| p.get("command_id"))
                    .and_then(|c| c.as_str());
                let code = payload
                    .and_then(|p| p.get("code"))
                    .and_then(|c| c.as_str())
                    .unwrap_or("unknown");
                let message = payload
                    .and_then(|p| p.get("message"))
                    .and_then(|m| m.as_str())
                    .unwrap_or("");
                match cid {
                    None => Step::Fail(crash_text(format!(
                        "protocol error: hub rejection without command_id: {}",
                        first80(raw)
                    ))),
                    Some(cid) => {
                        let command = self.command_name(cid).to_string();
                        Step::Fail(crash_text(format!(
                            "hub rejected {command}: {code}: {message}"
                        )))
                    }
                }
            }
            "attention" | "device_changed" => Step::Continue,
            "stream_closed" => Step::FailQuiet(crash_text(
                "hub closed the stream (stream_closed)".to_string(),
            )),
            "stream_reopened" => Step::Fail(crash_text(
                "hub connection event stream_reopened ends the run".to_string(),
            )),
            "turn_completed" => {
                if !self.turn_started {
                    // Before our turn: fold only when the gate admits, never
                    // flags and never a close.
                    if self.admitted(&value) {
                        self.fold(raw);
                    }
                    return Step::Continue;
                }
                self.record_turn_outcome(&value);
                self.fold(raw);
                Step::CloseOnce
            }
            "fiber_exited" => self.on_exited(raw, &value),
            _ => {
                if kind == "turn_started" && self.is_own_turn_started(&value) {
                    self.turn_started = true;
                }
                if self.admitted(&value) {
                    self.fold(raw);
                }
                Step::Continue
            }
        }
    }

    fn command_name(&self, cid: &str) -> &str {
        if cid == self.start_id {
            "start"
        } else if cid == self.sub_id {
            "subscribe"
        } else if cid == self.prompt_id {
            "prompt"
        } else if self.close_id.as_deref() == Some(cid) {
            "close"
        } else {
            "unknown command"
        }
    }

    /// C's `turn_started`: a `turn_started` whose `payload.input` carries the
    /// prompt command id.
    fn is_own_turn_started(&self, value: &serde_json::Value) -> bool {
        value
            .get("payload")
            .and_then(|p| p.get("input"))
            .and_then(|i| i.as_array())
            .is_some_and(|items| {
                items.iter().any(|item| {
                    item.get("command_id").and_then(|c| c.as_str()) == Some(&self.prompt_id)
                })
            })
    }

    /// The history gate: a line read after the subscribe ack is admitted to
    /// the fold when C's turn has started, or when its `seq` passes the
    /// subscribe ack's `last_seq`. A missing `last_seq` means every line is
    /// live. Everything else is replayed history and is dropped.
    fn admitted(&self, value: &serde_json::Value) -> bool {
        if self.turn_started {
            return true;
        }
        let Some(last) = self.last_seq else {
            return true;
        };
        value
            .get("seq")
            .and_then(|s| s.as_u64())
            .is_some_and(|seq| seq > last)
    }

    fn fold(&mut self, raw: &[u8]) {
        (self.on)(Event::Activity);
        if handle_line(raw, &mut self.state) {
            (self.on)(Event::Progress(ProgressSnapshotRaw {
                last_tool: self.state.last_tool.clone(),
                tokens_so_far: self.state.tokens_so_far(),
                last_assistant: self.state.last_assistant.clone(),
                files_touched: self.state.files_touched.clone(),
                phase: self.state.phase.clone(),
                session_id: self.state.session_id.clone(),
            }));
        }
    }

    /// A `turn_completed` read after C's `turn_started` decides the verdict:
    /// only `completed` with no questions can end Done. A first failure wins
    /// and stays: a later completed turn never clears it.
    fn record_turn_outcome(&mut self, value: &serde_json::Value) {
        let payload = value.get("payload");
        if let Some(questions) = payload.and_then(|p| p.get("questions"))
            && questions.as_array().is_some_and(|q| !q.is_empty())
            && self.questions.is_none()
        {
            self.questions =
                Some(serde_json::to_string(questions).unwrap_or_else(|_| "questions".to_string()));
        }
        match payload
            .and_then(|p| p.get("outcome"))
            .and_then(|o| o.as_str())
        {
            Some("completed") => {
                self.completed_ok = true;
            }
            Some(outcome) => {
                if self.bad_outcome.is_none() {
                    self.bad_outcome = Some(outcome.to_string());
                }
            }
            None => {
                if self.bad_outcome.is_none() {
                    self.bad_outcome = Some("missing".to_string());
                }
            }
        }
    }

    /// A `fiber_exited` read after C's `turn_started` is the verdict at any
    /// `seq`. Before C's turn it is live only past `last_seq`, and a live one
    /// ends the run as an error: the turn never started. At or below
    /// `last_seq`, read before C's turn, it is replayed history and ignored.
    fn on_exited(&mut self, raw: &[u8], value: &serde_json::Value) -> Step {
        if self.turn_started {
            return Step::End(self.verdict(raw));
        }
        let live = match self.last_seq {
            None => true,
            Some(last) => value
                .get("seq")
                .and_then(|s| s.as_u64())
                .is_some_and(|seq| seq > last),
        };
        if !live {
            return Step::Continue;
        }
        Step::End(self.pre_turn_exit(value))
    }

    /// Fold the verdict line, then apply the turn rule: a non-`completed`
    /// outcome or carried questions is an error naming it, even on
    /// `fiber_exited` exit 0; Done needs an admitted `completed` turn.
    fn verdict(&mut self, raw: &[u8]) -> BackendResult {
        self.fold(raw);
        let mut res = finish(std::mem::take(&mut self.state), true, "");
        if res.is_error == Some(false) {
            if let Some(outcome) = self.bad_outcome.as_deref() {
                res.is_error = Some(true);
                res.text = crash_text(format!("turn outcome {outcome}: the turn did not complete"));
            } else if let Some(questions) = self.questions.as_deref() {
                res.is_error = Some(true);
                res.text = crash_text(format!(
                    "turn carried questions {questions}: the client never answers them"
                ));
            } else if !self.completed_ok {
                res.is_error = Some(true);
                res.text = crash_text("session exited without a completed turn".to_string());
            }
        }
        res
    }

    /// The turn never started: an error with the exit reason, never Done.
    fn pre_turn_exit(&mut self, value: &serde_json::Value) -> BackendResult {
        let payload = value.get("payload");
        let code = payload
            .and_then(|p| p.get("exit_code"))
            .and_then(|c| c.as_i64());
        let message = payload
            .and_then(|p| p.get("error"))
            .and_then(|e| e.get("message"))
            .and_then(|m| m.as_str())
            .or_else(|| {
                payload
                    .and_then(|p| p.get("error"))
                    .and_then(|e| e.as_str())
            });
        let reason = match (code, message) {
            (Some(code), Some(message)) => format!("exit_code {code}: {message}"),
            (Some(code), None) => format!("exit_code {code}"),
            (None, Some(message)) => message.to_string(),
            (None, None) => "no exit details".to_string(),
        };
        self.crash(crash_text(format!(
            "session exited before the turn started ({reason})"
        )))
    }
}

/// History handler as a free function, so the ack waits can borrow the
/// connection and the run state apart.
fn as_history(rest: &mut Rest, raw: &[u8]) -> Option<Step> {
    match rest.handle_history(raw) {
        Step::Continue => None,
        stop => Some(stop),
    }
}

/// Live handler as a free function, for the same borrow split.
fn as_live(rest: &mut Rest, raw: &[u8]) -> Option<Step> {
    match rest.handle_live(raw) {
        Step::Continue => None,
        stop => Some(stop),
    }
}

/// Run one step: send `close` once, end the run, or crash it. Returns `None`
/// to keep reading.
fn apply_step(conn: &mut HubConn, rest: &mut Rest, step: Step) -> Option<BackendResult> {
    match step {
        Step::Continue => None,
        Step::CloseOnce => {
            if !rest.closed {
                rest.closed = true;
                if let Some(session_id) = rest.session_id.clone() {
                    let id = new_command_id();
                    let _ = conn.send(&close_command(&id, &session_id));
                    rest.close_id = Some(id);
                }
            }
            None
        }
        Step::End(result) => Some(result),
        Step::Fail(text) => Some(fail_with_cleanup(conn, rest, text)),
        Step::FailQuiet(text) => Some(rest.crash(text)),
    }
}

/// Crash after the `start` answer, on a live connection: one best-effort
/// `close` with `now: true`, then the crash. Skipped when no session is open
/// or `close` already went out, so `close` is sent at most once per run.
fn fail_with_cleanup(conn: &mut HubConn, rest: &mut Rest, text: String) -> BackendResult {
    if !rest.closed {
        rest.closed = true;
        if let Some(session_id) = rest.session_id.clone() {
            let _ = conn.send(&close_now_command(&new_command_id(), &session_id));
        }
    }
    rest.crash(text)
}

/// A hub line must be JSON with a string `kind`; anything else is a crash
/// naming the first 80 bytes.
fn parse_line(raw: &[u8]) -> Result<(String, serde_json::Value), String> {
    let value: serde_json::Value = serde_json::from_slice(raw).map_err(|_| {
        crash_text(format!(
            "protocol error: hub line is not JSON: {}",
            first80(raw)
        ))
    })?;
    let kind = value.get("kind").and_then(|k| k.as_str()).ok_or_else(|| {
        crash_text(format!(
            "protocol error: hub line has no string kind: {}",
            first80(raw)
        ))
    })?;
    Ok((kind.to_string(), value))
}

/// The `command_id` a hub answer carries, when it carries a string one.
fn accepted_id(value: &serde_json::Value) -> Option<&str> {
    value
        .get("payload")
        .and_then(|p| p.get("command_id"))
        .and_then(|c| c.as_str())
}

/// A repository offer is never answered, so a dropped or folded offer would
/// block: the client never resolves one, and every offer ends the run.
fn repository_offer_text() -> String {
    crash_text(
        "repository offer repository_code_offered cannot be answered; ending the run".to_string(),
    )
}

/// A hub command with no answer when the connection dropped is not resent:
/// before the `start` answer the session may exist, after it the session may
/// still be running.
fn lost_before_start_text(start_id: &str) -> String {
    crash_text(format!(
        "No answer before the connection was lost. Start {start_id} is unanswered; the session may exist"
    ))
}

fn lost_text(session_id: &str) -> String {
    crash_text(format!(
        "No answer before the connection was lost. Session {session_id} gave no verdict; the session may still be running"
    ))
}

fn crash_result(
    session_id: Option<String>,
    permission_denials: Vec<serde_json::Value>,
    text: String,
) -> BackendResult {
    BackendResult {
        text,
        session_id,
        is_error: Some(true),
        clean_exit: false,
        permission_denials,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc;
    use std::time::Duration;

    static SOCK_NEXT: AtomicU64 = AtomicU64::new(0);

    fn sock_path() -> PathBuf {
        PathBuf::from(format!(
            "/tmp/dh-{}-{}",
            std::process::id(),
            SOCK_NEXT.fetch_add(1, Ordering::SeqCst)
        ))
    }

    struct FakeSrv {
        reader: BufReader<UnixStream>,
        writer: UnixStream,
        received: Vec<String>,
    }

    impl FakeSrv {
        fn send(&mut self, line: &str) {
            write_line(&mut self.writer, line).expect("fake hub send");
        }

        fn recv(&mut self) -> String {
            match read_line(&mut self.reader) {
                Ok(raw) => {
                    let s = String::from_utf8(raw).expect("fake hub keeps lines UTF-8");
                    self.received.push(s.clone());
                    s
                }
                Err(ReadErr::Lost(detail)) => {
                    panic!("fake hub timed out waiting for a client line: {detail}")
                }
            }
        }
    }

    /// Run `script` against one accepted connection. The script's reads carry
    /// deadlines, so a stuck client fails the test instead of hanging it.
    fn spawn_fake(
        script: impl FnOnce(&mut FakeSrv) + Send + 'static,
    ) -> (PathBuf, mpsc::Receiver<Vec<String>>) {
        let path = sock_path();
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).expect("bind fake hub");
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("fake hub accept");
            stream
                .set_read_timeout(Some(Duration::from_secs(15)))
                .expect("read timeout");
            let mut srv = FakeSrv {
                reader: BufReader::new(stream.try_clone().expect("clone")),
                writer: stream,
                received: Vec::new(),
            };
            script(&mut srv);
            let _ = tx.send(srv.received);
        });
        (path, rx)
    }

    fn join_fake(path: &Path, rx: mpsc::Receiver<Vec<String>>) -> Vec<String> {
        let received = rx
            .recv_timeout(Duration::from_secs(30))
            .expect("fake hub finished");
        let _ = std::fs::remove_file(path);
        received
    }

    fn hello(version: serde_json::Value, fiber_version: &str) -> String {
        serde_json::json!({
            "kind": "hub_hello",
            "schema_version": version,
            "payload": {"fiber_version": fiber_version},
        })
        .to_string()
    }

    #[test]
    fn hello_at_once_passes() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
        });
        let (conn, version) = connect(&path).expect("connect");
        drop(conn);
        assert_eq!(version, "9.9.9");
        assert!(join_fake(&path, rx).is_empty());
    }

    #[test]
    fn hello_schema_version_2_fails_with_the_rule_9_text() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(2), "9.9.9"));
        });
        let err = connect(&path).unwrap_err();
        assert!(
            err.contains("the hub speaks schema_version 2; delegate reads 1"),
            "{err}"
        );
        assert!(err.contains("9.9.9"), "{err}");
        join_fake(&path, rx);
    }

    #[test]
    fn hello_missing_schema_version_names_it_missing() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(
                &serde_json::json!({"kind":"hub_hello","payload":{"fiber_version":"1.2.3"}})
                    .to_string(),
            );
        });
        let err = connect(&path).unwrap_err();
        assert!(
            err.contains("the hub speaks schema_version missing; delegate reads 1"),
            "{err}"
        );
        join_fake(&path, rx);
    }

    #[test]
    fn hello_non_json_first_line_fails() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send("this is not json");
        });
        let err = connect(&path).unwrap_err();
        assert!(err.contains("protocol error"), "{err}");
        assert!(err.contains("this is not json"), "{err}");
        join_fake(&path, rx);
    }

    #[test]
    fn hello_wrong_kind_names_the_line() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&serde_json::json!({"kind":"command_accepted","payload":{}}).to_string());
        });
        let err = connect(&path).unwrap_err();
        assert!(err.contains("protocol error"), "{err}");
        assert!(err.contains("command_accepted"), "{err}");
        join_fake(&path, rx);
    }

    #[test]
    fn missing_socket_fails_with_the_path_and_os_error() {
        let missing = PathBuf::from(format!("/tmp/dh-missing-{}", std::process::id()));
        let _ = std::fs::remove_file(&missing);
        let err = connect(&missing).unwrap_err();
        assert!(err.contains(&*missing.to_string_lossy()), "{err}");
    }

    #[test]
    fn long_hub_line_reads_whole() {
        let big = "y".repeat(2 * 1024 * 1024);
        let mut cursor = std::io::Cursor::new(format!("{big}\n"));
        let line = read_line(&mut cursor).expect("long line");
        assert_eq!(line.len(), big.len());
        assert!(line.iter().all(|&b| b == b'y'));
    }

    #[test]
    fn split_line_with_a_pause_reads_whole() {
        let (client, server) = UnixStream::pair().expect("socket pair");
        let chunk = "q".repeat(20_000);
        let first = chunk.clone();
        std::thread::spawn(move || {
            use std::io::Write;
            let mut server = server;
            server.write_all(first.as_bytes()).expect("first half");
            server.flush().expect("flush");
            std::thread::sleep(Duration::from_millis(200));
            server
                .write_all(format!("{chunk}\n").as_bytes())
                .expect("second half");
        });
        let mut reader = BufReader::new(client);
        let line = read_line(&mut reader).expect("split line");
        assert_eq!(line.len(), 40_000);
        assert!(line.iter().all(|&b| b == b'q'));
    }

    #[test]
    fn eof_without_a_line_is_a_lost_connection() {
        let mut empty = std::io::Cursor::new(b"".to_vec());
        assert!(matches!(read_line(&mut empty), Err(ReadErr::Lost(_))));
        let mut partial = std::io::Cursor::new(b"abc".to_vec());
        assert!(matches!(read_line(&mut partial), Err(ReadErr::Lost(_))));
    }

    #[test]
    fn socket_path_over_103_bytes_fails() {
        let home_95 = format!("/tmp/{}", "a".repeat(90));
        assert_eq!(home_95.len(), 95);
        let ok = hub_socket_path(Path::new(&home_95)).expect("103 bytes");
        assert_eq!(ok.to_string_lossy().len(), 103);
        let home_96 = format!("/tmp/{}", "a".repeat(91));
        let err = hub_socket_path(Path::new(&home_96)).unwrap_err();
        assert!(err.contains("FIBER_HOME"), "{err}");
        assert!(err.contains("103"), "{err}");
    }

    #[test]
    fn fiber_home_defaults_and_rejects() {
        let _held = crate::test_env::lock();
        let _home = crate::test_env::EnvGuard::set("HOME", "/tmp/dh-home");
        let _unset = crate::test_env::EnvGuard::remove("FIBER_HOME");
        assert_eq!(
            fiber_home().expect("default"),
            PathBuf::from("/tmp/dh-home/.fiber")
        );
        let _empty = crate::test_env::EnvGuard::set("FIBER_HOME", "");
        assert!(
            fiber_home().unwrap_err().contains("FIBER_HOME"),
            "empty names the variable"
        );
        let _rel = crate::test_env::EnvGuard::set("FIBER_HOME", "rel/path");
        assert!(
            fiber_home().unwrap_err().contains("FIBER_HOME"),
            "relative names the variable"
        );
        let _abs = crate::test_env::EnvGuard::set("FIBER_HOME", "/abs/path");
        assert_eq!(fiber_home().expect("absolute"), PathBuf::from("/abs/path"));
        let _non_utf8 = crate::test_env::EnvGuard::set_os(
            "FIBER_HOME",
            std::os::unix::ffi::OsStringExt::from_vec(vec![0xff]),
        );
        assert!(
            fiber_home().unwrap_err().contains("FIBER_HOME"),
            "non-UTF-8 names the variable"
        );
    }

    #[test]
    fn command_ids_are_prefixed_hex_and_unique() {
        for id in [new_command_id(), new_command_id()] {
            assert!(id.starts_with("c_"), "{id}");
            assert_eq!(id.len(), 18, "{id}");
            assert!(
                id[2..]
                    .chars()
                    .all(|c| c.is_ascii_hexdigit() && (c.is_ascii_digit() || c.is_lowercase())),
                "{id}"
            );
        }
        assert_ne!(new_command_id(), new_command_id());
    }

    #[test]
    fn command_bytes_match_the_driver_table() {
        assert_eq!(
            start_command("c_1", "/abs/worktree", "opencode-go/m"),
            r#"{"id":"c_1","command":"start","args":{"workspace":"/abs/worktree","model":"opencode-go/m","supervised":true}}"#
        );
        assert_eq!(
            subscribe_command("c_2", "s_36e63d22c39750e1"),
            r#"{"id":"c_2","command":"subscribe","session_id":"s_36e63d22c39750e1","args":{"level":"full"}}"#
        );
        assert_eq!(
            prompt_command("c_3", "s_36e63d22c39750e1", "hi"),
            r#"{"id":"c_3","command":"prompt","session_id":"s_36e63d22c39750e1","args":{"content":[{"type":"text","text":"hi"}]}}"#
        );
        assert_eq!(
            close_command("c_4", "s_36e63d22c39750e1"),
            r#"{"id":"c_4","command":"close","session_id":"s_36e63d22c39750e1"}"#
        );
        assert_eq!(
            close_now_command("c_5", "s_36e63d22c39750e1"),
            r#"{"id":"c_5","command":"close","session_id":"s_36e63d22c39750e1","args":{"now":true}}"#
        );
    }

    #[test]
    fn start_command_carries_no_session_id() {
        let line: serde_json::Value =
            serde_json::from_str(&start_command("c_1", "/w", "m")).expect("json");
        assert!(line.get("session_id").is_none());
        assert_eq!(
            line.get("args").and_then(|a| a.get("supervised")),
            Some(&serde_json::Value::Bool(true))
        );
    }

    fn accepted(id: &str, result: serde_json::Value) -> String {
        serde_json::json!({
            "kind": "command_accepted",
            "schema_version": 1,
            "payload": {"command_id": id, "result": result},
        })
        .to_string()
    }

    fn rejected(id: Option<&str>, code: &str, message: &str) -> String {
        let mut payload = serde_json::json!({"code": code, "message": message});
        if let Some(id) = id {
            payload["command_id"] = id.into();
        }
        serde_json::json!({
            "kind": "command_rejected",
            "schema_version": 1,
            "payload": payload,
        })
        .to_string()
    }

    fn connect_pair(
        script: impl FnOnce(&mut FakeSrv) + Send + 'static,
    ) -> (HubConn, PathBuf, mpsc::Receiver<Vec<String>>) {
        let (path, rx) = spawn_fake(script);
        let (conn, _) = connect(&path).expect("connect");
        (conn, path, rx)
    }

    #[test]
    fn start_answer_gives_the_session() {
        let (mut conn, path, rx) = connect_pair(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            assert_eq!(srv.recv(), start_command("c_1", "/w", "m"));
            srv.send(&accepted("c_1", serde_json::json!({"session_id": "s_9"})));
        });
        conn.send(&start_command("c_1", "/w", "m")).expect("send");
        let WaitOutcome::Ack(Ack::Accepted { result }) = conn.await_ack("c_1", |_| None) else {
            panic!("rejected");
        };
        assert_eq!(start_session(&result).expect("session"), "s_9");
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn start_accept_without_a_session_id_is_a_protocol_error() {
        for result in [
            serde_json::json!({}),
            serde_json::json!({"session_id": serde_json::Value::Null}),
            serde_json::json!({"session_id": 7}),
            serde_json::json!({"session_id": ""}),
        ] {
            assert!(
                start_session(&result)
                    .unwrap_err()
                    .contains("no session_id"),
                "{result}"
            );
        }
        assert_eq!(
            start_session(&serde_json::json!({"session_id": "s_1"})).expect("ok"),
            "s_1"
        );
    }

    #[test]
    fn rejection_returns_code_and_message() {
        let (mut conn, path, rx) = connect_pair(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            srv.recv();
            srv.send(&rejected(Some("c_1"), "invalid_arguments", "bad start"));
        });
        conn.send(&start_command("c_1", "/w", "m")).expect("send");
        let WaitOutcome::Ack(Ack::Rejected { code, message }) = conn.await_ack("c_1", |_| None)
        else {
            panic!("accepted");
        };
        assert_eq!(code, "invalid_arguments");
        assert_eq!(message, "bad start");
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn answer_without_a_command_id_is_a_protocol_error() {
        let cases = [
            accepted("c_1", serde_json::json!({})),
            rejected(Some("c_1"), "busy", "taken"),
        ];
        for line in cases {
            let stripped: serde_json::Value = serde_json::from_str(&line).expect("json");
            let mut payload = stripped
                .get("payload")
                .cloned()
                .expect("payload")
                .as_object()
                .cloned()
                .expect("object");
            payload.remove("command_id");
            let bare = serde_json::json!({
                "kind": stripped.get("kind"),
                "schema_version": 1,
                "payload": payload,
            })
            .to_string();
            let (mut conn, path, rx) = connect_pair(move |srv| {
                srv.send(&hello(serde_json::json!(1), "9.9.9"));
                srv.recv();
                srv.send(&bare);
            });
            conn.send(&start_command("c_1", "/w", "m")).expect("send");
            let WaitOutcome::Stopped(Step::Fail(text)) = conn.await_ack("c_1", |_| None) else {
                panic!("no protocol error for {line}");
            };
            assert!(text.contains("protocol error"), "{text}");
            assert!(text.contains("command_id"), "{text}");
            drop(conn);
            join_fake(&path, rx);
        }
    }

    #[test]
    fn answer_for_another_id_is_a_protocol_error_naming_it() {
        let (mut conn, path, rx) = connect_pair(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            srv.recv();
            srv.send(&accepted("c_other", serde_json::json!({})));
        });
        conn.send(&start_command("c_1", "/w", "m")).expect("send");
        let WaitOutcome::Stopped(Step::Fail(text)) = conn.await_ack("c_1", |_| None) else {
            panic!("no protocol error");
        };
        assert!(text.contains("protocol error"), "{text}");
        assert!(text.contains("c_other"), "{text}");
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn lines_before_the_ack_are_kept_in_order() {
        let first = serde_json::json!({"kind":"attention","seq":1}).to_string();
        let second = "not json at all".to_string();
        let third = serde_json::json!({"kind":"device_changed","seq":2}).to_string();
        let (mut conn, path, rx) = connect_pair(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            srv.recv();
            srv.send(&serde_json::json!({"kind":"attention","seq":1}).to_string());
            srv.send("not json at all");
            srv.send(&serde_json::json!({"kind":"device_changed","seq":2}).to_string());
            srv.send(&accepted("c_1", serde_json::json!({"session_id": "s_1"})));
        });
        conn.send(&start_command("c_1", "/w", "m")).expect("send");
        let mut seen = Vec::new();
        let WaitOutcome::Ack(Ack::Accepted { .. }) = conn.await_ack("c_1", |raw| {
            seen.push(String::from_utf8_lossy(raw).into_owned());
            None
        }) else {
            panic!("rejected");
        };
        assert_eq!(seen, vec![first, second, third]);
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn lost_connection_while_waiting_is_not_an_ack() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
        });
        let (mut conn, _) = connect(&path).expect("connect");
        let WaitOutcome::Lost = conn.await_ack("c_1", |_| None) else {
            panic!("expected loss");
        };
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn two_commands_never_share_an_id() {
        let a = new_command_id();
        let b = new_command_id();
        assert_ne!(a, b);
        let (mut conn, path, rx) = connect_pair(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let first = srv.recv();
            let second = srv.recv();
            let a_id: String =
                serde_json::from_str::<serde_json::Value>(&first).expect("json")["id"]
                    .as_str()
                    .expect("id")
                    .into();
            let b_id: String =
                serde_json::from_str::<serde_json::Value>(&second).expect("json")["id"]
                    .as_str()
                    .expect("id")
                    .into();
            assert_ne!(a_id, b_id);
        });
        conn.send(&start_command(&a, "/w", "m")).expect("send");
        conn.send(&subscribe_command(&b, "s_1")).expect("send");
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn last_seq_present_absent_and_wrong_shape() {
        assert_eq!(last_seq_of(&serde_json::json!({"last_seq": 41})), Some(41));
        assert_eq!(last_seq_of(&serde_json::json!({})), None);
        assert_eq!(last_seq_of(&serde_json::json!({"last_seq": "41"})), None);
        assert_eq!(last_seq_of(&serde_json::json!({"last_seq": -1})), None);
    }

    impl FakeSrv {
        /// No further client line follows: a clean EOF passes, a line or a
        /// still-open connection fails. The spawn timeout bounds the wait: a
        /// silent but open connection fails the test instead of hanging it.
        /// No new timeout is set here: this platform rejects a second
        /// `set_read_timeout` once the peer is at EOF.
        fn expect_eof(&mut self) {
            match read_line(&mut self.reader) {
                Err(ReadErr::Lost(detail)) if detail == "connection closed" => {}
                Err(ReadErr::Lost(detail)) => {
                    panic!("fake hub expected EOF, got loss: {detail}")
                }
                Ok(line) => panic!(
                    "fake hub got an extra line: {}",
                    String::from_utf8_lossy(&line)
                ),
            }
        }
    }

    fn hub_request() -> HubRequest {
        HubRequest {
            cwd: "/w".to_string(),
            model: "fiber/m".to_string(),
            prompt: "go".to_string(),
        }
    }

    fn run_case(
        script: impl FnOnce(&mut FakeSrv) + Send + 'static,
    ) -> (BackendResult, Vec<String>) {
        let (path, rx) = spawn_fake(script);
        let res = run_turn(&hub_request(), &path, &|_| {});
        let received = join_fake(&path, rx);
        (res, received)
    }

    fn ev(kind: &str, seq: u64, payload: serde_json::Value) -> String {
        serde_json::json!({
            "kind": kind,
            "session_id": "s_1",
            "ts": 1,
            "schema_version": 1,
            "seq": seq,
            "payload": payload,
        })
        .to_string()
    }

    fn turn_started_ev(cmd_id: &str, seq: u64) -> String {
        ev(
            "turn_started",
            seq,
            serde_json::json!({"input": [{
                "command_id": cmd_id,
                "content": [{"type": "text", "text": "go"}],
                "source": "driver",
                "type": "message",
            }]}),
        )
    }

    fn turn_completed_ev(seq: u64, outcome: &str, questions: Option<serde_json::Value>) -> String {
        let mut payload = serde_json::json!({"outcome": outcome});
        if let Some(questions) = questions {
            payload["questions"] = questions;
        }
        ev("turn_completed", seq, payload)
    }

    fn exited_ev(seq: u64, exit_code: i64, text: &str, error: Option<&str>) -> String {
        let mut payload = serde_json::json!({"exit_code": exit_code, "text": text});
        if let Some(error) = error {
            payload["error"] = serde_json::json!({"message": error});
        }
        ev("fiber_exited", seq, payload)
    }

    fn offer_ev(seq: u64) -> String {
        ev(
            "repository_code_offered",
            seq,
            serde_json::json!({"path": "/repo", "revision": "abc"}),
        )
    }

    fn recv_id(srv: &mut FakeSrv) -> (String, serde_json::Value) {
        let line = srv.recv();
        let value: serde_json::Value = serde_json::from_str(&line).expect("hub line json");
        let id = value
            .get("id")
            .and_then(|i| i.as_str())
            .expect("command id")
            .to_string();
        (id, value)
    }

    fn received_commands(received: &[String]) -> Vec<String> {
        received
            .iter()
            .map(|line| {
                serde_json::from_str::<serde_json::Value>(line).expect("hub line json")["command"]
                    .as_str()
                    .expect("command")
                    .to_string()
            })
            .collect()
    }

    fn fixture_lines(name: &str, n: usize) -> Vec<String> {
        let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
        let text = std::fs::read_to_string(dir.join(name)).expect("fixture");
        text.lines().take(n).map(str::to_string).collect()
    }

    /// The standard handshake to the prompt ack. Fold lines come from a
    /// recorded fixture, read only. The prompt id C is the id of the last
    /// line the fake received.
    fn handshake_to_prompt(srv: &mut FakeSrv, fold: &[String], last_seq: serde_json::Value) {
        srv.send(&hello(serde_json::json!(1), "9.9.9"));
        let (start_id, start) = recv_id(srv);
        assert_eq!(start["command"], "start");
        assert_eq!(start["args"]["supervised"], true);
        assert_eq!(start["args"]["workspace"], "/w");
        assert_eq!(start["args"]["model"], "m");
        assert!(start.get("session_id").is_none());
        srv.send(&accepted(
            &start_id,
            serde_json::json!({"session_id": "s_1"}),
        ));
        let (sub_id, sub) = recv_id(srv);
        assert_eq!(sub["command"], "subscribe");
        assert_eq!(sub["session_id"], "s_1");
        assert_eq!(sub["args"]["level"], "full");
        for line in fold {
            srv.send(line);
        }
        let mut result = serde_json::json!({});
        if !last_seq.is_null() {
            result["last_seq"] = last_seq;
        }
        srv.send(&accepted(&sub_id, result));
        let (prompt_id, prompt) = recv_id(srv);
        assert_eq!(prompt["command"], "prompt");
        assert_eq!(prompt["session_id"], "s_1");
        assert_eq!(prompt["args"]["content"][0]["text"], "go");
        srv.send(&accepted(&prompt_id, serde_json::json!({})));
    }

    #[test]
    fn fresh_run_to_done_with_text_done() {
        let fold = fixture_lines("contract/fiber/needs-context.jsonl", 8);
        let (res, received) = run_case(move |srv| {
            handshake_to_prompt(srv, &fold, serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&ev("assistant_message_delta", 1002, serde_json::json!({})));
            srv.send(&turn_completed_ev(1003, "completed", None));
            srv.send(&exited_ev(1004, 0, "DONE", None));
            let (_close_id, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["session_id"], "s_1");
            assert!(close.get("args").is_none());
            srv.expect_eof();
        });
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert!(res.clean_exit);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
        let start: serde_json::Value = serde_json::from_str(&received[0]).expect("start");
        assert_eq!(start["args"]["supervised"], true);
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Done
        );
    }

    fn received_last(received: &[String]) -> String {
        received.last().cloned().expect("last received")
    }

    #[test]
    fn replay_exit_at_or_below_last_seq_is_ignored() {
        let (res, received) = run_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&exited_ev(500, 0, "stale", None));
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 1000})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({})));
            srv.send(&exited_ev(999, 0, "stale", None));
            srv.send(&exited_ev(1000, 0, "stale at the fold point", None));
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(1002, "completed", None));
            srv.send(&exited_ev(1003, 0, "DONE", None));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            srv.expect_eof();
        });
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn live_exit_before_the_turn_started_is_an_error() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&exited_ev(1001, 1, "", Some("boom")));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(!res.clean_exit);
        assert!(
            res.text.contains("session exited before the turn started"),
            "{}",
            res.text
        );
        assert!(res.text.contains("boom"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
    }

    #[test]
    fn live_exit_before_the_turn_started_with_no_last_seq() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::Value::Null);
            srv.send(&exited_ev(3, 1, "", Some("gone")));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(
            res.text.contains("session exited before the turn started"),
            "{}",
            res.text
        );
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
    }

    #[test]
    fn post_turn_exit_at_a_low_seq_is_still_the_verdict() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 5));
            srv.send(&turn_completed_ev(6, "completed", None));
            srv.send(&exited_ev(7, 0, "DONE", None));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            srv.expect_eof();
        });
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert!(res.clean_exit);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn foreign_turn_started_does_not_start_the_turn() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&turn_started_ev("c_foreign", 1001));
            srv.send(&exited_ev(1002, 1, "", Some("away")));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(
            res.text.contains("session exited before the turn started"),
            "{}",
            res.text
        );
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
    }

    #[test]
    fn done_needs_a_completed_turn() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&exited_ev(1002, 0, "suspended", None));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(
            res.text.contains("without a completed turn"),
            "{}",
            res.text
        );
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
    }

    #[test]
    fn second_turn_completed_after_close_only_folds() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(1002, "completed", None));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            srv.send(&turn_completed_ev(1003, "completed", None));
            srv.send(&exited_ev(1004, 0, "DONE", None));
            srv.expect_eof();
        });
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn close_ack_is_ignored() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(1002, "completed", None));
            let (close_id, _) = recv_id(srv);
            srv.send(&accepted(&close_id, serde_json::json!({})));
            srv.send(&exited_ev(1003, 0, "DONE", None));
            srv.expect_eof();
        });
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn long_line_mid_run_is_folded_not_dropped() {
        let big_text = "z".repeat(300 * 1024);
        let (res, received) = run_case(move |srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&ev(
                "assistant_message_delta",
                1002,
                serde_json::json!({"text": big_text}),
            ));
            srv.send(&turn_completed_ev(1003, "completed", None));
            srv.send(&exited_ev(1004, 0, "DONE", None));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            srv.expect_eof();
        });
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn silent_hub_after_prompt_means_no_verdict() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
        });
        assert!(
            res.text
                .starts_with("No answer before the connection was lost."),
            "{}",
            res.text
        );
        assert!(res.text.contains("s_1"), "{}", res.text);
        assert!(res.text.contains("may still be running"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
    }

    #[test]
    fn silent_hub_after_turn_started_means_no_verdict() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
        });
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
        assert!(
            res.text
                .starts_with("No answer before the connection was lost."),
            "{}",
            res.text
        );
        assert!(res.text.contains("s_1"), "{}", res.text);
        assert!(res.text.contains("may still be running"), "{}", res.text);
    }

    #[test]
    fn drop_before_the_start_answer_names_the_client_id() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            srv.recv();
        });
        let res = run_turn(&hub_request(), &path, &|_| {});
        let received = join_fake(&path, rx);
        assert_eq!(received.len(), 1);
        let start_id =
            serde_json::from_str::<serde_json::Value>(&received[0]).expect("start")["id"]
                .as_str()
                .expect("id")
                .to_string();
        assert!(
            res.text
                .starts_with("No answer before the connection was lost."),
            "{}",
            res.text
        );
        assert!(res.text.contains(&start_id), "{}", res.text);
        assert!(res.text.contains("may exist"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
    }

    #[test]
    fn exited_with_exit_1_and_error_keeps_that_error() {
        let (res, _) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(1002, "completed", None));
            let (_, _) = recv_id(srv);
            srv.send(&ev(
                "fiber_exited",
                1003,
                serde_json::json!({
                    "exit_code": 1,
                    "error": {"message": "crashed"},
                }),
            ));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(res.clean_exit);
        assert_eq!(res.text, "crashed");
    }

    #[test]
    fn failed_and_interrupted_outcomes_are_errors_naming_the_outcome() {
        for outcome in ["failed", "interrupted"] {
            let (res, received) = run_case(|srv| {
                handshake_to_prompt(srv, &[], serde_json::json!(1000));
                let prompt_id =
                    serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                        .expect("prompt")["id"]
                        .as_str()
                        .expect("id")
                        .to_string();
                srv.send(&turn_started_ev(&prompt_id, 1001));
                srv.send(&turn_completed_ev(1002, outcome, None));
                let (_, close) = recv_id(srv);
                assert_eq!(close["command"], "close");
                srv.send(&exited_ev(1003, 0, "whatever", None));
                srv.expect_eof();
            });
            assert_eq!(res.is_error, Some(true), "{outcome}");
            assert!(res.text.contains(outcome), "{}: {}", outcome, res.text);
            assert_eq!(
                received_commands(&received),
                ["start", "subscribe", "prompt", "close"]
            );
            assert!(
                crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                    == crate::types::RunStatus::Error
            );
        }
    }

    #[test]
    fn turn_carrying_questions_is_an_error_naming_them() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(
                1002,
                "completed",
                Some(serde_json::json!(["Which branch?"])),
            ));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            srv.send(&exited_ev(1003, 0, "waiting", None));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(res.text.contains("Which branch?"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
    }

    #[test]
    fn empty_questions_do_not_spoil_done() {
        let (res, _) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(
                1002,
                "completed",
                Some(serde_json::json!([])),
            ));
            let (_, _) = recv_id(srv);
            srv.send(&exited_ev(1003, 0, "DONE", None));
            srv.expect_eof();
        });
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
    }

    #[test]
    fn attention_and_device_changed_are_ignored() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&ev("attention", 1001, serde_json::json!({})));
            srv.send(&turn_started_ev(&prompt_id, 1002));
            srv.send(&ev("device_changed", 1003, serde_json::json!({})));
            srv.send(&turn_completed_ev(1004, "completed", None));
            srv.send(&exited_ev(1005, 0, "DONE", None));
            let (_, _) = recv_id(srv);
            srv.expect_eof();
        });
        assert_eq!(res.text, "DONE");
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn repository_offer_during_subscribe_wait_is_a_crash() {
        let (res, received) = run_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (_, _) = recv_id(srv);
            srv.send(&offer_ev(500));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert_offer_crash(&res, &received, &["start", "subscribe", "close"]);
    }

    #[test]
    fn repository_offer_below_last_seq_is_a_crash() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&offer_ev(500));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert_offer_crash(&res, &received, &["start", "subscribe", "prompt", "close"]);
    }

    #[test]
    fn repository_offer_live_before_the_turn_is_a_crash() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&offer_ev(1001));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert_offer_crash(&res, &received, &["start", "subscribe", "prompt", "close"]);
    }

    #[test]
    fn repository_offer_after_the_turn_started_is_a_crash() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&offer_ev(1002));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert_offer_crash(&res, &received, &["start", "subscribe", "prompt", "close"]);
    }

    fn assert_offer_crash(res: &BackendResult, received: &[String], commands: &[&str]) {
        assert!(res.text.contains("repository_code_offered"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(received_commands(received), commands);
        let close: serde_json::Value =
            serde_json::from_str(&received[received.len() - 1]).expect("close");
        assert_eq!(close["command"], "close");
        assert_eq!(close["args"]["now"], true);
    }

    #[test]
    fn rejected_start_sends_nothing_more() {
        let (res, received) = run_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&rejected(
                Some(&start_id),
                "invalid_arguments",
                "bad workspace",
            ));
            srv.expect_eof();
        });
        assert!(res.text.contains("invalid_arguments"), "{}", res.text);
        assert!(res.text.contains("bad workspace"), "{}", res.text);
        assert_eq!(received.len(), 1);
        assert_eq!(received_commands(&received), ["start"]);
    }

    #[test]
    fn rejected_subscribe_closes_now() {
        let (res, received) = run_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&rejected(Some(&sub_id), "session_held", "held"));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("session_held"), "{}", res.text);
        assert!(res.text.contains("subscribe"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "close"]
        );
    }

    #[test]
    fn rejected_prompt_busy_closes_now() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt_no_prompt_ack(srv, serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&rejected(Some(&prompt_id), "busy", "turn running"));
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("busy"), "{}", res.text);
        assert!(res.text.contains("prompt"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    fn handshake_to_prompt_no_prompt_ack(srv: &mut FakeSrv, last_seq: serde_json::Value) {
        srv.send(&hello(serde_json::json!(1), "9.9.9"));
        let (start_id, _) = recv_id(srv);
        srv.send(&accepted(
            &start_id,
            serde_json::json!({"session_id": "s_1"}),
        ));
        let (sub_id, _) = recv_id(srv);
        let mut result = serde_json::json!({});
        if !last_seq.is_null() {
            result["last_seq"] = last_seq;
        }
        srv.send(&accepted(&sub_id, result));
        let _ = recv_id(srv);
    }

    #[test]
    fn rejected_close_is_a_crash_naming_it() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(1002, "completed", None));
            let (close_id, _) = recv_id(srv);
            srv.send(&rejected(Some(&close_id), "closing", "going away"));
            srv.expect_eof();
        });
        assert!(res.text.contains("closing"), "{}", res.text);
        assert!(res.text.contains("close"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn accept_for_an_unknown_id_mid_run_is_a_crash() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&accepted("c_unknown", serde_json::json!({})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("c_unknown"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn reject_without_a_command_id_is_a_crash() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(
                &serde_json::json!({
                    "kind": "command_rejected",
                    "schema_version": 1,
                    "payload": {"code": "busy", "message": "x"},
                })
                .to_string(),
            );
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("protocol error"), "{}", res.text);
        assert!(res.text.contains("command_id"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn stream_closed_never_gets_a_close() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&ev("stream_closed", 1001, serde_json::json!({})));
            srv.expect_eof();
        });
        assert!(res.text.contains("stream_closed"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
    }

    #[test]
    fn stream_reopened_is_a_crash_with_cleanup() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&ev("stream_reopened", 1001, serde_json::json!({})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("stream_reopened"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn non_json_line_mid_run_is_a_crash_with_cleanup() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send("this is not json at all, and it is long enough to name bytes here!!");
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("protocol error"), "{}", res.text);
        assert!(res.text.contains("this is not json"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn kindless_line_mid_run_is_a_crash_with_cleanup() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&serde_json::json!({"seq": 1001, "payload": {}}).to_string());
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("protocol error"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn non_json_during_subscribe_wait_is_a_crash() {
        let (res, received) = run_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (_, _) = recv_id(srv);
            srv.send("garbage before the subscribe ack");
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("protocol error"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "close"]
        );
    }

    #[test]
    fn reviewer_denial_lands_in_permission_denials() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&ev(
                "tool_call_requested",
                1002,
                serde_json::json!({"name": "shell", "action_id": "a_1"}),
            ));
            srv.send(&ev(
                "permission_resolved",
                1003,
                serde_json::json!({
                    "action_id": "a_1",
                    "decision": "deny",
                    "decided_by": "reviewer",
                    "reason": "fetches a remote host",
                }),
            ));
            srv.send(&ev(
                "tool_call_completed",
                1004,
                serde_json::json!({"action_id": "a_1", "status": "denied"}),
            ));
            srv.send(&turn_completed_ev(1005, "completed", None));
            srv.send(&exited_ev(1006, 0, "refused", None));
            let (_, _) = recv_id(srv);
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(false));
        assert!(
            !res.permission_denials.is_empty(),
            "{:?}",
            res.permission_denials
        );
        assert!(received.iter().all(|line| {
            let v: serde_json::Value = serde_json::from_str(line).expect("json");
            !matches!(v["command"].as_str(), Some("reply") | Some("cancel"))
        }));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn hub_message_ending_in_status_done_still_errors() {
        let (res, _) = run_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&rejected(
                Some(&sub_id),
                "session_held",
                "taken\nSTATUS: DONE",
            ));
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("STATUS: DONE"), "{}", res.text);
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
    }
}
