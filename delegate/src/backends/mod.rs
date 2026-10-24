pub mod claude;
pub mod codex;
pub mod cursor;
pub mod fiber;
pub mod muse;
pub mod pi;
pub mod types;

use crate::types::JobSpec;
use crate::util::captured_command;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStderr, ChildStdout, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use types::{BackendResult, Event, EventFn, Spawned};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    Cursor,
    Pi,
    Claude,
    Fiber,
    Codex,
    Muse,
}

impl Backend {
    /// None when `name` is not an implemented backend.
    pub fn from_name(name: &str) -> Option<Backend> {
        match name {
            "cursor" => Some(Self::Cursor),
            "pi" => Some(Self::Pi),
            "claude" => Some(Self::Claude),
            "fiber" => Some(Self::Fiber),
            "codex" => Some(Self::Codex),
            "muse" => Some(Self::Muse),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Cursor => "cursor",
            Self::Pi => "pi",
            Self::Claude => "claude",
            Self::Fiber => "fiber",
            Self::Codex => "codex",
            Self::Muse => "muse",
        }
    }

    /// Implemented backends, in doctor order.
    pub const ALL: [Backend; 6] = [
        Self::Cursor,
        Self::Pi,
        Self::Claude,
        Self::Fiber,
        Self::Codex,
        Self::Muse,
    ];

    /// Resolved binary path (env override, then PATH, then ~/.local/bin).
    pub fn bin(self) -> String {
        match self {
            Self::Cursor => cursor::resolve_bin(None),
            Self::Pi => pi::resolve_bin(None),
            Self::Claude => claude::resolve_bin(None),
            Self::Fiber => fiber::resolve_bin(None),
            Self::Codex => codex::resolve_bin(None),
            Self::Muse => muse::resolve_bin(None),
        }
    }

    /// Full argv (without the binary). Every job runs with writes enabled.
    ///
    /// This is a staging form: the prompt rides after the `--` separator,
    /// exactly where the child would take it. Most backends execute it as-is.
    /// Codex and muse lower it in spawn (codex inserting `-C <cwd>` from the
    /// spec and replacing the trailing prompt with `-`, muse inserting
    /// `--workspace <cwd>` from the spec) and codex pipes the staged prompt to
    /// the child's stdin, so the staging form itself is never executed and
    /// must never be mistaken for child wire argv in tests: assert the actual
    /// child argv (and stdin bytes) through a fake process instead.
    pub fn argv(self, model: &str, session: Option<&str>, prompt: &str) -> Vec<String> {
        match self {
            Self::Cursor => cursor::argv(model, session, prompt),
            Self::Pi => pi::argv(model, session, prompt),
            Self::Claude => claude::argv(model, session, prompt),
            Self::Fiber => fiber::argv(model, session, prompt),
            Self::Codex => codex::argv(model, session, prompt),
            Self::Muse => muse::argv(model, session, prompt),
        }
    }

    /// Spawn and drive the child; same contract as today's `Backend::run`.
    pub fn spawn(self, spec: &JobSpec) -> Spawned {
        match self {
            Self::Cursor => cursor::spawn(spec),
            Self::Pi => pi::spawn(spec),
            Self::Claude => claude::spawn(spec),
            Self::Fiber => fiber::spawn(spec),
            Self::Codex => codex::spawn(spec),
            Self::Muse => muse::spawn(spec),
        }
    }

    pub(crate) fn fill_doctor(
        self,
        report: &mut crate::types::DoctorReport,
        opts: &crate::doctor::RunDoctorOpts<'_>,
    ) {
        match self {
            Self::Cursor => cursor::doctor::fill(report, opts),
            Self::Pi => pi::doctor::fill(report, opts),
            Self::Claude => claude::doctor::fill(report, opts),
            Self::Fiber => fiber::doctor::fill(report, opts),
            Self::Codex => codex::doctor::fill(report, opts),
            // The muse doctor probe is a follow-up after #596.
            Self::Muse => {}
        }
    }

