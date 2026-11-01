//! Supervised hub client for the Fiber door (see #682).
//!
//! A program that drives sessions is a client of the hub: it connects to
//! `<FIBER_HOME>/run/hub`, starts a supervised session, drives it with the
//! driver commands and ends it with `close`, reading `fiber_exited` as the
//! verdict. Socket reads are polled in `poll_slice` slices against the
//! `Bounds` totals for the run; all writes go through one locked writer
//! with a per-sequence write deadline. A second thread can stop the run
//! with `kill` or `cancel`: one `close now` goes out (re-subscribing at
//! `summary` when the connection holds no subscription, retried once after
//! `stream_closed`), and the run ends when the stop wait passes or the
//! verdict arrives first.

use super::super::types::{BackendResult, Event, EventFn, ProgressSnapshotRaw};
use super::{finish, handle_line};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// A socket path is limited to 103 bytes on macOS.
const MAX_SOCKET_PATH: usize = 103;

/// Fixed closing sentence on every error text the client builds, so no text
/// the client builds ever ends in a hub or model `STATUS:` line.
const FIXED: &str = "The run ended without a verdict.";

fn crash_text(body: String) -> String {
    format!("{body}\n{FIXED}")
}

const ACK_WAIT: Duration = Duration::from_secs(30);
const TURN_START_WAIT: Duration = Duration::from_secs(120);
const STOP_WAIT: Duration = Duration::from_secs(10);
const POLL_SLICE: Duration = Duration::from_millis(200);
const WRITE_DEADLINE: Duration = Duration::from_secs(5);

/// Bounds for every wait in the run. Each bound is a total for its wait: a
/// line that arrives resets nothing. `turn_wait` is `None` by default, which
/// means unbounded, as with `wall_ms` elsewhere.
#[derive(Clone, Debug)]
pub struct Bounds {
    pub ack_wait: Duration,
    pub turn_start_wait: Duration,
    pub turn_wait: Option<Duration>,
    pub stop_wait: Duration,
    pub poll_slice: Duration,
    pub write_deadline: Duration,
}

impl Default for Bounds {
    fn default() -> Self {
        Bounds {
            ack_wait: ACK_WAIT,
            turn_start_wait: TURN_START_WAIT,
            turn_wait: None,
            stop_wait: STOP_WAIT,
            poll_slice: POLL_SLICE,
            write_deadline: WRITE_DEADLINE,
        }
    }
}

/// The OS rejects a zero socket timeout, so a zero bound becomes 1 ms.
fn clamp_bound(bound: Duration) -> Duration {
    bound.max(Duration::from_millis(1))
}

/// The writer side of the connection, shared with the control thread. One
/// lock per write sequence; the driver never holds it across a read.
#[derive(Debug)]
struct Shared {
    out: Mutex<Out>,
    /// Test-only clock and pause points for the race and clock tests (N5):
    /// the production build has no field here.
    #[cfg(test)]
    hooks: Hooks,
}

/// Test seam (N5): a clock the test advances as a value, and pause points
/// where the driver stops until the test releases it. No sleep, no real
/// wait on a constant, no production field.
#[cfg(test)]
struct Hooks {
    clock: Box<dyn Fn() -> Instant + Send + Sync>,
    pause: Option<Box<dyn Fn(Point) + Send + Sync>>,
}

#[cfg(test)]
impl Hooks {
    fn live() -> Self {
        Hooks {
            clock: Box::new(Instant::now),
            pause: None,
        }
    }
}

#[cfg(test)]
impl std::fmt::Debug for Hooks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Hooks").finish()
    }
}

/// The places the driver stops for the race tests. Fired in both builds in
/// `pause!` calls; without `cfg(test)` the macro expands to nothing.
#[cfg(test)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Point {
    BeforeRead,
    AfterLine,
    BeforeStartAnswer,
    BeforeSubscribeWrite,
    BeforeSubscribeAck,
    AfterSubscribeAck,
    BeforePromptWrite,
    AfterPromptAck,
    AfterVerdictFlag,
    HelloTick,
}

/// The run's clock: wall time in production, the test's value under test.
#[cfg(not(test))]
fn now(_shared: &Shared) -> Instant {
    Instant::now()
}

/// The run's clock: wall time in production, the test's value under test.
#[cfg(test)]
fn now(shared: &Shared) -> Instant {
    (shared.hooks.clock)()
}

#[cfg(test)]
macro_rules! pause {
    ($shared:expr, $point:expr) => {
        if let Some(pause) = $shared.hooks.pause.as_ref() {
            pause($point);
        }
    };
}

#[cfg(not(test))]
macro_rules! pause {
    ($shared:expr, $point:expr) => {};
}

/// The writable half: one sequence at a time, one budget per sequence.
/// `writer` is set once the connect succeeds; `session_id` once the `start`
/// is answered; `subscribed` while the hub holds a subscription for this
/// connection.
#[derive(Debug)]
struct Out {
    writer: Option<UnixStream>,
    deadline: Duration,
    broken: bool,
    ended: bool,
    session_id: Option<String>,
    subscribed: bool,
    summary_sent: bool,
    summary_ids: Vec<String>,
    close_now_id: Option<String>,
    close_now_ids: Vec<String>,
    close_now_open: bool,
    intent: Intent,
    stopping: bool,
    retried: bool,
}

/// What the control thread asked for: `Kill` upgrades a pending `Cancel`,
/// and the two differ only in the crash text.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Intent {
    None,
    Cancel,
    Kill,
}

/// Why the run is stopping: a control-thread stop, or an expired phase
/// bound running the stop procedure as for `cancel` (R10).
#[derive(Clone, Copy, PartialEq, Eq)]
enum StopReason {
    Kill,
    Cancel,
    TurnStartWait,
    TurnWait,
}

/// A stop under way: the text is fixed at the deadline, while a `fiber_exited`
/// read before then still wins in the line handler (R3).
struct Stop {
    reason: StopReason,
    deadline: Instant,
}

/// One ack wait: which command is unanswered, and when the wait ends in a
/// crash (R10). The driver installs it in `Rest` around each `await_ack`.
#[derive(Clone, Copy)]
struct AckWait {
    what: &'static str,
    deadline: Instant,
}

/// The ids the driver knows at one pass: answers for these are the client's
/// own commands, never protocol errors. Rebuilt after every line read: a
/// retry or a control-thread `close now` mints ids mid-wait.
#[derive(Default)]
struct KnownIds {
    close_id: Option<String>,
    close_now_ids: Vec<String>,
    summary_ids: Vec<String>,
    stream_closed_pending: bool,
}

fn known_ids(rest: &Rest, shared: &Shared) -> KnownIds {
    let out = lock(&shared.out);
    KnownIds {
        close_id: rest.close_id.clone(),
        close_now_ids: out.close_now_ids.clone(),
        summary_ids: out.summary_ids.clone(),
        stream_closed_pending: rest.stream_closed_deadline.is_some(),
    }
}

/// The one way to lock `Out`: a poisoned lock is the last holder's panic,
/// not this caller's, so the guard is recovered instead of panicking.
fn lock(mutex: &Mutex<Out>) -> MutexGuard<'_, Out> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Time left in a write budget started at `start`: `None` once spent. A
/// zero remainder is spent too: the OS rejects a zero socket timeout.
fn remaining(start: Instant, now: Instant, budget: Duration) -> Option<Duration> {
    match start
        .checked_add(budget)
        .and_then(|end| end.checked_duration_since(now))
    {
        Some(left) if !left.is_zero() => Some(left),
        _ => None,
    }
}

impl Out {
    /// One line within the sequence budget started at `start`: before every
    /// `write` call the timeout is recomputed from the time left, so a hub
    /// that drains a few bytes at a time cannot hold the lock past one
    /// deadline. A spent budget, a missing writer, or any write error but an
    /// interruption marks the connection `broken` and fails. A write that
    /// fails may have written part of a line, so nothing is written to a
    /// `broken` connection again.
    fn write_line(&mut self, line: &str, start: Instant) -> bool {
        let mut buf: Vec<u8> = Vec::with_capacity(line.len() + 1);
        buf.extend_from_slice(line.as_bytes());
        buf.push(b'\n');
        let mut at = 0;
        while at < buf.len() {
            let Some(left) = remaining(start, Instant::now(), self.deadline) else {
                self.broken = true;
                return false;
            };
            enum Outcome {
                Wrote(usize),
                Retry,
                Fail,
            }
            let outcome = match self.writer.as_mut() {
                None => Outcome::Fail,
                Some(writer) => {
                    if writer.set_write_timeout(Some(left)).is_err() {
                        Outcome::Fail
                    } else {
                        match writer.write(&buf[at..]) {
                            Ok(0) => Outcome::Fail,
                            Ok(n) => Outcome::Wrote(n),
                            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => Outcome::Retry,
                            Err(_) => Outcome::Fail,
                        }
                    }
                }
            };
            match outcome {
                Outcome::Wrote(n) => at += n,
                Outcome::Retry => continue,
                Outcome::Fail => {
                    self.broken = true;
                    return false;
                }
            }
        }
        match self.writer.as_mut() {
            Some(writer) => {
                if writer.flush().is_err() {
                    self.broken = true;
                    return false;
                }
                true
            }
            None => {
                self.broken = true;
                false
            }
        }
    }

    /// One locked write sequence with one budget: `start` is taken once for
    /// every line, so a `summary` subscribe plus its `close now` share one
    /// deadline. Skips silently when the connection is `broken` or `ended`.
    fn write_lines(&mut self, lines: &[String]) -> bool {
        if self.broken || self.ended {
            return false;
        }
        let start = Instant::now();
        for line in lines {
            if !self.write_line(line, start) {
                return false;
            }
        }
        true
    }
}

impl Out {
    fn new(deadline: Duration) -> Self {
        Out {
            writer: None,
            deadline: clamp_bound(deadline),
            broken: false,
            ended: false,
            session_id: None,
            subscribed: false,
            summary_sent: false,
            summary_ids: Vec::new(),
            close_now_id: None,
            close_now_ids: Vec::new(),
            close_now_open: false,
            intent: Intent::None,
            stopping: false,
            retried: false,
        }
    }

    /// One intent-checked locked write: the check and the write are one
    /// locked call, so no line goes out after the intent is set, after a
    /// `close now`, once stopping or ended, or on a broken connection.
    /// False stops the driver at once; the driver tells a failed intent
    /// write from a failed connection write by reading the intent.
    fn send_checked(&mut self, line: &str) -> bool {
        if self.intent != Intent::None
            || self.close_now_id.is_some()
            || self.stopping
            || self.ended
            || self.broken
        {
            return false;
        }
        self.write_lines(&[line.to_string()])
    }
}

impl Shared {
    fn new(deadline: Duration) -> Self {
        Shared {
            out: Mutex::new(Out::new(deadline)),
            #[cfg(test)]
            hooks: Hooks::live(),
        }
    }

    #[cfg(test)]
    fn with_hooks(deadline: Duration, hooks: Hooks) -> Self {
        Shared {
            out: Mutex::new(Out::new(deadline)),
            hooks,
        }
    }

    /// One best-effort `close now`. On a connection that holds no
    /// subscription it first sends a `summary` subscribe in the same locked
    /// write, then the `close now`, sharing one write budget; the hub
    /// dropped the subscription, so `close` alone would be rejected
    /// `not_subscribed` and the session would keep running. Runs at most
    /// once: a set `close_now_id`, an `ended` or a `broken` connection, or
    /// a run with no session to name all skip.
    fn close_now_once(&self) {
        let mut out = lock(&self.out);
        if out.close_now_id.is_some() || out.ended || out.broken {
            return;
        }
        let Some(session_id) = out.session_id.clone() else {
            return;
        };
        let mut lines = Vec::with_capacity(2);
        if !out.subscribed && !out.summary_sent {
            let summary_id = new_command_id();
            lines.push(subscribe_summary_command(&summary_id, &session_id));
            out.summary_ids.push(summary_id);
            out.summary_sent = true;
        }
        let close_id = new_command_id();
        lines.push(close_now_command(&close_id, &session_id));
        out.close_now_ids.push(close_id.clone());
        if out.write_lines(&lines) {
            out.close_now_id = Some(close_id);
            out.close_now_open = true;
        }
    }

    /// The one retry of a `close now` (F4, R16): after a `not_subscribed`
    /// rejection, or a `stream_closed` read with the `close now` unanswered.
    /// Skips an already-sent `summary` subscribe (R19): the hub would reject
    /// a subscribe at the held level, F6 would report it as a crash, and the
    /// retry's `close now` would not run. Runs once; write errors are
    /// ignored (the connection goes `broken` inside).
    fn retry_close_now(&self) {
        let mut out = lock(&self.out);
        if out.retried || out.ended || out.broken {
            return;
        }
        out.retried = true;
        let Some(session_id) = out.session_id.clone() else {
            return;
        };
        let mut lines = Vec::with_capacity(2);
        if !out.subscribed && !out.summary_sent {
            let summary_id = new_command_id();
            lines.push(subscribe_summary_command(&summary_id, &session_id));
            out.summary_ids.push(summary_id);
            out.summary_sent = true;
        }
        let close_id = new_command_id();
        lines.push(close_now_command(&close_id, &session_id));
        out.close_now_ids.push(close_id.clone());
        out.close_now_id = Some(close_id);
        out.close_now_open = true;
        out.write_lines(&lines);
    }
}

/// What the driver does with one hub answer for a known id.
enum Answer {
    /// Not ours: a protocol error (or the row's own text) naming it.
    Unknown,
    /// Ours, answered: keep reading.
    Ignore,
    /// Our `close now` was rejected `not_subscribed`: the retry went out.
    Retried,
    /// Our command was rejected: fail naming it.
    Fail(String),
}

/// The `code` and `message` of a hub rejection, with S1's defaults.
fn reject_parts(value: &serde_json::Value) -> (String, String) {
    let payload = value.get("payload");
    (
        payload
            .and_then(|p| p.get("code"))
            .and_then(|c| c.as_str())
            .unwrap_or("unknown")
            .to_string(),
        payload
            .and_then(|p| p.get("message"))
            .and_then(|m| m.as_str())
            .unwrap_or("")
            .to_string(),
    )
}

fn stream_closed_text() -> String {
    crash_text("hub closed the stream (stream_closed)".to_string())
}

/// The crash when an ack wait expires (R10): the command, the session when
/// known (a session whose cleanup is still unconfirmed may still be
/// running), and no wait.
fn ack_crash(session: Option<&str>, what: &str) -> String {
    let mut text = format!("no answer to `{what}` within the ack bound");
    if let Some(id) = session {
        text += &format!(" for session {id}; the session may still be running");
    }
    crash_text(text)
}

/// The crash when a stop finds no `fiber_exited` within `stop_wait`, or when
/// a stop ends before any verdict can arrive (R2, R14). Kill and cancel
/// differ only in this text (R7). A session whose `close now` went
/// unconfirmed may still be running.
fn stop_crash(shared: &Shared, session: Option<String>, reason: StopReason) -> String {
    let base = match reason {
        StopReason::Kill => "killed by the caller",
        StopReason::Cancel => "cancelled by the caller",
        StopReason::TurnStartWait => {
            "no turn_started within the turn-start bound; no fiber_exited within the stop bound"
        }
        StopReason::TurnWait => {
            "no verdict within the turn bound; no fiber_exited within the stop bound"
        }
    };
    let confirmed = {
        let out = lock(&shared.out);
        out.close_now_id.is_some() && !out.close_now_open
    };
    let mut text = base.to_string();
    if let Some(id) = session
        && !confirmed
    {
        text += &format!(" Session {id} gave no verdict; the session may still be running");
    }
    crash_text(text)
}

fn intent_reason(shared: &Shared) -> StopReason {
    match lock(&shared.out).intent {
        Intent::Kill => StopReason::Kill,
        // Only the intent can fail the intent-checked writes below; a missing
        // intent there is unreachable, and cancel is the milder text.
        Intent::Cancel | Intent::None => StopReason::Cancel,
    }
}

/// Classify one hub answer for the close, close-now or summary ids the
/// driver knows: the same set in the ack waits and the live loop (N4), so a
/// late answer is never a protocol error. Side effects (clearing
/// `close_now_open`, the one retry) happen under the one lock here.
fn note_answer(
    kind: &str,
    cid: &str,
    value: &serde_json::Value,
    known: &KnownIds,
    shared: &Shared,
) -> Answer {
    if known.close_id.as_deref() == Some(cid) {
        if kind == "command_accepted" {
            return Answer::Ignore;
        }
        let (code, message) = reject_parts(value);
        return Answer::Fail(crash_text(format!("hub rejected close: {code}: {message}")));
    }
    if kind == "command_accepted" {
        let is_known = known.close_now_ids.iter().any(|id| id == cid)
            || known.summary_ids.iter().any(|id| id == cid);
        if !is_known {
            return Answer::Unknown;
        }
        let mut out = lock(&shared.out);
        if out.close_now_id.as_deref() == Some(cid) {
            out.close_now_open = false;
            if known.stream_closed_pending {
                return Answer::Fail(stream_closed_text());
            }
        }
        return Answer::Ignore;
    }
    let (code, message) = reject_parts(value);
    if known.summary_ids.iter().any(|id| id == cid) {
        return Answer::Fail(crash_text(format!(
            "hub rejected subscribe at summary: {code}: {message}"
        )));
    }
    if !known.close_now_ids.iter().any(|id| id == cid) {
        return Answer::Unknown;
    }
    let (current, retried, session) = {
        let out = lock(&shared.out);
        (
            out.close_now_id.as_deref() == Some(cid),
            out.retried,
            out.session_id.clone(),
        )
    };
    if !current {
        // Stale: superseded by the retry, which the hub answers next (R16).
        return Answer::Ignore;
    }
    if !retried && code == "not_subscribed" {
        shared.retry_close_now();
        return Answer::Retried;
    }
    if !retried {
        return Answer::Fail(crash_text(format!(
            "hub rejected close now: {code}: {message}"
        )));
    }
    let mut text = format!("hub rejected close now {cid}: {code}: {message}");
    if let Some(id) = session {
        text += &format!(" Session {id} gave no verdict; the session may still be running");
    }
    Answer::Fail(crash_text(text))
}

/// What went wrong reading one hub line: EOF or a read error means the
/// connection is lost. Hub lines carry no cap, only client lines do: the hub
/// is local, so a line is read to its newline whatever its size.
#[derive(Debug, PartialEq)]
enum ReadErr {
    Lost(String),
}

/// What one fill of the read buffer found: a whole line, or a quiet socket
/// with the bytes so far kept in the caller's buffer.
#[derive(Debug)]
enum Read {
    Line(Vec<u8>),
    Pending,
}

/// What one poll of the socket found: a whole line, a quiet slice, or a
/// lost connection. Partial bytes survive a quiet slice and complete on a
/// later poll, so a line is never split or lost across `Tick`s.
#[derive(Debug)]
enum Next {
    Line(Vec<u8>),
    Tick,
    Lost,
}

/// Read one hub line into `partial`, keeping bytes across polls. A read
/// timeout (`WouldBlock` or `TimedOut`) keeps what arrived and reports
/// `Pending`; an interruption retries; EOF or any other error loses the
/// connection, as `read_line` always did. Bytes that keep arriving without a
/// newline yield too: once `budget` has passed since the call started, the
/// bytes so far stay in `partial` and the call reports `Pending`, so a
/// continuously trickling unfinished line cannot hold the caller past one
/// poll slice and the phase bounds still run.
fn read_line_into<R: BufRead>(
    reader: &mut R,
    partial: &mut Vec<u8>,
    budget: Duration,
) -> Result<Read, ReadErr> {
    read_line_into_at(reader, partial, budget, Instant::now)
}

