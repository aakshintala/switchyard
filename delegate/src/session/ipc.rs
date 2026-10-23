use crate::session::state::Paths;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq, Eq)]
pub enum IpcError {
    Unreachable(String),
    Timeout,
    BadReply(String),
}

impl std::fmt::Display for IpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unreachable(message) => write!(f, "session supervisor is unreachable: {message}"),
            Self::Timeout => write!(f, "session supervisor request timed out"),
            Self::BadReply(message) => write!(f, "invalid session supervisor reply: {message}"),
        }
    }
}

impl std::error::Error for IpcError {}

pub fn request(paths: &Paths, id: &str, req: &Value, timeout: Duration) -> Result<Value, IpcError> {
    let socket = paths
        .socket_path(id)
        .map_err(|error| IpcError::Unreachable(error.to_string()))?;
    let mut line =
        serde_json::to_vec(req).map_err(|error| IpcError::BadReply(error.to_string()))?;
    line.push(b'\n');
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or(IpcError::Timeout)?;
    let mut stream = UnixStream::connect(socket).map_err(|error| match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => IpcError::Timeout,
        _ => IpcError::Unreachable(error.to_string()),
    })?;
    for chunk in line.chunks(64 * 1024) {
        set_remaining_write_timeout(&stream, deadline)?;
        if Instant::now() >= deadline {
            return Err(IpcError::Timeout);
        }
        stream
            .write_all(chunk)
            .map_err(|error| map_io_error(error, "socket write"))?;
    }
    set_remaining_read_timeout(&stream, deadline)?;

    let mut reader = BufReader::new(stream);
    let mut reply = Vec::new();
    match reader.read_until(b'\n', &mut reply) {
        Ok(0) => return Err(IpcError::BadReply("server closed without a reply".into())),
        Ok(_) if reply.last() != Some(&b'\n') => {
            return Err(IpcError::BadReply(
                "reply was not newline terminated".into(),
            ));
        }
        Ok(_) => {}
        Err(error) => return Err(map_io_error(error, "socket read")),
    }
    reply.pop();
    serde_json::from_slice(&reply).map_err(|error| IpcError::BadReply(error.to_string()))
}

fn set_remaining_write_timeout(stream: &UnixStream, deadline: Instant) -> Result<(), IpcError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(IpcError::Timeout);
    }
    stream
        .set_write_timeout(Some(remaining))
        .map_err(|error| IpcError::Unreachable(format!("set socket write timeout: {error}")))
}

fn set_remaining_read_timeout(stream: &UnixStream, deadline: Instant) -> Result<(), IpcError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(IpcError::Timeout);
    }
    stream
        .set_read_timeout(Some(remaining))
        .map_err(|error| IpcError::Unreachable(format!("set socket read timeout: {error}")))
}

fn map_io_error(error: std::io::Error, operation: &str) -> IpcError {
    match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => IpcError::Timeout,
        _ => IpcError::Unreachable(format!("{operation}: {error}")),
    }
}