    pub(crate) fn doctor_lines(self, report: &crate::types::DoctorReport) -> (String, bool) {
        match self {
            Self::Cursor => cursor::doctor::lines(report),
            Self::Pi => pi::doctor::lines(report),
            Self::Claude => claude::doctor::lines(report),
            Self::Fiber => fiber::doctor::lines(report),
            Self::Codex => codex::doctor::lines(report),
            // The muse doctor probe is a follow-up after #596.
            Self::Muse => (String::new(), false),
        }
    }
}

impl types::Runner for Backend {
    fn run(&self, spec: &JobSpec) -> Spawned {
        self.spawn(spec)
    }

    fn resume_argv(&self, model: &str, session: &str, prompt: &str) -> Vec<String> {
        self.argv(model, Some(session), prompt)
    }
}

/// Only a 64 KB tail of stderr is ever reported; pump keeps a bounded window of it.
pub(crate) const STDERR_KEEP: usize = 64 * 1024;

/// A child with its pipes detached, in its own process group (so cancel also stops
/// the shell commands the agent started). The drive closure below owns the wait.
pub(crate) struct Started {
    pub pid: libc::pid_t,
    pub reaped: Arc<AtomicBool>,
    pub child: Child,
    pub stdout: ChildStdout,
    pub stderr: ChildStderr,
}

pub(crate) fn start_child(spec: &JobSpec) -> Result<Started, String> {
    start_child_with_stdin(spec, Stdio::null())
}

/// Like [`start_child`], but the child inherits `stdin` instead of null:
/// codex pipes its staged prompt to the child while the other backends keep
/// null stdin. The caller owns the prompt-sized write: do it on the drive
/// thread while the pipes drain, never synchronously during dispatch.
pub(crate) fn start_child_with_stdin(spec: &JobSpec, stdin: Stdio) -> Result<Started, String> {
    let spawned = captured_command(&spec.bin)
        .map_err(|e| format!("cannot write cargo-mutants shim: {e}"))?
        .args(&spec.argv)
        .current_dir(&spec.cwd)
        .stdin(stdin)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Own process group, so cancel also stops the shell commands the agent started.
        .process_group(0)
        .spawn();
    let mut child = spawned.map_err(|e| e.to_string())?;
    let pid = child.id() as libc::pid_t;
    // Set once the child is reaped, so a late kill can't hit a recycled pid.
    let reaped = Arc::new(AtomicBool::new(false));
    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");
    Ok(Started {
        pid,
        reaped,
        child,
        stdout,
        stderr,
    })
}

/// SIGTERM to the child's process group on the first call, SIGKILL on any
/// later call. Safe on a recycled pid only because the driver sets `reaped`
/// right after `wait`.
pub(crate) fn killer(pid: libc::pid_t, reaped: Arc<AtomicBool>) -> Box<dyn Fn() + Send + Sync> {
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    Box::new(move || {
        if reaped.load(Ordering::SeqCst) {
            return;
        }
        let n = calls.fetch_add(1, Ordering::SeqCst);
        let sig = if n == 0 { libc::SIGTERM } else { libc::SIGKILL };
        unsafe { libc::kill(-pid, sig) };
    })
}

/// The result when the child never started: the spawn error is the text.
pub(crate) fn spawn_failed(msg: &str) -> Spawned {
    let msg = msg.to_string();
    Spawned {
        kill: Box::new(|| {}),
        session_id: None,
        drive: Box::new(move |_| BackendResult {
            text: msg.clone(),
            is_error: Some(true),
            clean_exit: false,
            stderr: msg.clone(),
            ..Default::default()
        }),
    }
}

pub(crate) struct Pumped {
    pub stderr: String,
    pub saw_stdout: bool,
    pub clean_exit: bool,
}

