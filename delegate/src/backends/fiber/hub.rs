//! Supervised hub client for the Fiber door (see #682).
//!
//! A program that drives sessions is a client of the hub: it connects to
//! `<FIBER_HOME>/run/hub`, starts a supervised session, drives it with the
//! driver commands and ends it with `close`, reading `fiber_exited` as the
//! verdict. Every read on the socket is a plain blocking read: no timeout,
//! no poll loop and no second thread.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

/// Newline JSON framing cap: a hub line over 64 MiB ends the run, it is
/// never truncated.
const READ_CAP: u64 = 64 * 1024 * 1024;
/// A socket path is limited to 103 bytes on macOS.
const MAX_SOCKET_PATH: usize = 103;

/// Fixed closing sentence on every error text the client builds, so no text
/// the client builds ever ends in a hub or model `STATUS:` line.
const FIXED: &str = "The delegate hub client ended the run with an error.";

fn crash_text(body: String) -> String {
    format!("{body}\n{FIXED}")
}

/// What went wrong reading one hub line.
#[derive(Debug, PartialEq)]
enum ReadErr {
    /// EOF or a read error: the connection is lost.
    Lost(String),
    /// A hub line over the 64 MiB cap, never a truncation.
    TooLong,
}

/// Read one newline-terminated hub line, keeping partial bytes across reads.
/// A line that passes the 64 MiB cap is an error, never a truncation.
fn read_line(reader: &mut BufReader<UnixStream>) -> Result<Vec<u8>, ReadErr> {
    read_line_capped(reader, READ_CAP)
}