/// The clock-injected core of `read_line_into`: the production caller passes
/// the wall clock, so behavior is unchanged; the yield test passes its manual
/// clock, so the budget proof advances time per fill instead of sleeping for
/// a real bound.
fn read_line_into_at<R: BufRead>(
    reader: &mut R,
    partial: &mut Vec<u8>,
    budget: Duration,
    clock: impl Fn() -> Instant,
) -> Result<Read, ReadErr> {
    enum Found {
        Done(usize),
        More(usize),
    }
    let start = clock();
    loop {
        let next = match reader.fill_buf() {
            Ok([]) => {
                return Err(ReadErr::Lost("connection closed".to_string()));
            }
            Ok(buf) => match buf.iter().position(|&b| b == b'\n') {
                Some(nl) => {
                    partial.extend_from_slice(&buf[..nl]);
                    Found::Done(nl + 1)
                }
                None => {
                    partial.extend_from_slice(buf);
                    Found::More(buf.len())
                }
            },
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                return Ok(Read::Pending);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(ReadErr::Lost(e.to_string())),
        };
        match next {
            Found::Done(n) => {
                reader.consume(n);
                return Ok(Read::Line(std::mem::take(partial)));
            }
            Found::More(n) => {
                reader.consume(n);
                if clock().saturating_duration_since(start) >= budget {
                    return Ok(Read::Pending);
                }
            }
        }
    }
}

/// Read one newline-terminated hub line, keeping partial bytes across reads.
/// Test-only from T3: the driver loop and `await_ack` moved to `next_line`,
/// so no production caller remains. Kept for the tests that still call it.
#[cfg(test)]
fn read_line<R: BufRead>(reader: &mut R) -> Result<Vec<u8>, ReadErr> {
    let mut partial = Vec::new();
    loop {
        // The fake side reads whole client lines, which always arrive
        // together; the budget only bounds one fill, and `Pending` retries.
        match read_line_into(reader, &mut partial, Duration::from_secs(15)) {
            Ok(Read::Line(line)) => return Ok(line),
            Ok(Read::Pending) => continue,
            Err(e) => return Err(e),
        }
    }
}

/// First 80 bytes of a line, for `protocol error` crash texts.
fn first80(raw: &[u8]) -> String {
    String::from_utf8_lossy(&raw[..raw.len().min(80)]).into_owned()
}

/// An open hub connection: the reader owns the socket, the writer lives
/// in the shared `Out`. Reads stay on the calling thread; every write
/// sequence locks `Out`. `partial` keeps the bytes of an unfinished line
/// across `Tick`s.
#[derive(Debug)]
struct HubConn {
    reader: BufReader<UnixStream>,
    partial: Vec<u8>,
    shared: Arc<Shared>,
}