/// Pump both pipes to EOF (stderr on a scoped thread), then `wait` for the exit
/// status. `handle_line` sees each stdout line without its newline; the backend
/// parses it and emits its own progress events through `on`.
pub(crate) fn pump(
    mut stdout: impl Read,
    mut stderr: impl Read + Send,
    on: EventFn<'_>,
    wait: impl FnOnce() -> bool,
    mut handle_line: impl FnMut(&[u8]),
) -> Pumped {
    std::thread::scope(|s| {
        let err = s.spawn(|| {
            let mut kept: Vec<u8> = Vec::new();
            let mut buf = [0u8; 4096];
            while let Ok(n) = stderr.read(&mut buf) {
                if n == 0 {
                    break;
                }
                kept.extend_from_slice(&buf[..n]);
                if kept.len() > STDERR_KEEP {
                    kept.drain(..kept.len() - STDERR_KEEP);
                }
                on(Event::Stderr);
            }
            crate::util::strip_ansi(&String::from_utf8_lossy(&kept))
        });

        let mut pending: Vec<u8> = Vec::new();
        let mut buf = [0u8; 8192];
        let mut saw_stdout = false;
        while let Ok(n) = stdout.read(&mut buf) {
            if n == 0 {
                break;
            }
            saw_stdout = true;
            on(Event::Activity);
            pending.extend_from_slice(&buf[..n]);
            while let Some(i) = pending.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = pending.drain(..=i).collect();
                handle_line(&line[..i]);
            }
        }
        // Flush a trailing line that arrived without a terminating newline.
        if !pending.is_empty() {
            handle_line(&pending);
        }
        let stderr = err.join().unwrap_or_default();
        Pumped {
            stderr,
            saw_stdout,
            clean_exit: wait(),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_name_maps_implemented_backends_and_rejects_the_rest() {
        assert_eq!(Backend::from_name("cursor"), Some(Backend::Cursor));
        assert_eq!(Backend::Cursor.name(), "cursor");
        assert_eq!(Backend::from_name("pi"), Some(Backend::Pi));
        assert_eq!(Backend::Pi.name(), "pi");
        assert_eq!(Backend::from_name("claude"), Some(Backend::Claude));
        assert_eq!(Backend::Claude.name(), "claude");
        assert_eq!(Backend::from_name("fiber"), Some(Backend::Fiber));
        assert_eq!(Backend::Fiber.name(), "fiber");
        assert_eq!(Backend::from_name("codex"), Some(Backend::Codex));
        assert_eq!(Backend::Codex.name(), "codex");
        assert_eq!(Backend::from_name("muse"), Some(Backend::Muse));
        assert_eq!(Backend::Muse.name(), "muse");
        assert!(Backend::from_name("nope").is_none());
        assert!(Backend::ALL.contains(&Backend::Muse));
    }

    /// A null-stdin child sees EOF at once; a piped child receives exactly
    /// the bytes written. Codex alone uses the piped form; every other
    /// backend keeps null stdin.
    #[test]
    fn null_stdin_sees_eof_at_once() {
        let spec = crate::job::tests::spec_of(|s| {
            s.bin = "/bin/cat".into();
            s.argv = vec![];
            s.cwd = "/tmp".into();
        });
        let mut started = start_child(&spec).expect("start cat");
        let mut out = String::new();
        use std::io::Read;
        started.stdout.read_to_string(&mut out).unwrap();
        assert_eq!(out, "");
        let clean = started.child.wait().map(|s| s.success()).unwrap_or(false);
        assert!(clean);
    }

    #[test]
    fn piped_stdin_round_trips_exact_bytes() {
        let spec = crate::job::tests::spec_of(|s| {
            s.bin = "/bin/cat".into();
            s.argv = vec![];
            s.cwd = "/tmp".into();
        });
        let prompt = "-leading dash\nünicode \u{1F600}\n";
        let mut started = start_child_with_stdin(&spec, Stdio::piped()).expect("start cat");
        use std::io::Write;
        started
            .child
            .stdin
            .take()
            .unwrap()
            .write_all(prompt.as_bytes())
            .unwrap();
        let mut out = String::new();
        use std::io::Read;
        started.stdout.read_to_string(&mut out).unwrap();
        assert_eq!(out, prompt);
        let clean = started.child.wait().map(|s| s.success()).unwrap_or(false);
        assert!(clean);
    }

    /// A SIGTERM-resistant child survives the first kill (SIGTERM) and dies
    /// on the second (SIGKILL) with signal 9.
    #[test]
    fn killer_escalates_to_sigkill_on_second_call() {
        let stem = format!(
            "killer-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let ready = std::env::temp_dir().join(format!("{stem}-ready"));
        let recvd = std::env::temp_dir().join(format!("{stem}-term"));
        let _ = std::fs::remove_file(&ready);
        let _ = std::fs::remove_file(&recvd);
        let spec = crate::job::tests::spec_of(|s| {
            s.bin = "/bin/sh".into();
            s.argv = vec![
                "-c".into(),
                format!(
                    "trap \"touch '{}'; trap '' TERM\" TERM; touch '{}'; while :; do sleep 1; done",
                    recvd.display(),
                    ready.display()
                ),
            ];
            s.cwd = "/tmp".into();
        });
        let mut started = start_child(&spec).expect("start trap child");
        let pid = started.pid;
        let reaped = started.reaped.clone();
        for _ in 0..500 {
            if ready.exists() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(ready.exists(), "trap child never became ready");
        let kill = killer(pid, reaped.clone());
        kill();
        // The trap receipt acknowledges the SIGTERM: no fixed delay assumes
        // the child processed it before asserting it survived it.
        for _ in 0..500 {
            if recvd.exists() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(recvd.exists(), "trap child never saw SIGTERM");
        let still_alive = started.child.try_wait().expect("try_wait works").is_none();
        assert!(still_alive, "SIGTERM-resistant child died on SIGTERM");
        kill();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let status = loop {
            if let Some(status) = started.child.try_wait().expect("try_wait works") {
                break status;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "child survived SIGKILL past 5 s"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        };
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(status.signal(), Some(9));
        reaped.store(true, std::sync::atomic::Ordering::SeqCst);
        let _ = std::fs::remove_file(&ready);
        let _ = std::fs::remove_file(&recvd);
    }

    /// Once `reaped` is set, neither call signals the child, so a late kill
    /// cannot hit a recycled pid.
    #[test]
    fn killer_sends_nothing_once_reaped() {
        let spec = crate::job::tests::spec_of(|s| {
            s.bin = "/bin/sleep".into();
            s.argv = vec!["30".into()];
            s.cwd = "/tmp".into();
        });
        let mut started = start_child(&spec).expect("start sleep");
        started
            .reaped
            .store(true, std::sync::atomic::Ordering::SeqCst);
        let kill = killer(started.pid, started.reaped.clone());
        kill();
        kill();
        // Neither call may signal: watch the child for the whole window and
        // fail at once with evidence instead of sleeping first and looking once.
        let t = std::time::Instant::now();
        while t.elapsed() < std::time::Duration::from_millis(300) {
            let alive = started.child.try_wait().expect("try_wait works").is_none();
            assert!(alive, "reaped child was signalled");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        unsafe { libc::kill(-started.pid, libc::SIGKILL) };
        let _ = started.child.wait();
        started
            .reaped
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// #83: an inherited FORCE_COLOR makes pi colour its stderr even into a
    /// pipe. These bytes match `FORCE_COLOR=3 pi -p --mode json` with a bad model.
    #[test]
    fn pump_strips_ansi_from_stderr() {
        let stderr: &[u8] = b"\x1b[33mWarning: No project session found\x1b[39m\n\
            \x1b[31mError: Model \"nope/x\" not found.\x1b[39m\n";
        let pumped = pump(&b""[..], stderr, &|_| {}, || false, |_| {});
        assert_eq!(
            pumped.stderr,
            "Warning: No project session found\nError: Model \"nope/x\" not found.\n"
        );
    }
}