fn read_line_capped<R: BufRead>(reader: &mut R, cap: u64) -> Result<Vec<u8>, ReadErr> {
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
                    if line.len() as u64 + nl as u64 > cap {
                        return Err(ReadErr::TooLong);
                    }
                    line.extend_from_slice(&buf[..nl]);
                    Next::Done(nl + 1)
                }
                None => {
                    if line.len() as u64 + buf.len() as u64 > cap {
                        return Err(ReadErr::TooLong);
                    }
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
        ReadErr::TooLong => crash_text("protocol error: hub line over 64 MiB".to_string()),
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
/// unset. An empty or relative value is an error naming `FIBER_HOME`, with
/// no `~/.fiber` fallback.
pub fn fiber_home() -> Result<PathBuf, String> {
    match std::env::var("FIBER_HOME") {
        Err(_) => Ok(crate::util::homedir().join(".fiber")),
        Ok(v) if v.is_empty() => {
            Err("FIBER_HOME is set but empty; set it to an absolute path or unset it".to_string())
        }
        Ok(v) => {
            let path = PathBuf::from(&v);
            if path.is_absolute() {
                Ok(path)
            } else {
                Err(format!(
                    "FIBER_HOME is relative ({v}); set it to an absolute path or unset it"
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

/// Why waiting for an answer stopped without one. `Protocol` already holds
/// the final crash text; `Lost` holds the raw read detail for the caller to
/// name the wait it was in.
#[derive(Debug)]
enum AwaitFail {
    Protocol(String),
    Lost(String),
    TooLong,
}

impl HubConn {
    fn send(&mut self, line: &str) -> std::io::Result<()> {
        write_line(&mut self.writer, line)
    }

    /// Read until a `command_accepted` or `command_rejected` whose
    /// `payload.command_id` equals `id`. Every other line passes to
    /// `on_other` in arrival order, so no line is lost while waiting.
    fn await_ack(&mut self, id: &str, mut on_other: impl FnMut(&[u8])) -> Result<Ack, AwaitFail> {
        loop {
            let raw = match read_line(&mut self.reader) {
                Ok(raw) => raw,
                Err(ReadErr::Lost(detail)) => return Err(AwaitFail::Lost(detail)),
                Err(ReadErr::TooLong) => return Err(AwaitFail::TooLong),
            };
            let parsed: serde_json::Value = match serde_json::from_slice(&raw) {
                Ok(v) => v,
                Err(_) => {
                    on_other(&raw);
                    continue;
                }
            };
            let kind = parsed.get("kind").and_then(|k| k.as_str()).unwrap_or("");
            if kind != "command_accepted" && kind != "command_rejected" {
                on_other(&raw);
                continue;
            }
            let cid = parsed
                .get("payload")
                .and_then(|p| p.get("command_id"))
                .and_then(|c| c.as_str());
            let Some(cid) = cid else {
                return Err(AwaitFail::Protocol(crash_text(format!(
                    "protocol error: hub answer without command_id: {}",
                    first80(&raw)
                ))));
            };
            if cid != id {
                return Err(AwaitFail::Protocol(crash_text(format!(
                    "protocol error: hub answer for unknown command {cid}"
                ))));
            }
            if kind == "command_accepted" {
                let result = parsed
                    .get("payload")
                    .and_then(|p| p.get("result"))
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                return Ok(Ack::Accepted { result });
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
            return Ok(Ack::Rejected { code, message });
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
                Err(ReadErr::TooLong) => panic!("fake hub got an over-cap client line"),
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
    fn line_over_64mib_is_rejected_not_truncated() {
        let (client, server) = UnixStream::pair().expect("socket pair");
        let big = "x".repeat(64 * 1024 * 1024 + 1);
        std::thread::spawn(move || {
            let mut server = server;
            write_line(&mut server, &big).expect("send big line");
        });
        let mut reader = BufReader::new(client);
        assert_eq!(read_line(&mut reader), Err(ReadErr::TooLong));
    }

    #[test]
    fn line_at_the_cap_reads_whole() {
        let mut cursor = std::io::Cursor::new(format!("{}\n", "y".repeat(64)));
        assert_eq!(read_line_capped(&mut cursor, 64).expect("at cap").len(), 64);
        let mut cursor = std::io::Cursor::new(format!("{}\n", "y".repeat(65)));
        assert_eq!(read_line_capped(&mut cursor, 64), Err(ReadErr::TooLong));
    }

    #[test]
    fn cap_edge_below_at_and_above() {
        let mut below = std::io::Cursor::new(b"1234567\n".to_vec());
        assert_eq!(read_line_capped(&mut below, 8).expect("below"), b"1234567");
        let mut at = std::io::Cursor::new(b"12345678\n".to_vec());
        assert_eq!(read_line_capped(&mut at, 8).expect("at"), b"12345678");
        let mut above = std::io::Cursor::new(b"123456789\n".to_vec());
        assert_eq!(read_line_capped(&mut above, 8), Err(ReadErr::TooLong));
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
        assert!(matches!(
            read_line_capped(&mut empty, 8),
            Err(ReadErr::Lost(_))
        ));
        let mut partial = std::io::Cursor::new(b"abc".to_vec());
        assert!(matches!(
            read_line_capped(&mut partial, 8),
            Err(ReadErr::Lost(_))
        ));
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
        let Ack::Accepted { result } = conn.await_ack("c_1", |_| {}).expect("ack") else {
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
        let Ack::Rejected { code, message } = conn.await_ack("c_1", |_| {}).expect("ack") else {
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
            let Err(AwaitFail::Protocol(text)) = conn.await_ack("c_1", |_| {}) else {
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
        let Err(AwaitFail::Protocol(text)) = conn.await_ack("c_1", |_| {}) else {
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
        let Ack::Accepted { .. } = conn
            .await_ack("c_1", |raw| {
                seen.push(String::from_utf8_lossy(raw).into_owned())
            })
            .expect("ack")
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
        let (mut conn, _) = connect(&path).expect("connect");
        let Err(AwaitFail::Lost(_)) = conn.await_ack("c_1", |_| {}) else {
            panic!("expected loss");
        };
        drop(conn);
        join_fake(&path, rx);
    }

    #[test]
    fn over_cap_line_while_waiting_is_too_long() {
        let (mut conn, path, rx) = connect_pair(|srv| {
            srv.send(&hello(serde_json::json!(1), "9.9.9"));
            let big = "z".repeat(64 * 1024 * 1024 + 1);
            write_line(&mut srv.writer, &big).expect("send big");
        });
        let Err(AwaitFail::TooLong) = conn.await_ack("c_1", |_| {}) else {
            panic!("expected too-long");
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
}