/// Connect to the hub socket, read `hub_hello` and return the connection.
/// The hello wait is the one poll in this task: each slice is `poll_slice`
/// long and the whole wait is `ack_wait`. A version mismatch names the
/// hub's `fiber_version` in the error text.
fn connect(socket_path: &Path, bounds: &Bounds, shared: Arc<Shared>) -> Result<HubConn, String> {
    let show = socket_path.display().to_string();
    let stream = UnixStream::connect(socket_path)
        .map_err(|e| crash_text(format!("cannot connect to hub socket {show}: {e}")))?;
    let writer = stream
        .try_clone()
        .map_err(|e| crash_text(format!("cannot clone hub socket {show}: {e}")))?;
    lock(&shared.out).writer = Some(writer);
    let mut conn = HubConn {
        reader: BufReader::new(stream),
        partial: Vec::new(),
        shared,
    };
    let deadline = now(&conn.shared) + clamp_bound(bounds.ack_wait);
    let raw = loop {
        match conn.next_line(bounds.poll_slice) {
            Next::Line(raw) => break raw,
            Next::Tick => {
                // The hello-tick tap: a test holds the second half of the
                // hello until it observes this, so the split-hello test
                // proves a quiet slice was waited out instead of sleeping
                // for one.
                pause!(&conn.shared, Point::HelloTick);
                if now(&conn.shared) >= deadline {
                    return Err(crash_text(format!(
                        "no hub_hello within the ack bound from {show}"
                    )));
                }
            }
            Next::Lost => {
                return Err(crash_text(format!(
                    "cannot read hub_hello from {show}: connection lost"
                )));
            }
        }
    };
    // Later reads block, so the poll timeout comes off before the run
    // continues. The driver poll in T3 sets it again on every poll.
    let _ = conn.reader.get_ref().set_read_timeout(None);
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
    Ok(conn)
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
            let Some(s) = v.to_str() else {
                return Err(
                    "FIBER_HOME is set but not valid UTF-8; set it to an absolute path or unset it"
                        .to_string(),
                );
            };
            let path = PathBuf::from(s);
            if path.is_absolute() {
                Ok(path)
            } else {
                Err(format!(
                    "FIBER_HOME is relative ({s}); set it to an absolute path or unset it"
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
    let mut args = serde_json::Map::new();
    args.insert("workspace".to_string(), workspace.into());
    if !model.is_empty() {
        args.insert("model".to_string(), model.into());
    }
    args.insert("supervised".to_string(), true.into());
    serde_json::json!({
        "id": id,
        "command": "start",
        "args": args,
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

/// The cleanup subscribe: same shape, but at `summary`, which reads no log
/// and adds nothing to `clients`.
fn subscribe_summary_command(id: &str, session_id: &str) -> String {
    serde_json::json!({
        "id": id,
        "command": "subscribe",
        "session_id": session_id,
        "args": {"level": "summary"},
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
/// one best-effort `close now` cleanup when a session is open.
#[derive(Debug)]
enum Step {
    Continue,
    CloseOnce,
    End(BackendResult),
    Fail(String),
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
    /// One poll of the socket: a whole line, a quiet slice, or a lost
    /// connection. The poll lasts at most `poll_slice`; bytes of an
    /// unfinished line stay in `partial` across `Tick`s.
    fn next_line(&mut self, poll_slice: Duration) -> Next {
        let slice = clamp_bound(poll_slice);
        let _ = self.reader.get_ref().set_read_timeout(Some(slice));
        match read_line_into(&mut self.reader, &mut self.partial, slice) {
            Ok(Read::Line(line)) => Next::Line(line),
            Ok(Read::Pending) => Next::Tick,
            Err(ReadErr::Lost(_)) => Next::Lost,
        }
    }

    /// Test-only direct write: the driver writes only through the
    /// intent-checked `Out::send_checked` calls.
    #[cfg(test)]
    fn send(&mut self, line: &str) -> bool {
        lock(&self.shared.out).write_lines(&[line.to_string()])
    }

    /// Read until a `command_accepted` or `command_rejected` whose
    /// `payload.command_id` equals `id`. Every other line passes to
    /// `on_other` in arrival order (which no longer borrows `rest`: it
    /// only observes), then folds through the loop's own handler, so no
    /// line is lost while waiting. Answers for the known ids (the plain
    /// close, the close-now ids, the summary-subscribe ids) are the
    /// client's own commands: the live handler accepts the same set, so a
    /// late answer is never a protocol error. After every `Next` the stop
    /// and bound checks run, exactly as in the read loop (N4, R3).
    /// The seven arguments are the plan's call shape (N4): the wait's own
    /// data, the loop's state, the known ids, and the observer.
    #[allow(clippy::too_many_arguments)]
    fn await_ack(
        &mut self,
        id: &str,
        known: &mut KnownIds,
        rest: &mut Rest,
        shared: &Shared,
        wait: AckWait,
        live: bool,
        mut on_other: impl FnMut(&[u8]) -> Option<Step>,
    ) -> WaitOutcome {
        rest.ack = Some(wait);
        let outcome = loop {
            pause!(shared, Point::BeforeRead);
            match self.next_line(rest.bounds.poll_slice) {
                Next::Tick => {
                    if let Some(stop) = rest.check(shared, now(shared)) {
                        break WaitOutcome::Stopped(stop);
                    }
                }
                Next::Lost => break WaitOutcome::Lost,
                Next::Line(raw) => {
                    pause!(shared, Point::AfterLine);
                    // Rebuilt after the read, before the classify: a retry
                    // or a control-thread `close now` mints ids mid-wait.
                    *known = known_ids(rest, shared);
                    let (kind, value) = match parse_line(&raw) {
                        Ok(parsed) => parsed,
                        Err(_) => {
                            // Not JSON or kindless: the observer sees it
                            // first, then the handlers fail closed on it, as
                            // they always did.
                            if let Some(stop) = on_other(&raw) {
                                break WaitOutcome::Stopped(stop);
                            }
                            if live {
                                break WaitOutcome::Stopped(rest.handle_live(&raw, shared));
                            }
                            break WaitOutcome::Stopped(rest.handle_history(&raw));
                        }
                    };
                    let kind = kind.as_str();
                    if kind == "command_accepted" || kind == "command_rejected" {
                        // Answers never reach the observer: they end the
                        // wait, answer a known id, or fail closed.
                        let cid = value
                            .get("payload")
                            .and_then(|p| p.get("command_id"))
                            .and_then(|c| c.as_str());
                        let Some(cid) = cid else {
                            break WaitOutcome::Stopped(Step::Fail(crash_text(format!(
                                "protocol error: hub answer without command_id: {}",
                                first80(&raw)
                            ))));
                        };
                        if cid == id {
                            if kind == "command_accepted" {
                                let result = value
                                    .get("payload")
                                    .and_then(|p| p.get("result"))
                                    .cloned()
                                    .unwrap_or(serde_json::Value::Null);
                                break WaitOutcome::Ack(Ack::Accepted { result });
                            }
                            let (code, message) = reject_parts(&value);
                            break WaitOutcome::Ack(Ack::Rejected { code, message });
                        }
                        match note_answer(kind, cid, &value, known, shared) {
                            Answer::Ignore | Answer::Retried => {
                                if let Some(stop) = rest.check(shared, now(shared)) {
                                    break WaitOutcome::Stopped(stop);
                                }
                            }
                            Answer::Fail(text) => {
                                break WaitOutcome::Stopped(Step::Fail(text));
                            }
                            Answer::Unknown => {
                                break WaitOutcome::Stopped(Step::Fail(crash_text(format!(
                                    "protocol error: hub answer for unknown command {cid}"
                                ))));
                            }
                        }
                        continue;
                    }
                    if let Some(stop) = on_other(&raw) {
                        break WaitOutcome::Stopped(stop);
                    }
                    let step = if live {
                        rest.handle_live(&raw, shared)
                    } else {
                        rest.handle_history(&raw)
                    };
                    match step {
                        Step::Continue => {
                            if let Some(stop) = rest.check(shared, now(shared)) {
                                break WaitOutcome::Stopped(stop);
                            }
                        }
                        stop => break WaitOutcome::Stopped(stop),
                    }
                }
            }
        };
        rest.ack = None;
        outcome
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

/// A resumed run can be driven only when its replayed session start records
/// that a program owns the session.
fn resumed_supervised(fold: &[serde_json::Value]) -> bool {
    fold.iter().any(|line| {
        line.get("kind").and_then(|kind| kind.as_str()) == Some("session_started")
            && line
                .get("payload")
                .and_then(|payload| payload.get("supervised"))
                .and_then(|supervised| supervised.as_bool())
                == Some(true)
    })
}

fn resume_fold_end(kind: &str, value: &serde_json::Value, last_seq: u64) -> bool {
    kind == "session_started" || value.get("seq").and_then(|seq| seq.as_u64()) == Some(last_seq)
}

/// One supervised turn through the hub: connect, start or resume, subscribe
/// at `full`, send one `prompt`, read to `turn_completed`, `close`, then read
/// `fiber_exited` as the verdict. There is no `bin` field: nothing here spawns
/// anything.
#[derive(Clone)]
pub struct HubRequest {
    pub cwd: String,
    pub model: String,
    pub prompt: String,
    pub bounds: Bounds,
    /// Existing session id; when set, the client skips `start`.
    pub resume: Option<String>,
}

/// The run's handle from another thread: `kill` and `cancel` set the intent
/// under the lock, release the guard, and make sure a subscribed session
/// gets its `close now`. They never read the socket and never call `on`.
/// A later `kill` upgrades a pending `cancel` (R7).
#[derive(Clone, Debug)]
pub struct HubControl {
    shared: Arc<Shared>,
}

impl HubControl {
    pub fn kill(&self) {
        self.stop(Intent::Kill);
    }

    pub fn cancel(&self) {
        self.stop(Intent::Cancel);
    }

    fn stop(&self, intent: Intent) {
        // A set kill stays; anything else takes the new intent.
        let subscribed = {
            let mut out = lock(&self.shared.out);
            if intent == Intent::Kill || out.intent == Intent::None {
                out.intent = intent;
            }
            out.subscribed
        };
        // The guard is released before the close locks again (D): holding it
        // would self-deadlock, and `close_now_once` no-ops when it should.
        if subscribed {
            self.shared.close_now_once();
        }
    }
}

/// A turn that can be stopped from another thread: the control exists before
/// the connect, so a `kill` before the socket exists is not a panic (N2).
pub struct HubRun {
    pub control: HubControl,
    pub drive: Box<dyn FnOnce(EventFn<'_>) -> BackendResult + Send>,
}

/// Start one supervised turn: build the shared writer first, so the control
/// is live before the connect.
pub fn spawn_turn(req: HubRequest, socket: PathBuf) -> HubRun {
    let shared = Arc::new(Shared::new(req.bounds.write_deadline));
    let control = HubControl {
        shared: Arc::clone(&shared),
    };
    HubRun {
        control,
        drive: Box::new(move |on| {
            let result = drive_turn(&req, &socket, on, Arc::clone(&shared));
            lock(&shared.out).ended = true;
            result
        }),
    }
}

#[cfg(test)]
fn spawn_turn_with(req: HubRequest, socket: PathBuf, hooks: Hooks) -> HubRun {
    let shared = Arc::new(Shared::with_hooks(req.bounds.write_deadline, hooks));
    let control = HubControl {
        shared: Arc::clone(&shared),
    };
    HubRun {
        control,
        drive: Box::new(move |on| {
            let result = drive_turn(&req, &socket, on, Arc::clone(&shared));
            lock(&shared.out).ended = true;
            result
        }),
    }
}

/// Drive one supervised turn to a verdict. The client sends `prompt` itself
/// so it knows the command id C, never answers an approval, and ends the
/// session with `close`, reading `fiber_exited` as the verdict.
pub fn run_turn(req: &HubRequest, socket: &Path, on: EventFn<'_>) -> BackendResult {
    let run = spawn_turn(req.clone(), socket.to_path_buf());
    (run.drive)(on)
}

fn drive_turn(
    req: &HubRequest,
    socket: &Path,
    on: EventFn<'_>,
    shared: Arc<Shared>,
) -> BackendResult {
    let model = super::model_reference(&req.model).to_string();
    let mut conn = match connect(socket, &req.bounds, Arc::clone(&shared)) {
        Ok(ok) => ok,
        Err(text) => return crash_result(None, Vec::new(), text),
    };
    let mut rest = Rest::new(on, &req.bounds);
    let mut known = known_ids(&rest, &shared);
    let session_id = if let Some(session_id) = req.resume.as_ref() {
        session_id.clone()
    } else {
        // start: no session_id, no content, supervised.
        let start_id = new_command_id();
        if !lock(&shared.out).send_checked(&start_command(&start_id, &req.cwd, &model)) {
            if lock(&shared.out).intent == Intent::None {
                return rest.crash(lost_before_start_text(&start_id));
            }
            // N2: the intent was set before the `start` line was written: no
            // session to name, no `close`, and the run ends at once.
            return rest.crash(stop_crash(&shared, None, intent_reason(&shared)));
        }
        rest.start_id = start_id.clone();
        pause!(shared, Point::BeforeStartAnswer);
        match conn.await_ack(
            &start_id,
            &mut known,
            &mut rest,
            &shared,
            ack_deadline(&shared, &req.bounds, "start"),
            false,
            |_| None,
        ) {
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
        }
    };
    rest.session_id = Some(session_id.clone());
    lock(&shared.out).session_id = Some(session_id.clone());
    // subscribe at full, unless the run is stopping (R2, R14 F1/A).
    pause!(shared, Point::BeforeSubscribeWrite);
    let sub_id = new_command_id();
    if !lock(&shared.out).send_checked(&subscribe_command(&sub_id, &session_id)) {
        if lock(&shared.out).intent == Intent::None {
            return fail_with_cleanup(&mut conn, &mut rest, lost_text(&session_id));
        }
        // F1/A: the intent landed before the full `subscribe` went out:
        // summary-subscribe and `close now` on the known session id (R6, one
        // locked write), no full `subscribe`, no `prompt`, fail at once.
        shared.close_now_once();
        return fail_with_cleanup(
            &mut conn,
            &mut rest,
            stop_crash(&shared, Some(session_id), intent_reason(&shared)),
        );
    }
    rest.sub_id = sub_id.clone();
    pause!(shared, Point::BeforeSubscribeAck);
    let subscribe_wait = ack_deadline(&shared, &req.bounds, "subscribe");
    match conn.await_ack(
        &sub_id,
        &mut known,
        &mut rest,
        &shared,
        subscribe_wait,
        false,
        |_| None,
    ) {
        WaitOutcome::Ack(Ack::Accepted { result }) => {
            rest.last_seq = last_seq_of(&result);
            lock(&shared.out).subscribed = true;
            // R2: a stop observed while the ack was in flight armed the stop
            // while unsubscribed, so no `close now` has gone out yet. The ack
            // resolves the subscription now, so it goes out at once instead
            // of waiting for the stop wait to run its course.
            if lock(&shared.out).intent != Intent::None {
                shared.close_now_once();
            }
        }
        WaitOutcome::Ack(Ack::Rejected { code, message }) => {
            // A rejected resumed subscribe did not open this client's
            // subscription, so it must not issue cleanup commands.
            let text = crash_text(format!("hub rejected subscribe: {code}: {message}"));
            if req.resume.is_some() {
                return rest.crash(text);
            }
            lock(&shared.out).subscribed = false;
            return fail_with_cleanup(&mut conn, &mut rest, text);
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
        WaitOutcome::Lost => {
            return fail_with_cleanup(&mut conn, &mut rest, lost_text(&session_id));
        }
    }
    // prompt with the client-minted id C, unless the run is stopping: then
    // go to the read loop in the stopping state (R2).
    pause!(shared, Point::AfterSubscribeAck);
    let mut resume_buffer = Vec::new();
    if req.resume.is_some() {
        let Some(last_seq) = rest.last_seq else {
            return rest.crash(crash_text(format!(
                "session {session_id} was not started supervised; start a new job"
            )));
        };
        rest.ack = Some(subscribe_wait);
        let mut fold = Vec::new();
        loop {
            pause!(shared, Point::BeforeRead);
            match conn.next_line(rest.bounds.poll_slice) {
                Next::Tick => {
                    if let Some(Step::Fail(text)) = rest.check(&shared, now(&shared)) {
                        rest.ack = None;
                        return fail_with_cleanup(&mut conn, &mut rest, text);
                    }
                }
                Next::Lost => {
                    rest.ack = None;
                    return fail_with_cleanup(&mut conn, &mut rest, lost_text(&session_id));
                }
                Next::Line(raw) => {
                    let (kind, value) = match parse_line(&raw) {
                        Ok(parsed) => parsed,
                        Err(text) => {
                            rest.ack = None;
                            return fail_with_cleanup(&mut conn, &mut rest, text);
                        }
                    };
                    if kind == "repository_code_offered" {
                        rest.ack = None;
                        return fail_with_cleanup(&mut conn, &mut rest, repository_offer_text());
                    }
                    let fold_end = resume_fold_end(&kind, &value, last_seq);
                    fold.push(value);
                    resume_buffer.push(raw);
                    if fold_end {
                        break;
                    }
                    if let Some(Step::Fail(text)) = rest.check(&shared, now(&shared)) {
                        rest.ack = None;
                        return fail_with_cleanup(&mut conn, &mut rest, text);
                    }
                }
            }
        }
        rest.ack = None;
        if !resumed_supervised(&fold) {
            return rest.crash(crash_text(format!(
                "session {session_id} was not started supervised; start a new job"
            )));
        }
    }
    let prompt_id = new_command_id();
    pause!(shared, Point::BeforePromptWrite);
    // The prompt ack budget is one total (R17): a `turn_completed` read
    // before the ack folds and closes once but resets nothing, so the
    // deadline is fixed before the loop instead of minting a fresh one per
    // pass.
    let prompt_wait = ack_deadline(&shared, &req.bounds, "prompt");
    let prompt_sent =
        if lock(&shared.out).send_checked(&prompt_command(&prompt_id, &session_id, &req.prompt)) {
            rest.prompt_id = prompt_id.clone();
            true
        } else if lock(&shared.out).intent == Intent::None {
            return fail_with_cleanup(&mut conn, &mut rest, lost_text(&session_id));
        } else {
            false
        };
    for raw in &resume_buffer {
        let step = rest.handle_buffered(raw, &shared);
        let step = match step {
            Step::Continue | Step::CloseOnce => rest.check(&shared, now(&shared)).unwrap_or(step),
            end_or_fail => end_or_fail,
        };
        if let Some(done) = apply_step(&mut conn, &mut rest, step) {
            return done;
        }
    }
    let prompt_acked = if prompt_sent {
        loop {
            match conn.await_ack(
                &prompt_id,
                &mut known,
                &mut rest,
                &shared,
                prompt_wait,
                true,
                |_| None,
            ) {
                WaitOutcome::Ack(Ack::Accepted { .. }) => break true,
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
                    // A `turn_completed` read before the ack only folds and
                    // closes once: the wait ends at the ack line, so keep
                    // waiting for it.
                }
                WaitOutcome::Lost => {
                    return fail_with_cleanup(&mut conn, &mut rest, lost_text(&session_id));
                }
            }
        }
    } else {
        false
    };
    if prompt_acked {
        // Phase bounds run from the `prompt` ack to the verdict (R17).
        let at = now(&shared);
        rest.turn_start_deadline = Some(at + clamp_bound(rest.bounds.turn_start_wait));
        if let Some(turn_wait) = rest.bounds.turn_wait {
            rest.turn_wait_deadline = Some(at + clamp_bound(turn_wait));
        }
    }
    // The phase-entry tap: a deadline test advances the manual clock only
    // after observing this, so the turn bounds are already fixed when the
    // clock jumps instead of being raced by it.
    pause!(shared, Point::AfterPromptAck);
    // Read to the verdict, which stops the run at once.
    loop {
        pause!(shared, Point::BeforeRead);
        match conn.next_line(rest.bounds.poll_slice) {
            Next::Tick => {
                if let Some(stop) = rest.check(&shared, now(&shared))
                    && let Some(done) = apply_step(&mut conn, &mut rest, stop)
                {
                    return done;
                }
            }
            Next::Lost => {
                return fail_with_cleanup(&mut conn, &mut rest, lost_text(&session_id));
            }
            Next::Line(raw) => {
                pause!(shared, Point::AfterLine);
                let step = rest.handle_live(&raw, &shared);
                // The line first, then the stop and bound checks (R3).
                let step = match step {
                    Step::Continue | Step::CloseOnce => {
                        rest.check(&shared, now(&shared)).unwrap_or(step)
                    }
                    end_or_fail => end_or_fail,
                };
                if let Some(done) = apply_step(&mut conn, &mut rest, step) {
                    return done;
                }
            }
        }
    }
}

fn ack_deadline(shared: &Shared, bounds: &Bounds, what: &'static str) -> AckWait {
    AckWait {
        what,
        deadline: now(shared) + clamp_bound(bounds.ack_wait),
    }
}

/// The run's fold and gate state. The connection stays outside, so the ack
/// handlers can borrow both without aliasing.
struct Rest<'a> {
    state: super::FiberState,
    on: EventFn<'a>,
    bounds: Bounds,
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
    questions: Option<serde_json::Value>,
    stop: Option<Stop>,
    ack: Option<AckWait>,
    turn_start_deadline: Option<Instant>,
    turn_wait_deadline: Option<Instant>,
    stream_closed_deadline: Option<Instant>,
}

impl<'a> Rest<'a> {
    fn new(on: EventFn<'a>, bounds: &Bounds) -> Self {
        Rest {
            state: super::FiberState::default(),
            on,
            bounds: bounds.clone(),
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
            stop: None,
            ack: None,
            turn_start_deadline: None,
            turn_wait_deadline: None,
            stream_closed_deadline: None,
        }
    }

    fn crash(&mut self, text: String) -> BackendResult {
        crash_result(self.session_id.clone(), self.state.denial_list(), text)
    }

    /// One tick after the line of the pass (the line first, R3): arm or end
    /// the stop, or fail an expired ack wait. Returns `None` to keep reading.
    /// Never overrides a verdict: the caller consults it only when the line
    /// did not end the run.
    fn check(&mut self, shared: &Shared, now: Instant) -> Option<Step> {
        // The R16 retry waits for its answer or this deadline, then still
        // ends as the `stream_closed` crash.
        if let Some(deadline) = self.stream_closed_deadline
            && now >= deadline
        {
            return Some(Step::Fail(stream_closed_text()));
        }
        // A stop already under way ends at its deadline; a `fiber_exited`
        // read before then wins in the line handler, never here. A `kill`
        // upgrades a pending `cancel` (R7).
        if lock(&shared.out).intent == Intent::Kill
            && let Some(stop) = &mut self.stop
        {
            stop.reason = StopReason::Kill;
        }
        // R14: while a `start` or `subscribe` answer is awaited, the stop
        // deadline waits: the driver keeps reading that answer within
        // `ack_wait`, and only the ack bound can end the wait. A `kill`
        // during the wait still cleans up on the answer (R6), and a silent
        // hub still fails at the ack bound (R10), even with the intent set.
        let defer_stop = matches!(
            self.ack.as_ref().map(|ack| ack.what),
            Some("start" | "subscribe")
        );
        if !defer_stop
            && let Some(stop) = &self.stop
            && now >= stop.deadline
        {
            return Some(Step::Fail(stop_crash(
                shared,
                self.session_id.clone(),
                stop.reason,
            )));
        }
        // An unanswered ack ends the run at once (R10): a hub that does not
        // answer will not be trusted for a verdict.
        if let Some(ack) = &self.ack
            && now >= ack.deadline
        {
            return Some(Step::Fail(ack_crash(self.session_id.as_deref(), ack.what)));
        }
        if self.stop.is_some() {
            return None;
        }
        // The unwritten `start` fails in the driver (N2); here the intent
        // arms the stop. With a subscription the `close now` goes out at
        // once; without one the driver waits for the ack first (R2).
        if lock(&shared.out).intent != Intent::None {
            let reason = intent_reason(shared);
            self.stop = Some(Stop {
                reason,
                deadline: now + clamp_bound(self.bounds.stop_wait),
            });
            let subscribed = {
                let mut out = lock(&shared.out);
                out.stopping = true;
                out.subscribed
            };
            if subscribed {
                shared.close_now_once();
            }
            return None;
        }
        // Phase bounds are totals, not idle timers: a line that arrives
        // resets nothing (R17).
        if !self.turn_started
            && let Some(deadline) = self.turn_start_deadline
            && now >= deadline
        {
            self.stop = Some(Stop {
                reason: StopReason::TurnStartWait,
                deadline: now + clamp_bound(self.bounds.stop_wait),
            });
            lock(&shared.out).stopping = true;
            shared.close_now_once();
            return None;
        }
        if let Some(deadline) = self.turn_wait_deadline
            && now >= deadline
        {
            self.stop = Some(Stop {
                reason: StopReason::TurnWait,
                deadline: now + clamp_bound(self.bounds.stop_wait),
            });
            lock(&shared.out).stopping = true;
            shared.close_now_once();
            return None;
        }
        None
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

    /// Fold the buffered replay prefix after the prompt is sent. The first
    /// `session_started` line seeds state even though its sequence is at or
    /// below the subscribe fold point; other lines keep normal live admission.
    fn handle_buffered(&mut self, raw: &[u8], shared: &Shared) -> Step {
        let (kind, _) = match parse_line(raw) {
            Ok(parsed) => parsed,
            Err(text) => return Step::Fail(text),
        };
        if kind == "session_started" {
            self.fold(raw);
            Step::Continue
        } else {
            self.handle_live(raw, shared)
        }
    }

    /// Lines read once the fold point is known. A `stream_closed` drops the
    /// hub-side subscription, so it clears the subscription flags: the
    /// cleanup re-subscribes before the `close now`.
    fn handle_live(&mut self, raw: &[u8], shared: &Shared) -> Step {
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
                Some(cid) => {
                    let known = known_ids(self, shared);
                    match note_answer("command_accepted", cid, &value, &known, shared) {
                        Answer::Ignore | Answer::Retried => Step::Continue,
                        Answer::Fail(text) => Step::Fail(text),
                        Answer::Unknown => Step::Fail(crash_text(format!(
                            "protocol error: hub answer for unknown command {cid}"
                        ))),
                    }
                }
            },
            "command_rejected" => {
                let payload = value.get("payload");
                let cid = payload
                    .and_then(|p| p.get("command_id"))
                    .and_then(|c| c.as_str());
                match cid {
                    None => Step::Fail(crash_text(format!(
                        "protocol error: hub rejection without command_id: {}",
                        first80(raw)
                    ))),
                    Some(cid) => {
                        let known = known_ids(self, shared);
                        match note_answer("command_rejected", cid, &value, &known, shared) {
                            Answer::Ignore | Answer::Retried => Step::Continue,
                            Answer::Fail(text) => Step::Fail(text),
                            Answer::Unknown => {
                                let (code, message) = reject_parts(&value);
                                let command = self.command_name(cid).to_string();
                                Step::Fail(crash_text(format!(
                                    "hub rejected {command}: {code}: {message}"
                                )))
                            }
                        }
                    }
                }
            }
            "attention" | "device_changed" => Step::Continue,
            "session_left" => Step::Continue,
            "stream_closed" => {
                // R16: with a `close now` outstanding and unanswered, the old
                // subscription is gone, so retry at once and keep reading;
                // the run still ends as the `stream_closed` crash once the
                // retry is answered or its wait passes. Otherwise the R6 path:
                // clear, re-subscribe in the cleanup, fail at once (F).
                let outstanding = {
                    let out = lock(&shared.out);
                    out.close_now_id.is_some() && out.close_now_open && !out.retried
                };
                if outstanding {
                    {
                        let mut out = lock(&shared.out);
                        out.subscribed = false;
                        out.summary_sent = false;
                    }
                    shared.retry_close_now();
                    self.stream_closed_deadline =
                        Some(now(shared) + clamp_bound(self.bounds.stop_wait));
                    Step::Continue
                } else {
                    let mut out = lock(&shared.out);
                    out.subscribed = false;
                    out.summary_sent = false;
                    Step::Fail(stream_closed_text())
                }
            }
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
            // The hub speaks first and once: a later `hub_hello` is a
            // reply kind with no table row, so it fails closed instead
            // of folding as an event (rule 12).
            "hub_hello" => Step::Fail(crash_text(format!(
                "protocol error: hub_hello after the first line: {}",
                first80(raw)
            ))),
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
        if self.questions.is_none()
            && payload.is_some_and(|payload| super::questions_section(payload).is_some())
            && let Some(questions) = payload.and_then(|payload| payload.get("questions"))
        {
            self.questions = Some(questions.clone());
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
            Some(last) => match value.get("seq").and_then(|s| s.as_u64()) {
                None => true,
                Some(seq) => seq > last,
            },
        };
        if !live {
            return Step::Continue;
        }
        Step::End(self.pre_turn_exit(value))
    }

    /// Fold the verdict line and carry renderable turn questions into the
    /// exit payload when it has none. `finish` then selects NeedsContext (or
    /// DoneWithConcerns for a denial). A failed outcome still wins; Done needs
    /// an admitted `completed` turn.
    fn verdict(&mut self, raw: &[u8]) -> BackendResult {
        self.fold(raw);
        if let Some(questions) = self.questions.as_ref() {
            let exited_has_questions = self
                .state
                .exited
                .as_ref()
                .and_then(|exited| exited.get("payload"))
                .is_some_and(|payload| super::questions_section(payload).is_some());
            if !exited_has_questions
                && let Some(payload) = self
                    .state
                    .exited
                    .as_mut()
                    .and_then(|exited| exited.get_mut("payload"))
                    .and_then(serde_json::Value::as_object_mut)
            {
                payload.insert("questions".to_string(), questions.clone());
            }
        }
        let mut res = finish(std::mem::take(&mut self.state), true, "", None);
        if res.is_error == Some(false) {
            if let Some(outcome) = self.bad_outcome.as_deref() {
                res.is_error = Some(true);
                res.text = crash_text(format!("turn outcome {outcome}: the turn did not complete"));
            } else if !self.completed_ok {
                res.is_error = Some(true);
                res.text = crash_text("session exited without a completed turn".to_string());
            }
        }
        res
    }

    /// The turn never started: an error with the exit reason, never Done. It
    /// ends in its own fixed sentence, so hub text never ends the error.
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
        crash_result(
            self.session_id.clone(),
            self.state.denial_list(),
            format!(
                "session exited before the turn started ({reason})\nThe run ended before the turn started."
            ),
        )
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
                    // No plain `close` once a `close now` went out or the
                    // stop is under way (R12); the id is recorded only when
                    // the line went out, so no answer is ever awaited twice.
                    if lock(&conn.shared.out).send_checked(&close_command(&id, &session_id)) {
                        rest.close_id = Some(id);
                    }
                }
            }
            None
        }
        Step::End(result) => {
            // The verdict flag (R1): no command goes out after it, and a
            // late `kill` is a no-op. Set before the pause, so a stop that
            // lands in the pause still sends nothing.
            lock(&conn.shared.out).ended = true;
            pause!(&conn.shared, Point::AfterVerdictFlag);
            Some(result)
        }
        Step::Fail(text) => Some(fail_with_cleanup(conn, rest, text)),
    }
}

/// Crash after the `start` answer, on a live connection: one best-effort
/// `close now`, then the crash. The attempt re-subscribes at `summary` when
/// the connection holds no subscription, so it still lands after the hub
/// dropped the subscription. Skipped when no session is open or a `close
/// now` already went out. It still runs after a plain `close` went out: a
/// crash in a later turn would otherwise leave the session running.
fn fail_with_cleanup(conn: &mut HubConn, rest: &mut Rest, text: String) -> BackendResult {
    conn.shared.close_now_once();
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
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
            // The fake side needs no write deadline: plain blocking writes.
            self.writer
                .write_all(line.as_bytes())
                .expect("fake hub send");
            self.writer.write_all(b"\n").expect("fake hub send");
            self.writer.flush().expect("fake hub send");
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
        let conn = connect(&path, &Bounds::default(), test_shared()).expect("connect");
        drop(conn);
        assert!(join_fake(&path, rx).is_empty());
    }

    #[test]
    fn hello_schema_version_2_fails_with_the_rule_9_text() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(2), "9.9.9"));
        });
        let err = connect(&path, &Bounds::default(), test_shared()).unwrap_err();
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
        let err = connect(&path, &Bounds::default(), test_shared()).unwrap_err();
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
        let err = connect(&path, &Bounds::default(), test_shared()).unwrap_err();
        assert!(err.contains("protocol error"), "{err}");
        assert!(err.contains("this is not json"), "{err}");
        join_fake(&path, rx);
    }

    #[test]
    fn hello_wrong_kind_names_the_line() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&serde_json::json!({"kind":"command_accepted","payload":{}}).to_string());
        });
        let err = connect(&path, &Bounds::default(), test_shared()).unwrap_err();
        assert!(err.contains("protocol error"), "{err}");
        assert!(err.contains("command_accepted"), "{err}");
        join_fake(&path, rx);
    }

    #[test]
    fn missing_socket_fails_with_the_path_and_os_error() {
        let missing = PathBuf::from(format!("/tmp/dh-missing-{}", std::process::id()));
        let _ = std::fs::remove_file(&missing);
        let err = connect(&missing, &Bounds::default(), test_shared()).unwrap_err();
        assert!(err.contains(&*missing.to_string_lossy()), "{err}");
    }

    #[test]
    fn bounds_default_to_the_named_constants() {
        let bounds = Bounds::default();
        assert_eq!(bounds.ack_wait, ACK_WAIT);
        assert_eq!(bounds.turn_start_wait, TURN_START_WAIT);
        assert_eq!(bounds.turn_wait, None);
        assert_eq!(bounds.stop_wait, STOP_WAIT);
        assert_eq!(bounds.poll_slice, POLL_SLICE);
        assert_eq!(bounds.write_deadline, WRITE_DEADLINE);
    }

    #[test]
    fn zero_bounds_clamp_to_one_millisecond() {
        assert_eq!(clamp_bound(Duration::ZERO), Duration::from_millis(1));
        assert_eq!(
            clamp_bound(Duration::from_millis(1)),
            Duration::from_millis(1)
        );
        assert_eq!(
            clamp_bound(Duration::from_secs(30)),
            Duration::from_secs(30)
        );
    }

    /// A line split across three writes, with the fake held back on a
    /// channel between them, reads whole and in order: the bytes before
    /// each quiet slice stay in `partial` across the `Tick`s.
    #[test]
    fn line_split_across_three_writes_reads_whole() {
        let (first_tx, first_rx) = mpsc::channel::<()>();
        let (second_tx, second_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.writer.write_all(b"{\"kind\":").expect("first third");
            srv.writer.flush().expect("flush");
            first_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("first release");
            srv.writer.write_all(b"\"turn_").expect("second third");
            srv.writer.flush().expect("flush");
            second_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("second release");
            srv.writer.write_all(b"started\"}\n").expect("last third");
            srv.writer.flush().expect("flush");
        });
        let stream = UnixStream::connect(&path).expect("client connect");
        let mut conn = poll_conn(stream);
        let poll = Duration::from_millis(20);
        assert!(matches!(conn.next_line(poll), Next::Tick));
        first_tx.send(()).expect("release first");
        assert!(matches!(conn.next_line(poll), Next::Tick));
        second_tx.send(()).expect("release second");
        match conn.next_line(poll) {
            Next::Line(line) => assert_eq!(line, b"{\"kind\":\"turn_started\"}"),
            other => panic!("expected the whole line, got {other:?}"),
        }
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn quiet_socket_is_a_tick_and_a_closed_one_is_lost() {
        let (tx, gate) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |_srv| {
            gate.recv_timeout(Duration::from_secs(15)).expect("release");
        });
        let stream = UnixStream::connect(&path).expect("client connect");
        let mut conn = poll_conn(stream);
        assert!(matches!(
            conn.next_line(Duration::from_millis(20)),
            Next::Tick
        ));
        drop(conn);
        tx.send(()).expect("release");
        join_fake(&path, rx);

        let (quiet, quiet_rx) = spawn_fake(|_srv| {});
        let stream = UnixStream::connect(&quiet).expect("client connect");
        let mut conn = poll_conn(stream);
        assert!(matches!(
            conn.next_line(Duration::from_millis(20)),
            Next::Lost
        ));
        drop(conn);
        join_fake(&quiet, quiet_rx);
    }

    /// A silent hub hits the hello bound: the bound, not a real wait,
    /// decides. The clock jumps past `ack_wait` only after the hello wait
    /// proves it is polling by tapping a quiet slice.
    #[test]
    fn silent_hub_hits_the_hello_bound() {
        let (tx, gate) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |_srv| {
            gate.recv_timeout(Duration::from_secs(15)).expect("release");
        });
        let bounds = Bounds {
            ack_wait: Duration::from_millis(50),
            poll_slice: Duration::from_millis(5),
            ..Default::default()
        };
        let start = Instant::now();
        let (tick_tx, tick_rx) = mpsc::channel::<()>();
        let ticked = Arc::new(AtomicBool::new(false));
        let seen = Arc::clone(&ticked);
        let now = Arc::new(Mutex::new(start));
        let clock = Arc::clone(&now);
        let shared = Arc::new(Shared::with_hooks(
            Duration::from_secs(5),
            Hooks {
                clock: Box::new(move || *clock.lock().expect("clock")),
                pause: Some(Box::new(move |p| {
                    if p == Point::HelloTick && !seen.swap(true, Ordering::SeqCst) {
                        tick_tx.send(()).expect("tick");
                    }
                })),
            },
        ));
        let conn_rx = {
            let path = path.clone();
            let bounds = bounds.clone();
            let (conn_tx, conn_rx) = mpsc::channel();
            std::thread::spawn(move || {
                let _ = conn_tx.send(connect(&path, &bounds, shared));
            });
            conn_rx
        };
        // The hello wait entered and tapped a quiet slice: its deadline was
        // fixed at entry, so jumping past it now trips exactly this bound.
        tick_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("hello tick");
        *now.lock().expect("clock") += Duration::from_secs(2);
        let err = conn_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("connect returned")
            .unwrap_err();
        assert!(err.contains("no hub_hello within the ack bound"), "{err}");
        assert!(err.ends_with("The run ended without a verdict."), "{err}");
        tx.send(()).expect("release");
        join_fake(&path, rx);
    }

    /// The `Tick` arm of the hello wait keeps waiting: a hello whose first
    /// half arrives before a quiet slice still connects. The fake holds the
    /// second half until the test observes the client's quiet-slice tick, so
    /// the tick is proved instead of slept for: no scheduling can deliver
    /// both halves before the client reads.
    #[test]
    fn hello_after_a_quiet_slice_still_passes() {
        let line = hello(serde_json::json!(1), "9.9.9");
        let (tick_tx, tick_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            let half = line.len() / 2;
            srv.writer
                .write_all(&line.as_bytes()[..half])
                .expect("first half");
            srv.writer.flush().expect("flush");
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            srv.writer
                .write_all(&line.as_bytes()[half..])
                .expect("second half");
            srv.writer.write_all(b"\n").expect("newline");
            srv.writer.flush().expect("flush");
        });
        let bounds = Bounds {
            poll_slice: Duration::from_millis(10),
            ack_wait: Duration::from_secs(5),
            ..Default::default()
        };
        let shared = Arc::new(Shared::with_hooks(
            Duration::from_secs(5),
            Hooks {
                clock: Box::new(Instant::now),
                pause: Some(Box::new(move |p| {
                    if p == Point::HelloTick {
                        let _ = tick_tx.send(());
                    }
                })),
            },
        ));
        let conn_rx = {
            let path = path.clone();
            let bounds = bounds.clone();
            let (conn_tx, conn_rx) = mpsc::channel();
            std::thread::spawn(move || {
                let _ = conn_tx.send(connect(&path, &bounds, shared));
            });
            conn_rx
        };
        // The client tapped a quiet slice with only the first half in hand:
        // only now may the second half go out, so the tick above is the one
        // this test proves.
        tick_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("hello tick");
        go_tx.send(()).expect("fake");
        let conn = conn_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("connect returned")
            .expect("hello after a quiet slice");
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn cleanup_subscribe_is_at_summary_level() {
        assert_eq!(
            subscribe_summary_command("c_9", "s_36e63d22c39750e1"),
            r#"{"id":"c_9","command":"subscribe","session_id":"s_36e63d22c39750e1","args":{"level":"summary"}}"#
        );
    }

    #[test]
    fn remaining_counts_down_the_budget() {
        let base = Instant::now();
        assert_eq!(
            remaining(base, base, Duration::from_secs(5)),
            Some(Duration::from_secs(5))
        );
        assert_eq!(
            remaining(base, base + Duration::from_secs(2), Duration::from_secs(5)),
            Some(Duration::from_secs(3))
        );
        assert_eq!(
            remaining(base, base + Duration::from_secs(5), Duration::from_secs(5)),
            None
        );
        assert_eq!(
            remaining(base, base + Duration::from_secs(6), Duration::from_secs(5)),
            None
        );
    }

    /// A panic while holding `Shared.out` must not wedge the cleanup: the
    /// lock is recovered and the `close now` still goes out, exactly once.
    #[test]
    fn poisoned_lock_still_closes_now() {
        let (path, rx) = spawn_fake(|srv| {
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            assert_eq!(close["session_id"], "s_1");
        });
        let stream = UnixStream::connect(&path).expect("client connect");
        let shared = Arc::new(Shared::new(Duration::from_secs(5)));
        {
            let mut out = lock(&shared.out);
            out.writer = Some(stream);
            out.session_id = Some("s_1".to_string());
            out.subscribed = true;
        }
        let poisoned = Arc::clone(&shared);
        assert!(
            std::thread::spawn(move || {
                let _guard = lock(&poisoned.out);
                panic!("holding the lock across a panic");
            })
            .join()
            .is_err()
        );
        shared.close_now_once();
        let received = join_fake(&path, rx);
        assert_eq!(received.len(), 1);
    }

    /// One budget per sequence: a start already one budget in the past
    /// writes neither line and marks the connection `broken`, with no clock
    /// and no sleep (the start is passed explicitly, as `write_line`
    /// takes it; `write_lines` takes it once per call).
    #[test]
    fn spent_start_writes_neither_line_and_marks_broken() {
        let (path, rx) = spawn_fake(|_srv| {});
        let stream = UnixStream::connect(&path).expect("client connect");
        let mut out = Out::new(Duration::from_secs(5));
        out.writer = Some(stream);
        let start = Instant::now() - Duration::from_secs(10);
        assert!(!out.write_line("a", start));
        assert!(!out.write_lines(&["b".to_string()]));
        assert!(out.broken);
        assert!(join_fake(&path, rx).is_empty());
    }

    /// The pair shares one budget: when the writer is dead the cleanup ends
    /// `broken` with no id stored, and the fake sees no line after the
    /// stall.
    #[test]
    fn close_now_once_on_a_dead_writer_ends_broken() {
        let (path, rx) = spawn_fake(|srv| {
            srv.reader
                .get_ref()
                .set_read_timeout(Some(Duration::from_millis(200)))
                .expect("fake read timeout");
            match read_line(&mut srv.reader) {
                Err(ReadErr::Lost(_)) => {}
                Ok(line) => panic!(
                    "fake saw a line after the stall: {}",
                    String::from_utf8_lossy(&line)
                ),
            }
        });
        let stream = UnixStream::connect(&path).expect("client connect");
        stream
            .shutdown(std::net::Shutdown::Write)
            .expect("shut the writer");
        let shared = Arc::new(Shared::new(Duration::from_millis(1)));
        {
            let mut out = lock(&shared.out);
            out.writer = Some(stream);
            out.session_id = Some("s_1".to_string());
        }
        shared.close_now_once();
        assert!(lock(&shared.out).broken, "dead writer ends broken");
        assert!(lock(&shared.out).close_now_id.is_none());
        join_fake(&path, rx);
    }

    /// After a forced write error no later `close now` is attempted.
    #[test]
    fn broken_connection_takes_no_further_writes() {
        let (path, rx) = spawn_fake(|srv| {
            srv.reader
                .get_ref()
                .set_read_timeout(Some(Duration::from_millis(200)))
                .expect("fake read timeout");
            match read_line(&mut srv.reader) {
                Err(ReadErr::Lost(_)) => {}
                Ok(line) => panic!(
                    "fake saw a line after the stall: {}",
                    String::from_utf8_lossy(&line)
                ),
            }
        });
        let stream = UnixStream::connect(&path).expect("client connect");
        stream
            .shutdown(std::net::Shutdown::Write)
            .expect("shut the writer");
        let shared = Arc::new(Shared::new(Duration::from_millis(1)));
        {
            let mut out = lock(&shared.out);
            out.writer = Some(stream);
            out.session_id = Some("s_1".to_string());
            out.subscribed = true;
        }
        shared.close_now_once();
        assert!(lock(&shared.out).broken);
        shared.close_now_once();
        assert!(lock(&shared.out).close_now_id.is_none());
        join_fake(&path, rx);
    }

    /// A prompt bigger than the socket buffer stalls a fake that stopped
    /// reading: the write fails within the write deadline, the run ends as
    /// a lost connection, and no `close now` goes out after the stall.
    #[test]
    fn stalled_prompt_write_ends_as_a_lost_connection() {
        let big = "p".repeat(4 * 1024 * 1024);
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({})));
            // Stop reading: the client's prompt never fits the buffer.
            release_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("release");
        });
        let mut req = hub_request();
        req.prompt = big;
        req.bounds.write_deadline = Duration::from_millis(20);
        let res = run_turn(&req, &path, &|_| {});
        assert!(
            res.text
                .starts_with("No answer before the connection was lost."),
            "{}",
            res.text
        );
        assert!(res.text.contains("s_1"), "{}", res.text);
        assert!(res.text.contains("may still be running"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        release_tx.send(()).expect("release");
        let received = join_fake(&path, rx);
        assert_eq!(received_commands(&received), ["start", "subscribe"]);
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
        let mut buf = vec![b'q'; 40_000];
        buf.push(b'\n');
        let mut reader = SplitOnce {
            buf,
            split_at: 20_000,
            pos: 0,
        };
        let line = read_line(&mut reader).expect("split line");
        assert_eq!(line.len(), 40_000);
        assert!(line.iter().all(|&b| b == b'q'));
    }

    /// A `BufRead` that yields its bytes in two slices with no newline in
    /// the first, so `read_line` must keep partial bytes across reads. No
    /// clock is involved: the split point is fixed.
    struct SplitOnce {
        buf: Vec<u8>,
        split_at: usize,
        pos: usize,
    }

    impl std::io::Read for SplitOnce {
        fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
            let n = std::cmp::min(out.len(), self.buf.len() - self.pos);
            out[..n].copy_from_slice(&self.buf[self.pos..self.pos + n]);
            self.pos += n;
            Ok(n)
        }
    }

    impl BufRead for SplitOnce {
        fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
            if self.pos >= self.buf.len() {
                return Ok(&[]);
            }
            let end = if self.pos < self.split_at {
                self.split_at
            } else {
                self.buf.len()
            };
            Ok(&self.buf[self.pos..end])
        }

        fn consume(&mut self, amt: usize) {
            self.pos += amt;
        }
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
        let _abs_non_utf8 = crate::test_env::EnvGuard::set_os(
            "FIBER_HOME",
            std::os::unix::ffi::OsStringExt::from_vec(b"/tmp/\xff".to_vec()),
        );
        assert!(
            fiber_home().unwrap_err().contains("FIBER_HOME"),
            "absolute non-UTF-8 names the variable"
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
    fn start_command_omits_an_empty_model() {
        let line: serde_json::Value =
            serde_json::from_str(&start_command("c_1", "/w", "")).expect("json");
        assert!(line["args"].get("model").is_none(), "{line}");
        assert_eq!(line["args"]["workspace"], "/w");
        assert_eq!(line["args"]["supervised"], true);
        let kept: serde_json::Value =
            serde_json::from_str(&start_command("c_1", "/w", "m")).expect("json");
        assert_eq!(kept["args"]["model"], "m");
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

    fn test_shared() -> Arc<Shared> {
        Arc::new(Shared::new(Duration::from_secs(5)))
    }

    /// The arguments a direct `await_ack` test needs beyond the id: a fresh
    /// known set, a rest to fold into, and a generous ack deadline (the
    /// template fakes answer at once; expiry is covered at run level).
    fn ack_harness<'a>(
        conn: &HubConn,
        on: EventFn<'a>,
        what: &'static str,
    ) -> (KnownIds, Rest<'a>, Arc<Shared>, AckWait) {
        let shared = Arc::clone(&conn.shared);
        let rest = Rest::new(on, &Bounds::default());
        let wait = AckWait {
            what,
            deadline: now(&shared) + Duration::from_secs(60),
        };
        (KnownIds::default(), rest, shared, wait)
    }

    /// A client connection that only reads: the writer lives in `Out`, and
    /// these tests never write.
    fn poll_conn(stream: UnixStream) -> HubConn {
        HubConn {
            reader: BufReader::new(stream),
            partial: Vec::new(),
            shared: test_shared(),
        }
    }

    fn connect_pair(
        script: impl FnOnce(&mut FakeSrv) + Send + 'static,
    ) -> (HubConn, PathBuf, mpsc::Receiver<Vec<String>>) {
        let (path, rx) = spawn_fake(script);
        let conn = connect(&path, &Bounds::default(), test_shared()).expect("connect");
        (conn, path, rx)
    }

    #[test]
    fn start_answer_gives_the_session() {
        let (mut conn, path, rx) = connect_pair(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            assert_eq!(srv.recv(), start_command("c_1", "/w", "m"));
            srv.send(&accepted("c_1", serde_json::json!({"session_id": "s_9"})));
        });
        assert!(conn.send(&start_command("c_1", "/w", "m")));
        let on = |_| {};
        let (mut known, mut rest, shared, wait) = ack_harness(&conn, &on, "start");
        let WaitOutcome::Ack(Ack::Accepted { result }) =
            conn.await_ack("c_1", &mut known, &mut rest, &shared, wait, false, |_| None)
        else {
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
        assert!(conn.send(&start_command("c_1", "/w", "m")));
        let on = |_| {};
        let (mut known, mut rest, shared, wait) = ack_harness(&conn, &on, "start");
        let WaitOutcome::Ack(Ack::Rejected { code, message }) =
            conn.await_ack("c_1", &mut known, &mut rest, &shared, wait, false, |_| None)
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
            assert!(conn.send(&start_command("c_1", "/w", "m")));
            let on = |_| {};
            let (mut known, mut rest, shared, wait) = ack_harness(&conn, &on, "start");
            let WaitOutcome::Stopped(Step::Fail(text)) =
                conn.await_ack("c_1", &mut known, &mut rest, &shared, wait, false, |_| None)
            else {
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
        assert!(conn.send(&start_command("c_1", "/w", "m")));
        let on = |_| {};
        let (mut known, mut rest, shared, wait) = ack_harness(&conn, &on, "start");
        let WaitOutcome::Stopped(Step::Fail(text)) =
            conn.await_ack("c_1", &mut known, &mut rest, &shared, wait, false, |_| None)
        else {
            panic!("no protocol error");
        };
        assert!(text.contains("protocol error"), "{text}");
        assert!(text.contains("c_other"), "{text}");
        drop(conn);
        join_fake(&path, rx);
    }

    /// Lines before the ack reach the observer in arrival order. All three
    /// are history here, so the run-level non-JSON failure is pinned
    /// separately (`non_json_during_subscribe_wait_is_a_crash`): a non-JSON
    /// line can no longer pass an ack wait through, because the wait always
    /// folds through the loop's own handler now (N4).
    #[test]
    fn lines_before_the_ack_are_kept_in_order() {
        let first = serde_json::json!({"kind":"attention","seq":1}).to_string();
        let second = serde_json::json!({"kind":"session_left","seq":2}).to_string();
        let third = serde_json::json!({"kind":"device_changed","seq":3}).to_string();
        let (mut conn, path, rx) = connect_pair(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            srv.recv();
            srv.send(&serde_json::json!({"kind":"attention","seq":1}).to_string());
            srv.send(&serde_json::json!({"kind":"session_left","seq":2}).to_string());
            srv.send(&serde_json::json!({"kind":"device_changed","seq":3}).to_string());
            srv.send(&accepted("c_1", serde_json::json!({"session_id": "s_1"})));
        });
        assert!(conn.send(&start_command("c_1", "/w", "m")));
        let mut seen = Vec::new();
        let on = |_| {};
        let (mut known, mut rest, shared, wait) = ack_harness(&conn, &on, "start");
        let WaitOutcome::Ack(Ack::Accepted { .. }) =
            conn.await_ack("c_1", &mut known, &mut rest, &shared, wait, false, |raw| {
                seen.push(String::from_utf8_lossy(raw).into_owned());
                None
            })
        else {
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
        let mut conn = connect(&path, &Bounds::default(), test_shared()).expect("connect");
        let on = |_| {};
        let (mut known, mut rest, shared, wait) = ack_harness(&conn, &on, "start");
        let WaitOutcome::Lost =
            conn.await_ack("c_1", &mut known, &mut rest, &shared, wait, false, |_| None)
        else {
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
        assert!(conn.send(&start_command(&a, "/w", "m")));
        assert!(conn.send(&subscribe_command(&b, "s_1")));
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
        /// Shut down the hub side for writing, keeping it open for reading:
        /// the client reads EOF, and a best-effort write from the client
        /// still reaches the fake.
        fn shutdown_write(&mut self) {
            use std::net::Shutdown;
            self.writer
                .shutdown(Shutdown::Write)
                .expect("shutdown write");
        }

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
            bounds: Bounds::default(),
            resume: None,
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

    fn resume_request() -> HubRequest {
        let mut request = hub_request();
        request.resume = Some("s_9".to_string());
        request
    }

    fn run_resume_case(
        script: impl FnOnce(&mut FakeSrv) + Send + 'static,
    ) -> (BackendResult, Vec<String>) {
        let (path, rx) = spawn_fake(script);
        let res = run_turn(&resume_request(), &path, &|_| {});
        let received = join_fake(&path, rx);
        (res, received)
    }

    fn ev(kind: &str, seq: u64, payload: serde_json::Value) -> String {
        ev_for_session("s_1", kind, seq, payload)
    }

    fn ev_for_session(
        session_id: &str,
        kind: &str,
        seq: u64,
        payload: serde_json::Value,
    ) -> String {
        serde_json::json!({
            "kind": kind,
            "session_id": session_id,
            "ts": 1,
            "schema_version": 1,
            "seq": seq,
            "payload": payload,
        })
        .to_string()
    }

    fn resumed_session_started_ev(seq: u64, supervised: Option<bool>) -> String {
        let mut payload = serde_json::json!({
            "workspace": "/w",
            "variables": {"path": "/bin", "names": []},
        });
        if let Some(supervised) = supervised {
            payload["supervised"] = serde_json::json!(supervised);
        }
        ev_for_session("s_9", "session_started", seq, payload)
    }

    fn resumed_turn_started_ev(prompt_id: &str, seq: u64) -> String {
        ev_for_session(
            "s_9",
            "turn_started",
            seq,
            serde_json::json!({"input": [{
                "command_id": prompt_id,
                "content": [{"type": "text", "text": "go"}],
                "source": "driver",
                "type": "message",
            }]}),
        )
    }

    fn resumed_turn_completed_ev(seq: u64) -> String {
        ev_for_session(
            "s_9",
            "turn_completed",
            seq,
            serde_json::json!({"outcome": "completed"}),
        )
    }

    fn resumed_exited_ev(seq: u64, text: &str) -> String {
        ev_for_session(
            "s_9",
            "fiber_exited",
            seq,
            serde_json::json!({"exit_code": 0, "text": text}),
        )
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

    #[test]
    fn resumed_run_subscribes_without_start_and_uses_the_live_exit() {
        let activities = Arc::new(AtomicU64::new(0));
        let counted = Arc::clone(&activities);
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (sub_id, sub) = recv_id(srv);
            assert_eq!(sub["command"], "subscribe");
            assert_eq!(sub["session_id"], "s_9");
            assert_eq!(sub["args"]["level"], "full");
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 5})));
            srv.send(&resumed_session_started_ev(1, Some(true)));
            srv.send(&resumed_exited_ev(4, "stale"));
            let (prompt_id, prompt) = recv_id(srv);
            assert_eq!(prompt["command"], "prompt");
            assert_eq!(prompt["session_id"], "s_9");
            assert_eq!(prompt["args"]["content"][0]["text"], "go");
            srv.send(&accepted(&prompt_id, serde_json::json!({})));
            srv.send(&resumed_turn_started_ev(&prompt_id, 6));
            srv.send(&resumed_turn_completed_ev(7));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["session_id"], "s_9");
            srv.send(&resumed_exited_ev(8, "DONE"));
            srv.expect_eof();
        });
        let request = resume_request();
        let on = |event| {
            if matches!(event, Event::Activity) {
                counted.fetch_add(1, Ordering::SeqCst);
            }
        };
        let res = run_turn(&request, &path, &on);
        let received = join_fake(&path, rx);
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert!(res.clean_exit);
        assert_eq!(res.session_id.as_deref(), Some("s_9"));
        assert_eq!(activities.load(Ordering::SeqCst), 4);
        assert_eq!(
            received_commands(&received),
            ["subscribe", "prompt", "close"]
        );
        assert_eq!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit),
            crate::types::RunStatus::Done
        );
    }

    #[test]
    fn kill_before_resumed_subscribe_write_closes_known_session() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["session_id"], "s_9");
            assert_eq!(summary["args"]["level"], "summary");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["session_id"], "s_9");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            resume_request(),
            path.clone(),
            gate_hooks(Point::BeforeSubscribeWrite, gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let result_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused before subscribe");
        control.kill();
        gate_tx.send(()).expect("release driver");
        let res = result_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        let received = join_fake(&path, rx);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_9"));
        assert_eq!(res.is_error, Some(true));
        assert_eq!(received_commands(&received), ["subscribe", "close"]);
    }

    #[test]
    fn rejected_resumed_subscribe_sends_nothing_else() {
        let (res, received) = run_resume_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (sub_id, sub) = recv_id(srv);
            assert_eq!(sub["command"], "subscribe");
            assert_eq!(sub["session_id"], "s_9");
            srv.send(&rejected(Some(&sub_id), "session_not_found", "gone"));
            srv.expect_eof();
        });
        assert!(res.text.contains("session_not_found"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_9"));
        assert_eq!(res.is_error, Some(true));
        assert_eq!(received_commands(&received), ["subscribe"]);
    }

    #[test]
    fn resumed_run_refuses_a_missing_or_false_supervised_marker() {
        for supervised in [None, Some(false)] {
            let (res, received) = run_resume_case(move |srv| {
                srv.send(&hello(serde_json::json!(1), "9.9.9"));
                let (sub_id, _) = recv_id(srv);
                srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 5})));
                if let Some(supervised) = supervised {
                    srv.send(&resumed_session_started_ev(1, Some(supervised)));
                } else {
                    srv.send(&ev_for_session(
                        "s_9",
                        "assistant_message_delta",
                        5,
                        serde_json::json!({}),
                    ));
                }
                srv.expect_eof();
            });
            assert!(
                res.text
                    .contains("session s_9 was not started supervised; start a new job"),
                "{}",
                res.text
            );
            assert_eq!(res.session_id.as_deref(), Some("s_9"));
            assert_eq!(res.is_error, Some(true));
            assert_eq!(received_commands(&received), ["subscribe"]);
        }
    }

    #[test]
    fn resumed_fold_stops_on_the_last_seq_when_session_started_is_absent() {
        let (res, received) = run_resume_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 5})));
            srv.send(&ev_for_session(
                "s_9",
                "assistant_message_delta",
                4,
                serde_json::json!({}),
            ));
            srv.send(&ev_for_session(
                "s_9",
                "assistant_message_delta",
                5,
                serde_json::json!({}),
            ));
            srv.shutdown_write();
            srv.expect_eof();
        });
        assert!(
            res.text
                .contains("session s_9 was not started supervised; start a new job"),
            "{}",
            res.text
        );
        assert_eq!(received_commands(&received), ["subscribe"]);
    }

    #[test]
    fn resumed_fold_end_uses_session_start_or_exact_last_seq() {
        let value = |seq| serde_json::json!({"seq": seq});
        assert!(!resume_fold_end("assistant_message_delta", &value(4), 5));
        assert!(resume_fold_end("assistant_message_delta", &value(5), 5));
        assert!(!resume_fold_end("assistant_message_delta", &value(6), 5));
        assert!(resume_fold_end("session_started", &value(1), 5));
    }

    #[test]
    fn resumed_fold_without_last_seq_refuses_without_reading() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({})));
            srv.expect_eof();
        });
        let mut request = resume_request();
        request.bounds.ack_wait = Duration::from_millis(50);
        let res = run_turn(&request, &path, &|_| {});
        let received = join_fake(&path, rx);
        assert!(
            res.text
                .contains("session s_9 was not started supervised; start a new job"),
            "{}",
            res.text
        );
        assert_eq!(received_commands(&received), ["subscribe"]);
    }

    #[test]
    fn resumed_fold_read_uses_the_subscribe_ack_deadline() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (release_fake_tx, release_fake_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 5})));
            release_fake_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("test releases fake after deadline");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let (hooks, clock) =
            gated_clock(Instant::now(), Point::AfterSubscribeAck, gate_rx, fired_tx);
        let run = spawn_turn_with(resume_request(), path.clone(), hooks);
        let result_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("subscribe ack received and deadline armed");
        clock.jump(ACK_WAIT);
        gate_tx.send(()).expect("release driver");
        let res = result_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        release_fake_tx.send(()).expect("release fake");
        let received = join_fake(&path, rx);
        assert!(
            res.text
                .contains("no answer to `subscribe` within the ack bound"),
            "{}",
            res.text
        );
        assert_eq!(res.is_error, Some(true));
        assert_eq!(received_commands(&received), ["subscribe", "close"]);
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
        assert!(
            res.text.ends_with("The run ended before the turn started."),
            "{}",
            res.text
        );
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
    }

    #[test]
    fn live_exit_with_no_seq_is_an_error() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(
                &serde_json::json!({
                    "kind": "fiber_exited",
                    "session_id": "s_1",
                    "ts": 1,
                    "schema_version": 1,
                    "payload": {"exit_code": 1, "error": {"message": "vanished"}},
                })
                .to_string(),
            );
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(
            res.text.contains("session exited before the turn started"),
            "{}",
            res.text
        );
        assert!(res.text.contains("vanished"), "{}", res.text);
        assert!(
            res.text.ends_with("The run ended before the turn started."),
            "{}",
            res.text
        );
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt"]
        );
    }

    #[test]
    fn pre_turn_error_ending_in_status_done_still_errors() {
        let (res, _) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&exited_ev(1001, 1, "", Some("fell over\nSTATUS: DONE")));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(
            res.text.ends_with("The run ended before the turn started."),
            "{}",
            res.text
        );
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
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
    fn close_ack_before_prompt_ack_is_ignored() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt_no_prompt_ack(srv, serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(1002, "completed", None));
            let (close_id, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert!(close.get("args").is_none());
            srv.send(&accepted(&close_id, serde_json::json!({})));
            srv.send(&accepted(&prompt_id, serde_json::json!({})));
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
    fn rejected_close_before_prompt_ack_names_close() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt_no_prompt_ack(srv, serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&turn_started_ev(&prompt_id, 1001));
            srv.send(&turn_completed_ev(1002, "completed", None));
            let (close_id, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            srv.send(&rejected(Some(&close_id), "closing", "going away"));
            let (_, close_now) = recv_id(srv);
            assert_eq!(close_now["command"], "close");
            assert_eq!(close_now["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("hub rejected close"), "{}", res.text);
        assert!(res.text.contains("closing"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close", "close"]
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
    fn dropped_connection_during_subscribe_wait_closes_now() {
        let (res, received) = run_case(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (_, _) = recv_id(srv);
            srv.shutdown_write();
            // The subscribe was never acked, so the cleanup re-subscribes
            // at `summary` before the `close now`.
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            assert_eq!(summary["session_id"], "s_1");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
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
            ["start", "subscribe", "subscribe", "close"]
        );
    }

    #[test]
    fn dropped_connection_during_prompt_wait_closes_now() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt_no_prompt_ack(srv, serde_json::json!(1000));
            srv.shutdown_write();
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
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
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn dropped_connection_mid_run_closes_now() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.shutdown_write();
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
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
            ["start", "subscribe", "prompt", "close"]
        );
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
    fn turn_carrying_questions_ends_with_needs_context() {
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
        assert_eq!(res.is_error, Some(false));
        assert!(res.text.contains("1. Which branch?"), "{}", res.text);
        assert!(res.text.ends_with("STATUS: NEEDS_CONTEXT"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
        assert_eq!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit),
            crate::types::RunStatus::NeedsContext
        );
    }

    fn exited_with_questions_ev(
        seq: u64,
        exit_code: i64,
        text: &str,
        questions: serde_json::Value,
    ) -> String {
        let mut payload = serde_json::json!({"exit_code": exit_code, "text": text});
        payload["questions"] = questions;
        ev("fiber_exited", seq, payload)
    }

    #[test]
    fn exited_carrying_questions_ends_with_needs_context() {
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
            let (close_id, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert!(close.get("args").is_none());
            let _ = close_id;
            srv.send(&exited_with_questions_ev(
                1003,
                0,
                "waiting",
                serde_json::json!(["Which branch?"]),
            ));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(false));
        assert!(res.clean_exit);
        assert!(res.text.contains("1. Which branch?"), "{}", res.text);
        assert!(res.text.ends_with("STATUS: NEEDS_CONTEXT"), "{}", res.text);
        assert_eq!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit),
            crate::types::RunStatus::NeedsContext
        );
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    #[test]
    fn turn_and_exit_questions_choose_the_exit_payload_once() {
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
                Some(serde_json::json!(["turn question"])),
            ));
            let (_, _) = recv_id(srv);
            srv.send(&exited_with_questions_ev(
                1003,
                0,
                "waiting",
                serde_json::json!(["exit question"]),
            ));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(false));
        assert!(res.text.contains("1. exit question"), "{}", res.text);
        assert!(!res.text.contains("turn question"), "{}", res.text);
        assert_eq!(res.text.matches("Questions:").count(), 1, "{}", res.text);
        assert!(res.text.ends_with("STATUS: NEEDS_CONTEXT"), "{}", res.text);
    }

    #[test]
    fn turn_questions_with_a_denial_end_with_done_with_concerns() {
        let (res, _) = run_case(|srv| {
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
            srv.send(&turn_completed_ev(
                1005,
                "completed",
                Some(serde_json::json!(["Which branch?"])),
            ));
            let (_, _) = recv_id(srv);
            srv.send(&exited_ev(1006, 0, "waiting", None));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(false));
        assert!(res.text.contains("1. Which branch?"), "{}", res.text);
        assert!(
            res.text.ends_with("STATUS: DONE_WITH_CONCERNS"),
            "{}",
            res.text
        );
        assert_eq!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit),
            crate::types::RunStatus::DoneWithConcerns
        );
    }

    #[test]
    fn blank_exit_questions_fall_back_to_turn_questions() {
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
                Some(serde_json::json!(["turn question"])),
            ));
            let (_, _) = recv_id(srv);
            srv.send(&exited_with_questions_ev(
                1003,
                0,
                "waiting",
                serde_json::json!(["  "]),
            ));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(false));
        assert!(res.text.contains("1. turn question"), "{}", res.text);
        assert_eq!(res.text.matches("Questions:").count(), 1, "{}", res.text);
        assert!(res.text.ends_with("STATUS: NEEDS_CONTEXT"), "{}", res.text);
    }

    #[test]
    fn non_object_exit_payload_skips_turn_question_copy() {
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
                Some(serde_json::json!(["Which branch?"])),
            ));
            let (_, _) = recv_id(srv);
            srv.send(&ev(
                "fiber_exited",
                1003,
                serde_json::json!("not an object"),
            ));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(!res.text.contains("Which branch?"), "{}", res.text);
        assert!(
            !res.text.lines().any(|line| line.starts_with("STATUS:")),
            "{}",
            res.text
        );
    }

    #[test]
    fn cancelled_turn_questions_stay_an_error_without_needs_context_status() {
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
                "cancelled",
                Some(serde_json::json!(["Which branch?"])),
            ));
            let (_, _) = recv_id(srv);
            srv.send(&exited_ev(1003, 0, "waiting", None));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(!res.text.ends_with("STATUS: NEEDS_CONTEXT"), "{}", res.text);
        assert_eq!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit),
            crate::types::RunStatus::Error
        );
    }

    #[test]
    fn nonzero_exit_with_turn_questions_has_no_status_line() {
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
                Some(serde_json::json!(["Which branch?"])),
            ));
            let (_, _) = recv_id(srv);
            srv.send(&exited_ev(1003, 1, "failed", None));
            srv.expect_eof();
        });
        assert_eq!(res.is_error, Some(true));
        assert!(
            !res.text.lines().any(|line| line.starts_with("STATUS:")),
            "{}",
            res.text
        );
        assert_eq!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit),
            crate::types::RunStatus::Error
        );
    }

    #[test]
    fn exited_with_empty_or_null_questions_stays_done() {
        for questions in [serde_json::json!([]), serde_json::json!(null)] {
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
                srv.send(&exited_with_questions_ev(1003, 0, "DONE", questions));
                srv.expect_eof();
            });
            assert_eq!(res.text, "DONE");
            assert_eq!(res.is_error, Some(false));
        }
    }

    #[test]
    fn empty_null_or_blank_turn_questions_do_not_spoil_done() {
        for questions in [
            serde_json::json!([]),
            serde_json::json!(null),
            serde_json::json!(["  "]),
        ] {
            let (res, _) = run_case(|srv| {
                handshake_to_prompt(srv, &[], serde_json::json!(1000));
                let prompt_id =
                    serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                        .expect("prompt")["id"]
                        .as_str()
                        .expect("id")
                        .to_string();
                srv.send(&turn_started_ev(&prompt_id, 1001));
                srv.send(&turn_completed_ev(1002, "completed", Some(questions)));
                let (_, _) = recv_id(srv);
                srv.send(&exited_ev(1003, 0, "DONE", None));
                srv.expect_eof();
            });
            assert_eq!(res.text, "DONE");
            assert_eq!(res.is_error, Some(false));
        }
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
    fn session_left_is_ignored() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicUsize, Ordering};
        let activity = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&activity);
        let (path, rx) = spawn_fake(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            let prompt_id =
                serde_json::from_str::<serde_json::Value>(&received_last(&srv.received))
                    .expect("prompt")["id"]
                    .as_str()
                    .expect("id")
                    .to_string();
            srv.send(&ev("session_left", 1001, serde_json::json!({})));
            srv.send(&turn_started_ev(&prompt_id, 1002));
            srv.send(&ev("session_left", 1003, serde_json::json!({})));
            srv.send(&turn_completed_ev(1004, "completed", None));
            srv.send(&exited_ev(1005, 0, "DONE", None));
            let (_, _) = recv_id(srv);
            srv.expect_eof();
        });
        let res = run_turn(&hub_request(), &path, &|event| {
            if matches!(event, crate::backends::types::Event::Activity) {
                counted.fetch_add(1, Ordering::SeqCst);
            }
        });
        let received = join_fake(&path, rx);
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(activity.load(Ordering::SeqCst), 3);
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
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert_offer_crash(
            &res,
            &received,
            &["start", "subscribe", "subscribe", "close"],
        );
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

    #[test]
    fn repository_offer_after_close_gets_close_now() {
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
            assert!(close.get("args").is_none());
            srv.send(&offer_ev(1003));
            let (_, close_now) = recv_id(srv);
            assert_eq!(close_now["command"], "close");
            assert_eq!(close_now["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("repository_code_offered"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close", "close"]
        );
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
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            assert_eq!(summary["session_id"], "s_1");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("session_held"), "{}", res.text);
        assert!(res.text.contains("subscribe"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert!(
            res.text.ends_with("The run ended without a verdict."),
            "{}",
            res.text
        );
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "subscribe", "close"]
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

    #[test]
    fn turn_completed_before_the_prompt_ack_still_closes_once() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt_no_prompt_ack(srv, serde_json::json!(1000));
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
            assert!(close.get("args").is_none());
            srv.send(&accepted(&prompt_id, serde_json::json!({})));
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
    fn exited_before_the_prompt_ack_is_the_verdict() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt_no_prompt_ack(srv, serde_json::json!(1000));
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
            srv.send(&exited_ev(1003, 0, "DONE", None));
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
            let (_, close_now) = recv_id(srv);
            assert_eq!(close_now["command"], "close");
            assert_eq!(close_now["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("closing"), "{}", res.text);
        assert!(res.text.contains("close"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close", "close"]
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
    fn stream_closed_is_a_crash_with_cleanup() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&ev("stream_closed", 1001, serde_json::json!({})));
            // The hub dropped the subscription with the stream, so the
            // cleanup re-subscribes at `summary` before the `close now`.
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            assert_eq!(summary["session_id"], "s_1");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("stream_closed"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "subscribe", "close"]
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
    fn hub_hello_mid_run_is_a_crash_with_cleanup() {
        let (res, received) = run_case(|srv| {
            handshake_to_prompt(srv, &[], serde_json::json!(1000));
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("hub_hello"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
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
        assert!(
            res.text.ends_with("The run ended without a verdict."),
            "{}",
            res.text
        );
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
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        assert!(res.text.contains("protocol error"), "{}", res.text);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "subscribe", "close"]
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

    /// A seam pause that blocks once at `point` on `gate`, telling `fired`
    /// first. Every blocking wait here carries a deadline, so a stuck
    /// driver fails the test instead of hanging it.
    fn gate_hooks(point: Point, gate: mpsc::Receiver<()>, fired: mpsc::Sender<()>) -> Hooks {
        let done = Arc::new(AtomicBool::new(false));
        let gate = Arc::new(Mutex::new(gate));
        Hooks {
            clock: Box::new(Instant::now),
            pause: Some(Box::new(move |p| {
                if p == point && !done.swap(true, Ordering::SeqCst) {
                    fired.send(()).expect("fired");
                    gate.lock()
                        .expect("gate")
                        .recv_timeout(Duration::from_secs(15))
                        .expect("release");
                }
            })),
        }
    }

    /// Run the drive on its own thread; the verdict arrives on the channel.
    /// A bare `join` has no deadline, so the result travels by channel with
    /// a `recv_timeout` at the test.
    fn drive_async(run: HubRun) -> mpsc::Receiver<BackendResult> {
        let (res_tx, res_rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = res_tx.send((run.drive)(&|_| {}));
        });
        res_rx
    }

    fn short_stop_bounds() -> Bounds {
        Bounds {
            stop_wait: Duration::from_millis(50),
            poll_slice: Duration::from_millis(5),
            ..Default::default()
        }
    }

    /// N2: the intent is set before the socket exists. The run connects and
    /// reads `hub_hello`, then the intent-checked `start` write finds the intent and writes
    /// nothing: the fake sees no `start`, and the run ends at once as the
    /// stop crash with no session id.
    #[test]
    fn kill_before_the_socket_exists_writes_nothing() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            srv.expect_eof();
        });
        // The run and its control drop at the end of the block, closing the
        // writer the `close now` would have used: the fake then sees EOF.
        let res = {
            let run = spawn_turn(hub_request(), path.clone());
            let control = run.control.clone();
            control.kill();
            (run.drive)(&|_| {})
        };
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id, None);
        assert!(
            res.text.ends_with("The run ended without a verdict."),
            "{}",
            res.text
        );
        assert_eq!(res.is_error, Some(true));
        assert!(join_fake(&path, rx).is_empty());
    }

    /// F1: a kill during the start wait keeps reading the start answer
    /// within `ack_wait`; on the answer it summary-subscribes and sends
    /// `close now` on that session id (R6, one locked write), no full
    /// subscribe, no prompt, and the run ends as the stop crash.
    #[test]
    fn kill_during_the_start_wait_fails_with_the_kill_text() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            assert_eq!(summary["session_id"], "s_1");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            assert_eq!(close["session_id"], "s_1");
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            gate_hooks(Point::BeforeStartAnswer, gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert!(
            res.text.ends_with("The run ended without a verdict."),
            "{}",
            res.text
        );
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// F1 with `cancel`: the same path ends as the cancel text (R7).
    #[test]
    fn cancel_during_the_start_wait_fails_with_the_cancel_text() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            gate_hooks(Point::BeforeStartAnswer, gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.cancel();
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("cancelled by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert!(
            res.text.ends_with("The run ended without a verdict."),
            "{}",
            res.text
        );
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// F1 second case (clock): the fake never answers `start` and the clock
    /// jumps past `ack_wait`. The expiry is a crash at once (R10): no
    /// `close`, no stop wait, even with the intent set. No real bound is
    /// waited out.
    #[test]
    fn unanswered_start_hits_the_ack_bound_despite_the_intent() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (_, _) = recv_id(srv);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.ack_wait = Duration::from_millis(20);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (hooks, ctl) = gated_clock(Instant::now(), Point::BeforeStartAnswer, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        gate_tx.send(()).expect("release");
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(
            res.text
                .contains("no answer to `start` within the ack bound"),
            "{}",
            res.text
        );
        assert_eq!(res.session_id, None);
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(received_commands(&join_fake(&path, rx)), ["start"]);
    }

    /// R14 (clock): a kill during the start wait defers the stop deadline
    /// until the start answer resolves. The clock jumps past the default 10 s
    /// `stop_wait` while the answer is in flight but short of the 30 s
    /// `ack_wait`; the late answer still cleans up (summary subscribe, `close
    /// now`) and the run ends as the kill crash with the session id. Without
    /// the deferral the stop would fire mid-wait and the started session
    /// would never be cleaned up: flip the `defer_stop` guard in `check` and
    /// this fails with a session-less stop crash and no cleanup lines.
    #[test]
    fn kill_during_the_start_wait_survives_past_the_stop_deadline() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (answer_tx, answer_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            answer_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("answer go");
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            // Bounded wait for the cleanup: without the deferral the driver
            // is already gone and nothing arrives.
            let mut partial = Vec::new();
            let mut summary = false;
            let mut close = false;
            for _ in 0..150 {
                match read_line_into(&mut srv.reader, &mut partial, Duration::from_millis(20)) {
                    Ok(Read::Line(raw)) => {
                        let line = String::from_utf8(raw).expect("fake hub keeps lines UTF-8");
                        let value: serde_json::Value =
                            serde_json::from_str(&line).expect("hub line json");
                        srv.received.push(line);
                        if value["command"] == "subscribe" && value["args"]["level"] == "summary" {
                            summary = true;
                        }
                        if value["command"] == "close" && value["args"]["now"] == true {
                            close = true;
                        }
                        if summary && close {
                            break;
                        }
                    }
                    Ok(Read::Pending) => {}
                    Err(ReadErr::Lost(detail)) => {
                        panic!("fake hub lost the connection: {detail}")
                    }
                }
            }
            assert!(summary, "no summary subscribe after the late start answer");
            assert!(close, "no close now after the late start answer");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.poll_slice = Duration::from_millis(5);
        let (hooks, ctl) = gated_clock(Instant::now(), Point::BeforeStartAnswer, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        gate_tx.send(()).expect("release");
        ctl.fresh(2);
        // Past the 10 s stop wait, short of the 30 s ack bound.
        ctl.jump(Duration::from_secs(15));
        // The deferral holds the driver in the start wait past the jumped
        // stop deadline: two fresh polls prove it is still waiting instead
        // of asserting silent seconds. Without the deferral the driver
        // already crashed here, so no poll ever taps and this fails.
        ctl.fresh(2);
        answer_tx.send(()).expect("fake");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// A: a kill between the start answer and the subscribe write. The
    /// the intent-checked `subscribe` write finds the intent and writes nothing; the driver
    /// takes the F1 path: summary subscribe, `close now`, no full
    /// subscribe, no prompt, kill crash with the session id.
    #[test]
    fn kill_before_the_subscribe_write_skips_the_full_subscribe() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            gate_hooks(Point::BeforeSubscribeWrite, gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// A with `cancel`, and the same stop-crash shape. The no-kill control
    /// case is every `handshake_to_prompt` run: the full subscribe at
    /// `full` goes out when no intent is set.
    #[test]
    fn cancel_before_the_subscribe_write_skips_the_full_subscribe() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["args"]["level"], "summary");
            let (_, close) = recv_id(srv);
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            gate_hooks(Point::BeforeSubscribeWrite, gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.cancel();
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("cancelled by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// R2: a kill during the subscribe wait. After the ack the driver does
    /// not send the prompt (clock): the run goes to the read loop in the
    /// stopping state, the `close now` goes out once, and the stop wait ends
    /// as the kill crash when no `fiber_exited` comes. The stop wait ends by
    /// jump, never by a real wait.
    #[test]
    fn kill_during_the_subscribe_wait_skips_the_prompt() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, sub) = recv_id(srv);
            assert_eq!(sub["command"], "subscribe");
            assert_eq!(sub["args"]["level"], "full");
            release_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("release");
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds = short_stop_bounds();
        let (hooks, ctl) =
            gated_clock(Instant::now(), Point::BeforeSubscribeAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        gate_tx.send(()).expect("release");
        release_tx.send(()).expect("fake");
        // Two fresh polls prove the stop armed before the jump ends it; the
        // deferred stop (R14) keeps a pre-answer jump from ending the wait.
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// R2 (clock): a stop observed during the subscribe wait arms the stop
    /// while unsubscribed; accepting the ack sends the `close now` at once,
    /// alone (the subscription just resolved, so no summary re-subscribe),
    /// instead of waiting for the stop wait. The clock stays frozen until
    /// the close is seen, so an un-advanced stop can never fire: the close
    /// proves immediacy. Flip the ack-branch `close_now_once` away and the
    /// fake's bounded wait finds no close.
    #[test]
    fn subscribe_ack_with_pending_kill_closes_now_at_once() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (answer_tx, answer_rx) = mpsc::channel::<()>();
        let (close_tx, close_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, sub) = recv_id(srv);
            assert_eq!(sub["command"], "subscribe");
            assert_eq!(sub["args"]["level"], "full");
            answer_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("answer go");
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            // Bounded wait for the immediate close: the frozen stop never
            // fires, so only the ack-branch send passes.
            let mut partial = Vec::new();
            let mut seen = false;
            for _ in 0..150 {
                match read_line_into(&mut srv.reader, &mut partial, Duration::from_millis(20)) {
                    Ok(Read::Line(raw)) => {
                        let line = String::from_utf8(raw).expect("fake hub keeps lines UTF-8");
                        let value: serde_json::Value =
                            serde_json::from_str(&line).expect("hub line json");
                        srv.received.push(line);
                        assert_eq!(value["command"], "close");
                        assert_eq!(value["args"]["now"], true);
                        assert_eq!(value["session_id"], "s_1");
                        seen = true;
                        break;
                    }
                    Ok(Read::Pending) => {}
                    Err(ReadErr::Lost(detail)) => {
                        panic!("fake hub lost the connection: {detail}")
                    }
                }
            }
            assert!(seen, "no close now right after the subscribe ack");
            close_tx.send(()).expect("test");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds = short_stop_bounds();
        let (hooks, ctl) =
            gated_clock(Instant::now(), Point::BeforeSubscribeAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        gate_tx.send(()).expect("release");
        ctl.fresh(2);
        answer_tx.send(()).expect("fake");
        // The close arrived before any jump: the stop wait was still frozen.
        close_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("immediate close");
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// After the subscribe ack, kill first (clock): the intent is set before
    /// the prompt write, so the driver skips the prompt and stops. The stop
    /// wait ends by jump, never by a real wait.
    #[test]
    fn kill_after_the_subscribe_ack_skips_the_prompt() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds = short_stop_bounds();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::AfterSubscribeAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        gate_tx.send(()).expect("release");
        // Two fresh polls prove the stop armed before the jump ends it.
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// An every-pass `BeforeRead` gate while `armed` is set: each read waits
    /// for one `gate` release and tells `fired`. The test disarms it once
    /// the driver is past the orchestrated passes.
    fn armed_gate(
        armed: Arc<AtomicBool>,
        gate: mpsc::Receiver<()>,
        fired: mpsc::Sender<()>,
    ) -> Hooks {
        let gate = Arc::new(Mutex::new(gate));
        Hooks {
            clock: Box::new(Instant::now),
            pause: Some(Box::new(move |p| {
                if p == Point::BeforeRead && armed.load(Ordering::SeqCst) {
                    fired.send(()).expect("fired");
                    gate.lock()
                        .expect("gate")
                        .recv_timeout(Duration::from_secs(15))
                        .expect("release");
                }
            })),
        }
    }

    /// A seam pause that only tells `fired` once at `point` and never
    /// blocks: for flows where the test, not the driver, sets the pace.
    fn signal_hooks(point: Point, fired: mpsc::Sender<()>) -> Hooks {
        let done = Arc::new(AtomicBool::new(false));
        Hooks {
            clock: Box::new(Instant::now),
            pause: Some(Box::new(move |p| {
                if p == point && !done.swap(true, Ordering::SeqCst) {
                    fired.send(()).expect("fired");
                }
            })),
        }
    }

    /// A clock the test moves by hand: frozen until the test advances it.
    /// The cases marked "clock" use it, directly or through `ticking_clock`
    /// and `gated_clock` below; verdict- and channel-driven tests need no
    /// clock at all.
    fn manual_clock(start: Instant) -> (Hooks, Arc<Mutex<Instant>>) {
        let now = Arc::new(Mutex::new(start));
        let tick = Arc::clone(&now);
        (
            Hooks {
                clock: Box::new(move || *tick.lock().expect("clock")),
                pause: None,
            },
            now,
        )
    }

    /// The test side of a manual clock: `jump` moves time, and `fresh`
    /// counts only polls newer than the test's last signal, so a wait-entry
    /// deadline is always fixed before the clock jumps instead of being
    /// raced by it. Taps pile up while the test does other work, so every
    /// tap carries its sequence number and stale ones never count.
    struct ClockCtl {
        clock: Arc<Mutex<Instant>>,
        ticks: mpsc::Receiver<u64>,
        seq: Arc<AtomicU64>,
    }

    impl ClockCtl {
        /// Advance the test clock: the only way a deadline-test bound
        /// expires. Jumps here stay far below the default 30 s/120 s/10 s
        /// bounds, so each jump trips only the short bound under test.
        fn jump(&self, by: Duration) {
            *self.clock.lock().expect("clock") += by;
        }

        /// Consume taps until `n` polls newer than this call prove the driver
        /// is waiting.
        fn fresh(&self, n: usize) {
            let since = self.seq.load(Ordering::SeqCst);
            let mut fresh = 0;
            while fresh < n {
                let tap = self
                    .ticks
                    .recv_timeout(Duration::from_secs(15))
                    .expect("driver kept polling");
                if tap > since {
                    fresh += 1;
                }
            }
        }
    }

    /// Manual clock plus pause support for the deadline tests: every
    /// `BeforeRead` poll taps a numbered channel (a send that never blocks),
    /// so the test advances the clock only while the driver waits instead of
    /// sleeping for a real bound.
    fn ticking_clock(start: Instant) -> (Hooks, ClockCtl) {
        let clock = Arc::new(Mutex::new(start));
        let seq = Arc::new(AtomicU64::new(0));
        let (tick_tx, tick_rx) = mpsc::channel::<u64>();
        let tick = Arc::clone(&clock);
        let count = Arc::clone(&seq);
        let hooks = Hooks {
            clock: Box::new(move || *tick.lock().expect("clock")),
            pause: Some(Box::new(move |p| {
                if p == Point::BeforeRead {
                    tick_tx
                        .send(count.fetch_add(1, Ordering::SeqCst))
                        .expect("tap");
                }
            })),
        };
        (
            hooks,
            ClockCtl {
                clock,
                ticks: tick_rx,
                seq,
            },
        )
    }

    /// `ticking_clock` with a one-shot blocking gate at `point`, as in
    /// `gate_hooks` but on the manual clock.
    fn gated_clock(
        start: Instant,
        point: Point,
        gate: mpsc::Receiver<()>,
        fired: mpsc::Sender<()>,
    ) -> (Hooks, ClockCtl) {
        let clock = Arc::new(Mutex::new(start));
        let seq = Arc::new(AtomicU64::new(0));
        let (tick_tx, tick_rx) = mpsc::channel::<u64>();
        let done = Arc::new(AtomicBool::new(false));
        let gate = Arc::new(Mutex::new(gate));
        let tick = Arc::clone(&clock);
        let count = Arc::clone(&seq);
        let hooks = Hooks {
            clock: Box::new(move || *tick.lock().expect("clock")),
            pause: Some(Box::new(move |p| {
                if p == Point::BeforeRead {
                    tick_tx
                        .send(count.fetch_add(1, Ordering::SeqCst))
                        .expect("tap");
                }
                if p == point && !done.swap(true, Ordering::SeqCst) {
                    fired.send(()).expect("fired");
                    gate.lock()
                        .expect("gate")
                        .recv_timeout(Duration::from_secs(15))
                        .expect("release");
                }
            })),
        };
        (
            hooks,
            ClockCtl {
                clock,
                ticks: tick_rx,
                seq,
            },
        )
    }

    /// After the subscribe ack, driver flag first: the prompt goes out, then
    /// the kill lands in the prompt-ack wait. The fake sends the ack, a
    /// completed turn and a clean verdict after the control's `close now`;
    /// the run ends Done with one `close now` and no plain `close` (R3 wins).
    /// The fake holds every later line until the test's kill, so no
    /// scheduling can put the verdict before the intent.
    #[test]
    fn kill_after_the_prompt_went_out_keeps_one_close_now() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (prompt_tx, prompt_rx) = mpsc::channel::<()>();
        let (kill_done_tx, kill_done_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            prompt_tx.send(()).expect("prompt seen");
            kill_done_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("kill");
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            srv.send(&turn_completed_ev(10, "completed", None));
            srv.send(&exited_ev(11, 0, "DONE", None));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            signal_hooks(Point::AfterSubscribeAck, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("passed");
        prompt_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("prompt");
        control.kill();
        kill_done_tx.send(()).expect("fake");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert_eq!(res.is_error, Some(false));
        assert_eq!(res.text, "DONE");
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// F3 (clock): a kill with the driver paused just before the prompt
    /// write. The release finds the intent-checked `prompt` write refusing on
    /// the intent; the run skips the prompt, the `close now` goes out once in
    /// the stopping read loop, and the stop wait ends with the kill crash.
    /// The stop wait ends by jump, never by a real wait.
    #[test]
    fn kill_before_the_prompt_write_sends_no_prompt() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds = short_stop_bounds();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::BeforePromptWrite, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        gate_tx.send(()).expect("release");
        // Two fresh polls prove the stop armed before the jump ends it.
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// F2 (clock): after the `close now`, the fake sends `turn_completed`
    /// and then nothing. The completed turn sends no plain `close` (R12: the
    /// stop is under way), and the stop wait ends with the stop text. The
    /// stop wait ends by jump, never by a real wait.
    /// A `STATUS: DONE` hub line on the way still derives Error.
    #[test]
    fn completed_turn_in_the_stop_wait_sends_no_plain_close() {
        let (ready_tx, ready_rx) = mpsc::channel::<()>();
        let (kill_done_tx, kill_done_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            ready_tx.send(()).expect("ready");
            kill_done_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("kill");
            srv.send(&ev(
                "assistant_message_delta",
                10,
                serde_json::json!({"text": "STATUS: DONE"}),
            ));
            srv.send(&turn_completed_ev(11, "completed", None));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            release_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("release");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds = short_stop_bounds();
        let (hooks, ctl) = ticking_clock(Instant::now());
        let run = spawn_turn_with(req, path.clone(), hooks);
        let control = run.control.clone();
        let res_rx = drive_async(run);
        ready_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("ready");
        control.kill();
        kill_done_tx.send(()).expect("fake");
        // Two fresh polls prove the stop armed before the jump ends it.
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        release_tx.send(()).expect("fake");
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// F2 with a verdict: the `fiber_exited` the fake sends after
    /// `turn_completed` wins over the armed stop (R3), so the run ends Done.
    #[test]
    fn exited_after_turn_completed_wins_over_the_armed_stop() {
        let (ready_tx, ready_rx) = mpsc::channel::<()>();
        let (kill_done_tx, kill_done_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            ready_tx.send(()).expect("ready");
            kill_done_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("kill");
            srv.send(&turn_completed_ev(10, "completed", None));
            srv.send(&exited_ev(11, 0, "DONE", None));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.stop_wait = Duration::from_secs(5);
        req.bounds.poll_slice = Duration::from_millis(5);
        let run = spawn_turn(req, path.clone());
        let control = run.control.clone();
        let res_rx = drive_async(run);
        ready_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("ready");
        control.kill();
        kill_done_tx.send(()).expect("fake");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert_eq!(res.is_error, Some(false));
        assert_eq!(res.text, "DONE");
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// F2 with the stop set by an expired `turn_wait` (clock): after
    /// `turn_started` with no completion, the turn bound arms the stop
    /// (close now goes out). A `turn_completed` in the stop wait sends no
    /// plain `close` (the stop is under way), and the stop wait ends with
    /// the turn-bound stop text. Both waits end by clock jumps, never by
    /// real ones.
    #[test]
    fn expired_turn_wait_arms_the_stop() {
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.send(&turn_completed_ev(10, "completed", None));
            release_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("release");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.turn_wait = Some(Duration::from_millis(50));
        req.bounds.stop_wait = Duration::from_millis(50);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::AfterPromptAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("phase entry");
        gate_tx.send(()).expect("release");
        // Phase bounds were fixed before the gate fired: the jump trips the
        // turn bound, and three fresh polls prove the stop armed before the
        // second jump ends it.
        ctl.jump(Duration::from_secs(2));
        ctl.fresh(3);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert!(
            res.text.contains(
                "no verdict within the turn bound; no fiber_exited within the stop bound"
            ),
            "{}",
            res.text
        );
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        release_tx.send(()).expect("fake");
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// R7 (clock): `cancel` then `kill` gives one `close now` and the kill
    /// text; the kill upgrades the pending cancel. A second flow does two
    /// kills: still one `close now`. Every pass through the read loop is
    /// gated, so the upgrade path (not just the outcome) is forced. The stop
    /// wait ends by jump, never by a real wait.
    #[test]
    fn stop_intent_upgrades_cancel_to_kill_with_one_close() {
        for second in [false, true] {
            let (fired_tx, fired_rx) = mpsc::channel::<()>();
            let (gate_tx, gate_rx) = mpsc::channel::<()>();
            let (ready_tx, ready_rx) = mpsc::channel::<()>();
            let (release_tx, release_rx) = mpsc::channel::<()>();
            let gated_armed = Arc::new(AtomicBool::new(false));
            let (path, rx) = spawn_fake(move |srv| {
                srv.send(&hello(serde_json::json!(1), "9.9.9"));
                let (start_id, _) = recv_id(srv);
                srv.send(&accepted(
                    &start_id,
                    serde_json::json!({"session_id": "s_1"}),
                ));
                let (sub_id, _) = recv_id(srv);
                srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
                let (prompt_id, _) = recv_id(srv);
                srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
                srv.send(&turn_started_ev(&prompt_id, 9));
                ready_tx.send(()).expect("ready");
                let (_, close) = recv_id(srv);
                assert_eq!(close["command"], "close");
                assert_eq!(close["args"]["now"], true);
                release_rx
                    .recv_timeout(Duration::from_secs(15))
                    .expect("release");
                srv.expect_eof();
            });
            let mut req = hub_request();
            req.bounds = short_stop_bounds();
            let clock = Arc::new(Mutex::new(Instant::now()));
            let (tick_tx, tick_rx) = mpsc::channel::<u64>();
            let tap_seq = Arc::new(AtomicU64::new(0));
            let ctl = ClockCtl {
                clock: Arc::clone(&clock),
                ticks: tick_rx,
                seq: Arc::clone(&tap_seq),
            };
            let pause = {
                let fired_tx = fired_tx;
                let gate_rx = Arc::new(Mutex::new(gate_rx));
                let armed = Arc::clone(&gated_armed);
                move |p: Point| {
                    if p == Point::BeforeRead {
                        tick_tx
                            .send(tap_seq.fetch_add(1, Ordering::SeqCst))
                            .expect("tap");
                        if armed.load(Ordering::SeqCst) {
                            fired_tx.send(()).expect("fired");
                            gate_rx
                                .lock()
                                .expect("gate")
                                .recv_timeout(Duration::from_secs(15))
                                .expect("release");
                        }
                    }
                }
            };
            let run = spawn_turn_with(
                req,
                path.clone(),
                Hooks {
                    clock: Box::new(move || *clock.lock().expect("clock")),
                    pause: Some(Box::new(pause)),
                },
            );
            let control = run.control.clone();
            let res_rx = drive_async(run);
            // Pump the driver forward until the fake is in the live loop,
            // then arm the gate: the next two passes are the orchestrated
            // stop and upgrade.
            gated_armed.store(true, Ordering::SeqCst);
            loop {
                fired_rx
                    .recv_timeout(Duration::from_secs(15))
                    .expect("fired");
                if ready_rx.try_recv().is_ok() {
                    break;
                }
                gate_tx.send(()).expect("release");
            }
            if second {
                control.kill();
            } else {
                control.cancel();
            }
            gate_tx.send(()).expect("release");
            fired_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("second");
            control.kill();
            gated_armed.store(false, Ordering::SeqCst);
            gate_tx.send(()).expect("release");
            // The gate is off now: two fresh polls prove the upgraded stop
            // armed before the jump ends it.
            ctl.fresh(2);
            ctl.jump(Duration::from_secs(2));
            let res = res_rx
                .recv_timeout(Duration::from_secs(30))
                .expect("result");
            drop(control);
            assert!(res.text.contains("killed by the caller"), "{}", res.text);
            assert!(
                crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                    == crate::types::RunStatus::Error
            );
            release_tx.send(()).expect("fake");
            assert_eq!(
                received_commands(&join_fake(&path, rx)),
                ["start", "subscribe", "prompt", "close"]
            );
        }
    }

    /// F (R16 rule): a `stream_closed` with no `close now` outstanding ends
    /// the run at once after the R6 cleanup (summary subscribe, `close
    /// now`): it does not wait out a long `stop_wait`, and the text is the
    /// `stream_closed` crash, not a stop text.
    #[test]
    fn stream_closed_without_a_close_now_ends_at_once() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&ev("stream_closed", 9, serde_json::json!({})));
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.stop_wait = Duration::from_secs(60);
        let res = run_turn(&req, &path, &|_| {});
        assert!(res.text.contains("stream_closed"), "{}", res.text);
        assert!(!res.text.contains("stop bound"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "subscribe", "close"]
        );
    }

    /// R16: with a `close now` outstanding and unanswered, a read
    /// `stream_closed` clears the subscription flags and retries at once
    /// (summary subscribe, then a fresh `close now`), then keeps reading.
    /// The late rejection of the first id is ignored (stale: no second
    /// retry); the fake's accept of the second ends the run as the
    /// `stream_closed` crash.
    #[test]
    fn stream_closed_with_close_now_outstanding_retries_once() {
        let (ready_tx, ready_rx) = mpsc::channel::<()>();
        let (a_seen_tx, a_seen_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let armed = Arc::new(AtomicBool::new(false));
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            ready_tx.send(()).expect("ready");
            let (a_id, close_a) = recv_id(srv);
            assert_eq!(close_a["command"], "close");
            assert_eq!(close_a["args"]["now"], true);
            a_seen_tx.send(()).expect("a seen");
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            srv.send(&ev("stream_closed", 10, serde_json::json!({})));
            srv.send(&rejected(Some(&a_id), "not_subscribed", "gone"));
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            assert_eq!(summary["session_id"], "s_1");
            let (b_id, close_b) = recv_id(srv);
            assert_eq!(close_b["command"], "close");
            assert_eq!(close_b["args"]["now"], true);
            assert_ne!(a_id, b_id);
            srv.send(&accepted(&b_id, serde_json::json!({})));
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            armed_gate(Arc::clone(&armed), gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        ready_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("ready");
        armed.store(true, Ordering::SeqCst);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        a_seen_rx.recv_timeout(Duration::from_secs(15)).expect("a");
        go_tx.send(()).expect("fake");
        armed.store(false, Ordering::SeqCst);
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("stream_closed"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        let received = join_fake(&path, rx);
        assert_eq!(
            received_commands(&received),
            [
                "start",
                "subscribe",
                "prompt",
                "close",
                "subscribe",
                "close"
            ]
        );
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&received[4]).expect("summary")["args"]["level"],
            serde_json::json!("summary")
        );
    }

    /// R16 accepted variant: the `close now` was answered before the
    /// `stream_closed` read (`close_now_open` false), so the run fails at
    /// once after the R6 cleanup and the fake receives nothing more.
    #[test]
    fn stream_closed_after_answered_close_now_sends_nothing() {
        let (ready_tx, ready_rx) = mpsc::channel::<()>();
        let (a_seen_tx, a_seen_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let armed = Arc::new(AtomicBool::new(false));
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            ready_tx.send(()).expect("ready");
            let (a_id, close_a) = recv_id(srv);
            assert_eq!(close_a["args"]["now"], true);
            srv.send(&accepted(&a_id, serde_json::json!({})));
            a_seen_tx.send(()).expect("a answered");
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            srv.send(&ev("stream_closed", 10, serde_json::json!({})));
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            armed_gate(Arc::clone(&armed), gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        ready_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("ready");
        armed.store(true, Ordering::SeqCst);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        a_seen_rx.recv_timeout(Duration::from_secs(15)).expect("a");
        go_tx.send(()).expect("fake");
        armed.store(false, Ordering::SeqCst);
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("stream_closed"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// R16 retried variant: with the retry already sent, a later
    /// `stream_closed` sends no further lines — and a retry on a subscribed
    /// connection carries no summary (nothing was ever dropped). The kill
    /// waits for the fake to hold the sent prompt: the subscribe ack is
    /// processed by then, so the control's `close now` is deterministic.
    #[test]
    fn stream_closed_after_the_retry_sends_nothing() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (prompt_tx, prompt_rx) = mpsc::channel::<()>();
        let (kill_done_tx, kill_done_rx) = mpsc::channel::<()>();
        let (b_seen_tx, b_seen_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            prompt_tx.send(()).expect("prompt seen");
            kill_done_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("kill");
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            let (a_id, _) = recv_id(srv);
            srv.send(&rejected(Some(&a_id), "not_subscribed", "gone"));
            let (_, retry) = recv_id(srv);
            assert_eq!(retry["command"], "close");
            assert_eq!(retry["args"]["now"], true);
            assert!(
                retry
                    .get("args")
                    .and(retry["args"].get("summary"))
                    .is_none(),
                "subscribed retry carries no summary: {}",
                retry
            );
            b_seen_tx.send(()).expect("retry seen");
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            srv.send(&ev("stream_closed", 10, serde_json::json!({})));
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            signal_hooks(Point::AfterSubscribeAck, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("subscribed");
        prompt_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("prompt");
        control.kill();
        kill_done_tx.send(()).expect("fake");
        b_seen_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("retry");
        go_tx.send(()).expect("fake");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("stream_closed"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close", "close"]
        );
    }

    /// F4 folded into the R16 flow (R21): a `close now` rejected
    /// `not_subscribed` after `stream_closed` retries with a summary
    /// subscribe and a second `close now`, and nothing more. Accepting the
    /// second ends with the `stream_closed` crash (pinned above); rejecting
    /// it ends in a crash naming that reply (R20's text).
    #[test]
    fn close_now_rejected_after_stream_closed_names_the_reply() {
        let (ready_tx, ready_rx) = mpsc::channel::<()>();
        let (a_seen_tx, a_seen_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let armed = Arc::new(AtomicBool::new(false));
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            ready_tx.send(()).expect("ready");
            let (a_id, _) = recv_id(srv);
            a_seen_tx.send(()).expect("a seen");
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            srv.send(&ev("stream_closed", 10, serde_json::json!({})));
            srv.send(&rejected(Some(&a_id), "not_subscribed", "gone"));
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["args"]["level"], "summary");
            let (b_id, _) = recv_id(srv);
            assert_ne!(a_id, b_id);
            srv.send(&rejected(Some(&b_id), "not_subscribed", "still gone"));
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            armed_gate(Arc::clone(&armed), gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        ready_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("ready");
        armed.store(true, Ordering::SeqCst);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        a_seen_rx.recv_timeout(Duration::from_secs(15)).expect("a");
        go_tx.send(()).expect("fake");
        armed.store(false, Ordering::SeqCst);
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("not_subscribed"), "{}", res.text);
        assert!(res.text.contains("still gone"), "{}", res.text);
        assert!(res.text.contains("s_1"), "{}", res.text);
        assert!(res.text.contains("may still be running"), "{}", res.text);
        assert!(
            res.text.ends_with("The run ended without a verdict."),
            "{}",
            res.text
        );
        assert_eq!(res.is_error, Some(true));
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            [
                "start",
                "subscribe",
                "prompt",
                "close",
                "subscribe",
                "close"
            ]
        );
    }

    /// F6: rejecting the summary subscribe id fails at once naming
    /// `subscribe` and the code; the `close now` that followed in the same
    /// write is not awaited.
    #[test]
    fn summary_subscribe_rejected_after_stream_closed_fails_at_once() {
        let (ready_tx, ready_rx) = mpsc::channel::<()>();
        let (a_seen_tx, a_seen_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let armed = Arc::new(AtomicBool::new(false));
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            ready_tx.send(()).expect("ready");
            let (a_id, _) = recv_id(srv);
            a_seen_tx.send(()).expect("a seen");
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            srv.send(&ev("stream_closed", 10, serde_json::json!({})));
            srv.send(&rejected(Some(&a_id), "not_subscribed", "gone"));
            let (summary_id, summary) = recv_id(srv);
            assert_eq!(summary["args"]["level"], "summary");
            let (_, _) = recv_id(srv);
            srv.send(&rejected(Some(&summary_id), "held", "summary held"));
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            armed_gate(Arc::clone(&armed), gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        ready_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("ready");
        armed.store(true, Ordering::SeqCst);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("paused");
        control.kill();
        a_seen_rx.recv_timeout(Duration::from_secs(15)).expect("a");
        go_tx.send(()).expect("fake");
        armed.store(false, Ordering::SeqCst);
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("subscribe"), "{}", res.text);
        assert!(res.text.contains("held"), "{}", res.text);
        assert!(
            res.text.ends_with("The run ended without a verdict."),
            "{}",
            res.text
        );
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            [
                "start",
                "subscribe",
                "prompt",
                "close",
                "subscribe",
                "close"
            ]
        );
    }

    /// R19: the retry skips an already-sent `summary` subscribe. Staged at
    /// the `Shared` level: a driver-level retry with a sent summary and a
    /// run that keeps reading would need the R16 `stream_closed` clearing,
    /// which carries the retry's own summary — so the unit pins the skip
    /// rule exactly where it lives.
    #[test]
    fn retry_skips_an_already_sent_summary_subscribe() {
        // A socket pair, not the threaded fake: the test thread is the only
        // writer here, so nothing can close the peer under a `set_read_timeout`.
        // The listener fake races a fast test thread that way on this platform.
        let (client, server) = UnixStream::pair().expect("socket pair");
        server
            .set_read_timeout(Some(Duration::from_secs(15)))
            .expect("read timeout");
        let mut srv = FakeSrv {
            reader: BufReader::new(server.try_clone().expect("clone")),
            writer: server,
            received: Vec::new(),
        };
        let shared = Arc::new(Shared::new(Duration::from_secs(5)));
        {
            let mut out = lock(&shared.out);
            out.writer = Some(client);
            out.session_id = Some("s_1".to_string());
            out.summary_sent = true;
        }
        shared.retry_close_now();
        assert!(lock(&shared.out).retried);
        assert!(lock(&shared.out).close_now_id.is_some());
        assert!(lock(&shared.out).summary_ids.is_empty());
        drop(shared);
        let (_, close) = recv_id(&mut srv);
        assert_eq!(close["command"], "close");
        assert_eq!(close["args"]["now"], true);
        assert_eq!(close["session_id"], "s_1");
        srv.expect_eof();
        assert_eq!(received_commands(&srv.received).len(), 1);
    }

    /// The other half of R19: after a `stream_closed` clears `summary_sent`,
    /// the retry resends the `summary` subscribe. No driver flow sets up a
    /// cleared-then-retried state any other way — every summary-sending
    /// path either ends the run at once or sets `retried`, which blocks a
    /// second retry — so this pins the retry half at the `Shared` level
    /// through the same calls the `stream_closed` arm makes.
    #[test]
    fn retry_after_a_cleared_summary_resends_it() {
        // A socket pair, not the threaded fake: the test thread is the only
        // writer here, so nothing can close the peer under a `set_read_timeout`.
        let (client, server) = UnixStream::pair().expect("socket pair");
        server
            .set_read_timeout(Some(Duration::from_secs(15)))
            .expect("read timeout");
        let mut srv = FakeSrv {
            reader: BufReader::new(server.try_clone().expect("clone")),
            writer: server,
            received: Vec::new(),
        };
        let shared = Arc::new(Shared::new(Duration::from_secs(5)));
        {
            let mut out = lock(&shared.out);
            out.writer = Some(client);
            out.session_id = Some("s_1".to_string());
        }
        shared.close_now_once();
        assert!(lock(&shared.out).summary_sent);
        // What the `stream_closed` arm does before the retry: the old
        // subscription is gone, so both flags go down.
        {
            let mut out = lock(&shared.out);
            out.subscribed = false;
            out.summary_sent = false;
        }
        shared.retry_close_now();
        assert!(lock(&shared.out).retried);
        assert_eq!(lock(&shared.out).summary_ids.len(), 2);
        assert_eq!(lock(&shared.out).close_now_ids.len(), 2);
        drop(shared);
        let (_, first) = recv_id(&mut srv);
        assert_eq!(first["command"], "subscribe");
        assert_eq!(first["args"]["level"], "summary");
        assert_eq!(first["session_id"], "s_1");
        let (a_id, close_a) = recv_id(&mut srv);
        assert_eq!(close_a["command"], "close");
        assert_eq!(close_a["args"]["now"], true);
        let (_, second) = recv_id(&mut srv);
        assert_eq!(second["command"], "subscribe");
        assert_eq!(second["args"]["level"], "summary");
        let (b_id, close_b) = recv_id(&mut srv);
        assert_eq!(close_b["command"], "close");
        assert_eq!(close_b["args"]["now"], true);
        assert_ne!(a_id, b_id);
        srv.expect_eof();
        assert_eq!(
            received_commands(&srv.received),
            ["subscribe", "close", "subscribe", "close"]
        );
    }

    /// R18: a clean live `fiber_exited` after an accepted `close now` is
    /// the S1 exit text (not the kill text): the verdict read before any
    /// bound wins. No command follows the verdict: the fake proves it with
    /// EOF after the test drops the retained control handle, not with a
    /// read timeout (which `read_line` maps to the same `Lost` as EOF).
    #[test]
    fn exited_after_accepted_close_now_keeps_the_exit_text() {
        let (ready_tx, ready_rx) = mpsc::channel::<()>();
        let (kill_done_tx, kill_done_rx) = mpsc::channel::<()>();
        let (eof_go_tx, eof_go_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            ready_tx.send(()).expect("ready");
            kill_done_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("kill");
            let (a_id, _) = recv_id(srv);
            srv.send(&accepted(&a_id, serde_json::json!({})));
            srv.send(&exited_ev(10, 0, "clean", None));
            // The driver is done once the test holds its result and drops
            // the control handle: only then must the socket end, with no
            // further command on it.
            eof_go_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("eof go");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.stop_wait = Duration::from_secs(30);
        req.bounds.poll_slice = Duration::from_millis(5);
        let run = spawn_turn(req, path.clone());
        let control = run.control.clone();
        let res_rx = drive_async(run);
        ready_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("ready");
        control.kill();
        kill_done_tx.send(()).expect("fake");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        eof_go_tx.send(()).expect("fake");
        assert!(
            res.text.contains("without a completed turn"),
            "{}",
            res.text
        );
        assert!(!res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// R1 with a resumed session (case C, clock): a replayed `fiber_exited`
    /// at or below `last_seq` in the fold does not set the verdict flag, so
    /// a `kill` before the prompt still writes one `close now`. With no live
    /// exit ever, the stop wait ends with the kill crash and nothing goes
    /// out after the `close now`. The stop wait ends by jump, never by a
    /// real wait.
    #[test]
    fn kill_on_a_resumed_session_closes_now_then_stops() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&exited_ev(500, 0, "stale", None));
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 1000})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            assert_eq!(close["session_id"], "s_1");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds = short_stop_bounds();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::AfterSubscribeAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("subscribed");
        control.kill();
        gate_tx.send(()).expect("release");
        // Two fresh polls prove the stop armed before the jump ends it.
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// R1 with a resumed session (case B): the `kill` lands before the
    /// prompt on a connection whose fold held only a replayed exit. The
    /// live `fiber_exited` the fake then sends is the S1 pre-turn verdict
    /// (R3: the verdict read in the stop wait wins), not the kill text.
    #[test]
    fn resumed_session_live_exit_after_kill_is_the_verdict() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&exited_ev(500, 0, "stale", None));
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 1000})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.send(&exited_ev(1001, 1, "", Some("boom")));
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds = short_stop_bounds();
        let run = spawn_turn_with(
            req,
            path.clone(),
            gate_hooks(Point::AfterSubscribeAck, gate_rx, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("subscribed");
        control.kill();
        gate_tx.send(()).expect("release");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert!(
            res.text.contains("session exited before the turn started"),
            "{}",
            res.text
        );
        assert!(res.text.contains("boom"), "{}", res.text);
        assert!(!res.text.contains("killed by the caller"), "{}", res.text);
        assert_eq!(res.is_error, Some(true));
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "close"]
        );
    }

    /// R1 itself: a `kill` after a post-`turn_started` `fiber_exited` was
    /// read writes nothing. The verdict flag is set before the seam pause,
    /// so the stop landing in the pause is a no-op and the socket stays
    /// silent after the verdict.
    #[test]
    fn kill_after_a_live_verdict_writes_nothing() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            srv.send(&turn_completed_ev(10, "completed", None));
            let (_, plain) = recv_id(srv);
            assert_eq!(plain["command"], "close");
            srv.send(&exited_ev(11, 0, "DONE", None));
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            signal_hooks(Point::AfterVerdictFlag, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("verdict");
        control.kill();
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// R3 cancel race: the fake holds the live `fiber_exited` until the
    /// test cancels. The test cancels only after the fake holds the
    /// driver's plain post-turn `close`: the cancel lands before the
    /// verdict is read, one `close now` goes out, no second plain `close`
    /// and no new `subscribe` appear, and the verdict is Done.
    #[test]
    fn cancel_after_turn_completed_keeps_done_with_one_close_now() {
        let (plain_tx, plain_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            srv.send(&turn_completed_ev(10, "completed", None));
            let (_, plain) = recv_id(srv);
            assert_eq!(plain["command"], "close");
            assert!(plain.get("args").is_none());
            plain_tx.send(()).expect("plain close");
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            srv.send(&exited_ev(11, 0, "DONE", None));
            let (_, now) = recv_id(srv);
            assert_eq!(now["command"], "close");
            assert_eq!(now["args"]["now"], true);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.stop_wait = Duration::from_secs(5);
        req.bounds.poll_slice = Duration::from_millis(5);
        let run = spawn_turn(req, path.clone());
        let control = run.control.clone();
        let res_rx = drive_async(run);
        plain_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("plain");
        control.cancel();
        go_tx.send(()).expect("fake");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        let received = join_fake(&path, rx);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close", "close"]
        );
        assert_eq!(
            received
                .iter()
                .filter(|line| {
                    serde_json::from_str::<serde_json::Value>(line).expect("json")["args"]["now"]
                        == true
                })
                .count(),
            1
        );
    }

    /// R3 with `cancel` after the verdict: the flag is set, so the late
    /// stop is a no-op and the socket stays silent after the verdict.
    #[test]
    fn cancel_after_the_verdict_writes_nothing() {
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            srv.send(&turn_completed_ev(10, "completed", None));
            let (_, plain) = recv_id(srv);
            assert_eq!(plain["command"], "close");
            srv.send(&exited_ev(11, 0, "DONE", None));
            srv.expect_eof();
        });
        let run = spawn_turn_with(
            hub_request(),
            path.clone(),
            signal_hooks(Point::AfterVerdictFlag, fired_tx),
        );
        let control = run.control.clone();
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("verdict");
        control.cancel();
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        drop(control);
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// R3 bound race (clock): the `turn_wait` bound fires while the turn is
    /// still open, arming the stop (one `close now` goes out). The verdict
    /// the fake then sends is still the outcome and no bound text appears: a
    /// verdict read after the bound fired wins. The `turn_completed` sends
    /// no plain `close`: the expired bound armed the stop first. A clock
    /// jump fires the bound; no real wait is needed.
    #[test]
    fn readable_exit_beats_an_expired_turn_wait() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.send(&turn_completed_ev(10, "completed", None));
            srv.send(&exited_ev(11, 0, "DONE", None));
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.turn_wait = Some(Duration::from_millis(50));
        req.bounds.stop_wait = Duration::from_secs(5);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::AfterPromptAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("phase entry");
        gate_tx.send(()).expect("release");
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert_eq!(res.text, "DONE");
        assert!(!res.text.contains("bound"), "{}", res.text);
        assert_eq!(res.is_error, Some(false));
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// R3 bound race, the stop wait itself (clock): with no exit the stop
    /// runs, one `close now` goes out, and the stop-wait crash follows the
    /// second clock jump. When the exit arrives inside the stop wait
    /// instead, it is the verdict. The fake gates the exit on the `close
    /// now`; both bounds end by jumps, never by real waits.
    #[test]
    fn stop_wait_runs_its_course_then_exit_or_bound() {
        for exit_in_wait in [false, true] {
            let (path, rx) = spawn_fake(move |srv| {
                srv.send(&hello(serde_json::json!(1), "9.9.9"));
                let (start_id, _) = recv_id(srv);
                srv.send(&accepted(
                    &start_id,
                    serde_json::json!({"session_id": "s_1"}),
                ));
                let (sub_id, _) = recv_id(srv);
                srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
                let (prompt_id, _) = recv_id(srv);
                srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
                srv.send(&turn_started_ev(&prompt_id, 9));
                let (_, close) = recv_id(srv);
                assert_eq!(close["command"], "close");
                assert_eq!(close["args"]["now"], true);
                if exit_in_wait {
                    srv.send(&turn_completed_ev(10, "completed", None));
                    srv.send(&exited_ev(11, 0, "DONE", None));
                }
                srv.expect_eof();
            });
            let mut req = hub_request();
            req.bounds.turn_wait = Some(Duration::from_millis(50));
            req.bounds.stop_wait = Duration::from_millis(50);
            req.bounds.poll_slice = Duration::from_millis(5);
            let (fired_tx, fired_rx) = mpsc::channel::<()>();
            let (gate_tx, gate_rx) = mpsc::channel::<()>();
            let (hooks, ctl) =
                gated_clock(Instant::now(), Point::AfterPromptAck, gate_rx, fired_tx);
            let run = spawn_turn_with(req, path.clone(), hooks);
            let res_rx = drive_async(run);
            fired_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("phase entry");
            gate_tx.send(()).expect("release");
            ctl.jump(Duration::from_secs(2));
            if !exit_in_wait {
                // Three fresh polls prove the stop armed before the second
                // jump ends it.
                ctl.fresh(3);
                ctl.jump(Duration::from_secs(2));
            }
            let res = res_rx
                .recv_timeout(Duration::from_secs(30))
                .expect("result");
            if exit_in_wait {
                assert_eq!(res.text, "DONE");
                assert_eq!(res.is_error, Some(false));
            } else {
                assert!(
                    res.text.contains(
                        "no verdict within the turn bound; no fiber_exited within the stop bound"
                    ),
                    "{}",
                    res.text
                );
                assert_eq!(res.is_error, Some(true));
                assert!(
                    crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                        == crate::types::RunStatus::Error
                );
            }
            assert_eq!(res.session_id.as_deref(), Some("s_1"));
            assert_eq!(
                received_commands(&join_fake(&path, rx)),
                ["start", "subscribe", "prompt", "close"]
            );
        }
    }

    /// T4 (clock): a silent hub through the `subscribe` ack times out with
    /// the R9 text naming the command and the bound. The clock jumps past
    /// `ack_wait` only after fresh polls prove the gated wait fixed its
    /// deadline; no real bound is waited out. The R6 cleanup runs at once:
    /// a `summary` subscribe, then `close now`, on the known session.
    #[test]
    fn unanswered_subscribe_hits_the_ack_bound() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (_, sub) = recv_id(srv);
            assert_eq!(sub["command"], "subscribe");
            assert_eq!(sub["args"]["level"], "full");
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
            assert_eq!(summary["session_id"], "s_1");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.ack_wait = Duration::from_millis(50);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (hooks, ctl) =
            gated_clock(Instant::now(), Point::BeforeSubscribeAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("subscribe wait");
        gate_tx.send(()).expect("release");
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert!(
            res.text
                .contains("no answer to `subscribe` within the ack bound"),
            "{}",
            res.text
        );
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "subscribe", "close"]
        );
    }

    /// T4 (clock): a silent hub through the `prompt` ack times out with the
    /// R9 text. The clock jumps past `ack_wait` only after fresh polls prove
    /// the gated wait fixed its deadline; no real bound is waited out. The
    /// connection holds the subscription, so the R6 cleanup is one `close
    /// now` and no second subscribe.
    #[test]
    fn unanswered_prompt_hits_the_ack_bound() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (_, prompt) = recv_id(srv);
            assert_eq!(prompt["command"], "prompt");
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            assert_eq!(close["session_id"], "s_1");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.ack_wait = Duration::from_millis(50);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::BeforePromptWrite, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("prompt wait");
        gate_tx.send(()).expect("release");
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert!(
            res.text
                .contains("no answer to `prompt` within the ack bound"),
            "{}",
            res.text
        );
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// R17 (clock): lines read during the prompt ack wait reset nothing. The
    /// fake sends `turn_started` and one `turn_completed` while the ack is
    /// still live: the completion folds and sends the one plain `close` (no
    /// stop is under way yet), but the ack budget stays put. A first jump
    /// stops 10 ms short of the bound so the wait survives the completion; a
    /// second jump past it ends the wait with the ack crash and the `close
    /// now` cleanup. Mint the deadline per pass again and the completion
    /// pushes it past the second jump, so the fake never sees the `close
    /// now`.
    #[test]
    fn prompt_ack_completions_do_not_restart_the_budget() {
        let (prompt_tx, prompt_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (plain_tx, plain_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, prompt) = recv_id(srv);
            assert_eq!(prompt["command"], "prompt");
            prompt_tx.send(()).expect("prompt seen");
            // While the ack is still live: the completion folds and closes
            // once, but must not move the budget.
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            srv.send(&turn_started_ev(&prompt_id, 9));
            srv.send(&turn_completed_ev(10, "completed", None));
            let (_, plain) = recv_id(srv);
            assert_eq!(plain["command"], "close");
            assert!(
                plain.get("args").is_none(),
                "completion before the ack sends the plain close: {plain}"
            );
            plain_tx.send(()).expect("plain seen");
            // Bounded wait for the ack-expiry cleanup.
            let mut partial = Vec::new();
            let mut now_close = false;
            for _ in 0..150 {
                match read_line_into(&mut srv.reader, &mut partial, Duration::from_millis(20)) {
                    Ok(Read::Line(raw)) => {
                        let line = String::from_utf8(raw).expect("fake hub keeps lines UTF-8");
                        let value: serde_json::Value =
                            serde_json::from_str(&line).expect("hub line json");
                        srv.received.push(line);
                        assert_eq!(value["command"], "close");
                        assert_eq!(value["args"]["now"], true);
                        assert_eq!(value["session_id"], "s_1");
                        now_close = true;
                        break;
                    }
                    Ok(Read::Pending) => {}
                    Err(ReadErr::Lost(detail)) => {
                        panic!("fake hub lost the connection: {detail}")
                    }
                }
            }
            assert!(now_close, "no close now after the ack bound");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.ack_wait = Duration::from_millis(50);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (hooks, ctl) = ticking_clock(Instant::now());
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        prompt_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("prompt seen");
        ctl.fresh(2);
        // Short of the 50 ms bound, so the wait survives the completion.
        ctl.jump(Duration::from_millis(40));
        go_tx.send(()).expect("fake");
        // The completion was processed (the plain close proves it) on the
        // original budget: the second jump ends the wait unless the pass
        // minted a fresh deadline.
        plain_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("plain seen");
        ctl.jump(Duration::from_millis(30));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert!(
            res.text
                .contains("no answer to `prompt` within the ack bound"),
            "{}",
            res.text
        );
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        let received = join_fake(&path, rx);
        assert_eq!(
            received_commands(&received),
            ["start", "subscribe", "prompt", "close", "close"]
        );
        let plain: serde_json::Value = serde_json::from_str(&received[3]).expect("plain close");
        assert!(
            plain.get("args").is_none(),
            "fourth line is the plain close: {}",
            received[3]
        );
        let now_close: serde_json::Value = serde_json::from_str(&received[4]).expect("close now");
        assert_eq!(now_close["args"]["now"], serde_json::json!(true));
    }

    /// T4 (clock): `turn_start_wait` runs from the `prompt` ack. With no
    /// `turn_started`, the bound arms the stop (one `close now` goes out)
    /// and the stop wait ends with the turn-start bound text. Both waits end
    /// by clock jumps, never by real ones.
    #[test]
    fn expired_turn_start_wait_runs_the_stop() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.turn_start_wait = Duration::from_millis(50);
        req.bounds.turn_wait = None;
        req.bounds.stop_wait = Duration::from_millis(50);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::AfterPromptAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("phase entry");
        gate_tx.send(()).expect("release");
        // Phase bounds were fixed before the gate fired: the jump trips the
        // turn-start bound, and three fresh polls prove the stop armed before
        // the second jump ends it.
        ctl.jump(Duration::from_secs(2));
        ctl.fresh(3);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert!(
            res.text.contains(
                "no turn_started within the turn-start bound; no fiber_exited within the stop bound"
            ),
            "{}",
            res.text
        );
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// T4 (R17, clock): phase bounds are totals, not idle timers. The fake
    /// keeps events flowing until it holds the `close now`, capped well past
    /// the bound: under totals the jumped bound fires mid-flow; under idle
    /// semantics the deadline would keep sliding and the cap fails loudly
    /// instead of hanging the test.
    #[test]
    fn turn_start_wait_expires_while_events_flow() {
        let (path, rx) = spawn_fake(|srv| {
            // Short reads from the start: the loop below polls for the
            // `close now` with one bounded read per sent delta. The peer
            // lives for the whole run, so no close can race this call.
            srv.reader
                .get_ref()
                .set_read_timeout(Some(Duration::from_millis(20)))
                .expect("fake read timeout");
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            let mut partial = Vec::new();
            let mut close = None;
            for seq in 0..200u64 {
                srv.send(&ev(
                    "assistant_message_delta",
                    100 + seq,
                    serde_json::json!({"text": "still going"}),
                ));
                match read_line_into(&mut srv.reader, &mut partial, Duration::from_millis(20)) {
                    Ok(Read::Line(raw)) => {
                        let line = String::from_utf8(raw).expect("fake hub keeps lines UTF-8");
                        let value: serde_json::Value =
                            serde_json::from_str(&line).expect("hub line json");
                        if value["command"] == "close" {
                            srv.received.push(line);
                            close = Some(value);
                            break;
                        }
                    }
                    Ok(Read::Pending) => {}
                    Err(ReadErr::Lost(detail)) => {
                        panic!("fake hub lost the connection: {detail}")
                    }
                }
            }
            let close = close.expect("close now never went out while events flowed");
            assert_eq!(close["args"]["now"], true);
            srv.reader
                .get_ref()
                .set_read_timeout(Some(Duration::from_secs(15)))
                .expect("fake read timeout");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.turn_start_wait = Duration::from_millis(50);
        req.bounds.turn_wait = None;
        req.bounds.stop_wait = Duration::from_millis(50);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::AfterPromptAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("phase entry");
        gate_tx.send(()).expect("release");
        // The bound fires mid-flow by jump, not by waiting: the close the
        // fake holds for proves the totals reading, and three fresh polls
        // prove the stop armed before the second jump ends it.
        ctl.jump(Duration::from_secs(2));
        ctl.fresh(3);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert!(
            res.text.contains(
                "no turn_started within the turn-start bound; no fiber_exited within the stop bound"
            ),
            "{}",
            res.text
        );
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// Bounds are phase totals (clock): bytes of an unfinished line that keep
    /// arriving still yield every poll slice, so the phase bounds run. Each
    /// scripted fill moves the test clock 1 ms with no real wait, so
    /// `Pending` can only come from the spent budget, never from a socket
    /// timeout. Yield the total poll budget away and the poll drains the
    /// whole burst instead of stopping at five bytes.
    struct Trickle {
        data: Vec<u8>,
        at: usize,
        clock: Arc<Mutex<Instant>>,
    }

    impl std::io::Read for Trickle {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.at >= self.data.len() {
                return Err(std::io::Error::new(std::io::ErrorKind::WouldBlock, "quiet"));
            }
            *self.clock.lock().expect("clock") += Duration::from_millis(1);
            let end = (self.at + 1).min(self.data.len());
            let n = end - self.at;
            buf[..n].copy_from_slice(&self.data[self.at..end]);
            self.at = end;
            Ok(n)
        }
    }

    impl BufRead for Trickle {
        fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
            if self.at >= self.data.len() {
                return Err(std::io::Error::new(std::io::ErrorKind::WouldBlock, "quiet"));
            }
            *self.clock.lock().expect("clock") += Duration::from_millis(1);
            Ok(&self.data[self.at..self.at + 1])
        }

        fn consume(&mut self, n: usize) {
            self.at += n;
        }
    }

    #[test]
    fn trickling_bytes_yield_the_poll_budget() {
        let start = Instant::now();
        let clock = Arc::new(Mutex::new(start));
        let tick = Arc::clone(&clock);
        let mut reader = Trickle {
            data: vec![b'x'; 64],
            at: 0,
            clock,
        };
        let mut partial = Vec::new();
        match read_line_into_at(&mut reader, &mut partial, Duration::from_millis(5), || {
            *tick.lock().expect("clock")
        }) {
            Ok(Read::Pending) => {}
            Ok(Read::Line(_)) => panic!("trickle carries no newline"),
            Err(ReadErr::Lost(detail)) => panic!("scripted trickle lost: {detail}"),
        }
        // One byte per millisecond against the 5 ms poll slice: the fifth
        // fill spends the budget with most of the burst still unread.
        // Without the yield the poll would drain all 64 bytes first.
        assert_eq!(partial, vec![b'x'; 5]);
    }

    /// T4 (R3): a `fiber_exited` read inside a `turn_start_wait`-armed stop
    /// wait is the verdict. The arm already sent the `close now`, so the
    /// session is closed even though the run ends without the stop text.
    #[test]
    fn exit_inside_turn_start_wait_is_the_verdict() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            let (_, close) = recv_id(srv);
            assert_eq!(close["command"], "close");
            assert_eq!(close["args"]["now"], true);
            assert_eq!(close["session_id"], "s_1");
            srv.send(&exited_ev(10, 1, "", Some("boom")));
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.turn_start_wait = Duration::from_millis(50);
        req.bounds.turn_wait = None;
        req.bounds.stop_wait = Duration::from_millis(50);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::AfterPromptAck, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("phase entry");
        gate_tx.send(()).expect("release");
        // The jump arms the stop; the exit the fake sends on the `close now`
        // is still the verdict, with the stop wait frozen short of expiry.
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert!(
            res.text.contains("session exited before the turn started"),
            "{}",
            res.text
        );
        assert!(res.text.contains("boom"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
            ["start", "subscribe", "prompt", "close"]
        );
    }

    /// T4 (clock): a silent hub through the `start` ack times out with the
    /// R9 text. The clock jumps past `ack_wait` only after fresh polls prove
    /// the gated wait fixed its deadline; no real bound is waited out. No
    /// session is open, so the cleanup sends no `close` at all.
    #[test]
    fn unanswered_start_sends_no_close() {
        let (path, rx) = spawn_fake(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (_, start) = recv_id(srv);
            assert_eq!(start["command"], "start");
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.ack_wait = Duration::from_millis(50);
        req.bounds.poll_slice = Duration::from_millis(5);
        let (fired_tx, fired_rx) = mpsc::channel::<()>();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (hooks, ctl) = gated_clock(Instant::now(), Point::BeforeStartAnswer, gate_rx, fired_tx);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        fired_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("start wait");
        gate_tx.send(()).expect("release");
        ctl.fresh(2);
        ctl.jump(Duration::from_secs(2));
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert!(
            res.text
                .contains("no answer to `start` within the ack bound"),
            "{}",
            res.text
        );
        assert_eq!(res.session_id, None);
        assert_eq!(res.is_error, Some(true));
        assert!(
            crate::output::derive_status(&res.text, res.is_error, res.clean_exit)
                == crate::types::RunStatus::Error
        );
        assert_eq!(received_commands(&join_fake(&path, rx)), ["start"]);
    }

    /// T4 (clock): `turn_wait: None` never expires. The clock jumps a day
    /// mid-run while events flow, and the run still reaches Done: no phase
    /// deadline is consulted for the verdict wait.
    #[test]
    fn turn_wait_none_ignores_a_day_jump() {
        let (hooks, clock) = manual_clock(Instant::now());
        let (plain_tx, plain_rx) = mpsc::channel::<()>();
        let (go_tx, go_rx) = mpsc::channel::<()>();
        let (path, rx) = spawn_fake(move |srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let (start_id, _) = recv_id(srv);
            srv.send(&accepted(
                &start_id,
                serde_json::json!({"session_id": "s_1"}),
            ));
            let (sub_id, _) = recv_id(srv);
            srv.send(&accepted(&sub_id, serde_json::json!({"last_seq": 7})));
            let (prompt_id, _) = recv_id(srv);
            srv.send(&accepted(&prompt_id, serde_json::json!({"last_seq": 8})));
            srv.send(&turn_started_ev(&prompt_id, 9));
            for seq in 10..13 {
                srv.send(&ev(
                    "assistant_message_delta",
                    seq,
                    serde_json::json!({"text": "still going"}),
                ));
            }
            srv.send(&turn_completed_ev(13, "completed", None));
            let (_, plain) = recv_id(srv);
            assert_eq!(plain["command"], "close");
            assert!(plain.get("args").is_none());
            plain_tx.send(()).expect("plain close");
            go_rx.recv_timeout(Duration::from_secs(15)).expect("go");
            for seq in 14..17 {
                srv.send(&ev(
                    "assistant_message_delta",
                    seq,
                    serde_json::json!({"text": "still going"}),
                ));
            }
            srv.send(&exited_ev(17, 0, "DONE", None));
            srv.expect_eof();
        });
        let mut req = hub_request();
        req.bounds.turn_wait = None;
        req.bounds.poll_slice = Duration::from_millis(5);
        let run = spawn_turn_with(req, path.clone(), hooks);
        let res_rx = drive_async(run);
        plain_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("plain");
        *clock.lock().expect("clock") += Duration::from_secs(24 * 3600);
        go_tx.send(()).expect("fake");
        let res = res_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("result");
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(res.session_id.as_deref(), Some("s_1"));
        assert_eq!(
            received_commands(&join_fake(&path, rx)),
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
            let (_, summary) = recv_id(srv);
            assert_eq!(summary["command"], "subscribe");
            assert_eq!(summary["args"]["level"], "summary");
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
