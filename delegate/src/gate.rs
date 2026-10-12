use crate::status_record::job_record_path;
use crate::types::GateResult;
use crate::util::{Abort, captured_command, strip_ansi, tail};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Only the last 2048 bytes of stdout+stderr are reported, so keep that much of each.
const KEEP: usize = 2048;
/// Gates run test suites, so the bound is generous — but it exists: a gate like
/// `sleep infinity` used to hang finalize forever, keeping the job's heartbeat alive and
/// making cancel/shutdown unable to finish the job.
pub const DEFAULT_GATE_TIMEOUT_MS: u64 = 10 * 60 * 1000;

/// How long a SIGTERMed gate gets to exit before SIGKILL.
const KILL_GRACE: Duration = Duration::from_secs(2);

pub struct GateOpts<'a> {
    pub timeout_ms: Option<u64>,
    pub signal: Option<&'a Abort>,
}

#[derive(Clone, Copy, Default)]
enum AnsiState {
    #[default]
    Text,
    Escape,
    Csi,
    Osc,
    OscEscape,
}

#[derive(Default)]
struct AnsiStripper {
    state: AnsiState,
}

impl AnsiStripper {
    fn write_stripped(&mut self, bytes: &[u8], writer: &mut impl Write) -> std::io::Result<()> {
        let mut clean = Vec::with_capacity(bytes.len());
        for &byte in bytes {
            match self.state {
                AnsiState::Text if byte == b'\x1b' => self.state = AnsiState::Escape,
                AnsiState::Text => clean.push(byte),
                AnsiState::Escape => {
                    self.state = match byte {
                        b'[' => AnsiState::Csi,
                        b']' => AnsiState::Osc,
                        _ => AnsiState::Text,
                    };
                }
                AnsiState::Csi if (b'@'..=b'~').contains(&byte) => {
                    self.state = AnsiState::Text;
                }
                AnsiState::Csi => {}
                AnsiState::Osc if byte == 0x07 => self.state = AnsiState::Text,
                AnsiState::Osc if byte == b'\x1b' => self.state = AnsiState::OscEscape,
                AnsiState::Osc => {}
                AnsiState::OscEscape if byte == b'\\' || byte == 0x07 => {
                    self.state = AnsiState::Text;
                }
                AnsiState::OscEscape if byte == b'\x1b' => {}
                AnsiState::OscEscape => self.state = AnsiState::Osc,
            }
        }
        writer.write_all(&clean)
    }
}

#[derive(Default)]
struct StreamOutput {
    tail: Vec<u8>,
    error: Option<String>,
}

fn read_stream(mut reader: impl Read, name: &str, log: Option<Arc<Mutex<File>>>) -> StreamOutput {
    let mut output = StreamOutput {
        tail: Vec::with_capacity(KEEP),
        error: None,
    };
    let mut stripper = AnsiStripper::default();
    let mut buf = [0u8; 4096];
    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                output.error = Some(format!("cannot read gate {name}: {e}"));
                break;
            }
        };
        output.tail.extend_from_slice(&buf[..n]);
        if output.tail.len() > KEEP {
            output.tail.drain(..output.tail.len() - KEEP);
        }
        if let Some(log) = &log
            && output.error.is_none()
        {
            let mut file = log.lock().unwrap_or_else(|e| e.into_inner());
            if let Err(e) = stripper.write_stripped(&buf[..n], &mut *file) {
                output.error = Some(format!("cannot write gate output log: {e}"));
            }
        }
    }
    output
}

fn create_output_log(job_id: &str) -> std::io::Result<(PathBuf, File)> {
    let record = job_record_path(job_id);
    let dir = record.parent().expect("job record has a parent");
    fs::create_dir_all(dir)?;
    for run in 1u64.. {
        let name = if run == 1 {
            format!("{job_id}-gate.log")
        } else {
            format!("{job_id}-gate-{run}.log")
        };
        let path = dir.join(name);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
    }
    unreachable!("gate log run counter exhausted")
}

fn append_error(error: &mut Option<String>, message: String) {
    if let Some(error) = error {
        error.push_str("; ");
        error.push_str(&message);
    } else {
        *error = Some(message);
    }
}

fn record_output(output: &str, file: &mut Option<File>, error: &mut Option<String>) {
    if let Some(file) = file
        && let Err(e) = file.write_all(output.as_bytes())
    {
        append_error(error, format!("cannot write gate output log: {e}"));
    }
}

fn gate_error(killed: bool, exit_code: i32, output_error: Option<String>) -> Option<String> {
    let killed_error =
        killed.then(|| format!("gate killed after timeout or abort signal (exitCode {exit_code})"));
    match (killed_error, output_error) {
        (Some(killed), Some(output)) => Some(format!("{killed}; {output}")),
        (Some(error), None) | (None, Some(error)) => Some(error),
        (None, None) => None,
    }
}

/// Run the postcondition `command` via `/bin/sh -c` in `cwd`. Never fails — always returns a
/// GateResult, `passed = exitCode == 0`. Bounded: the gate's whole process group is
/// SIGTERMed after `timeout_ms` or when `signal` is set, so a test runner the shell started
/// can't keep the pipes open.
pub fn run_gate(command: &str, cwd: &str, opts: GateOpts<'_>) -> GateResult {
    run_gate_inner(command, cwd, None, opts)
}

/// Run a job gate and keep its full output beside the job record.
pub fn run_gate_for_job(command: &str, cwd: &str, job_id: &str, opts: GateOpts<'_>) -> GateResult {
    run_gate_inner(command, cwd, Some(job_id), opts)
}

fn run_gate_inner(
    command: &str,
    cwd: &str,
    job_id: Option<&str>,
    opts: GateOpts<'_>,
) -> GateResult {
    let (output_path, mut output_file, mut output_error) = match job_id {
        Some(id) => match create_output_log(id) {
            Ok((path, file)) => (Some(path), Some(file), None),
            Err(e) => (
                None,
                None,
                Some(format!("cannot create gate output log: {e}")),
            ),
        },
        None => (None, None, None),
    };
    let timeout = Duration::from_millis(opts.timeout_ms.unwrap_or(DEFAULT_GATE_TIMEOUT_MS));
    let start = Instant::now();
    let spawned = captured_command("/bin/sh")
        .arg("-c")
        .arg(command)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn();
    let mut child = match spawned {
        Ok(c) => c,
        Err(e) => {
            let output = e.to_string();
            record_output(&strip_ansi(&output), &mut output_file, &mut output_error);
            return GateResult {
                command: command.to_string(),
                exit_code: 1,
                passed: false,
                output_tail: output,
                output_path: output_path.map(|p| p.to_string_lossy().into_owned()),
                error: output_error,
            };
        }
    };
    let pgid = child.id() as libc::pid_t;
    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");
    let output_log = output_file.take().map(|file| Arc::new(Mutex::new(file)));
    let out_log = output_log.clone();
    let err_log = output_log.clone();
    let (status, killed, out, err) = std::thread::scope(|s| {
        let out = s.spawn(move || read_stream(stdout, "stdout", out_log));
        let err = s.spawn(move || read_stream(stderr, "stderr", err_log));
        let mut termed_at: Option<Instant> = None;
        let status = loop {
            match child.try_wait() {
                Ok(Some(st)) => break Some(st),
                Ok(None) => {}
                Err(_) => break None,
            }
            let aborted = opts.signal.is_some_and(|a| a.load(Ordering::SeqCst));
            match termed_at {
                None if aborted || start.elapsed() >= timeout => {
                    termed_at = Some(Instant::now());
                    unsafe { libc::kill(-pgid, libc::SIGTERM) };
                }
                // A gate that traps SIGTERM would otherwise hold finalize forever.
                Some(t) if t.elapsed() >= KILL_GRACE => unsafe {
                    libc::kill(-pgid, libc::SIGKILL);
                },
                _ => {}
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let killed = termed_at.is_some();
        if killed {
            // The shell is gone; take down anything it left holding the pipes.
            unsafe { libc::kill(-pgid, libc::SIGKILL) };
        }
        (
            status,
            killed,
            out.join().unwrap_or_default(),
            err.join().unwrap_or_default(),
        )
    });
    if let Some(error) = out.error {
        append_error(&mut output_error, error);
    }
    if let Some(error) = err.error {
        append_error(&mut output_error, error);
    }
    if let Some(log) = output_log {
        let mut file = log.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = file.flush() {
            append_error(
                &mut output_error,
                format!("cannot flush gate output log: {e}"),
            );
        }
    }
    let combined_tail =
        String::from_utf8_lossy(&out.tail).into_owned() + &String::from_utf8_lossy(&err.tail);
    let exit_code = match status {
        Some(st) => st.code().unwrap_or(1),
        None => 1,
    };
    GateResult {
        command: command.to_string(),
        exit_code,
        passed: exit_code == 0 && !killed,
        output_tail: tail(&strip_ansi(&combined_tail), KEEP),
        output_path: output_path.map(|p| p.to_string_lossy().into_owned()),
        error: gate_error(killed, exit_code, output_error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::AtomicBool;
    use std::time::Instant;

    fn gate_opts() -> GateOpts<'static> {
        GateOpts {
            timeout_ms: None,
            signal: None,
        }
    }

    #[test]
    fn passing_command() {
        let r = run_gate(
            "echo hello && true",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: None,
                signal: None,
            },
        );
        assert!(r.passed);
        assert_eq!(r.exit_code, 0);
        assert!(r.output_tail.contains("hello"));
    }

    #[test]
    fn failing_command() {
        let r = run_gate(
            "echo boom >&2; exit 5",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: None,
                signal: None,
            },
        );
        assert!(!r.passed);
        assert_eq!(r.exit_code, 5);
        assert!(r.output_tail.contains("boom"));
    }

    #[test]
    fn never_throws_nonsense() {
        let r = run_gate(
            "this-command-does-not-exist-xyz",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: None,
                signal: None,
            },
        );
        assert!(!r.passed);
        assert_ne!(r.exit_code, 0);
    }

    #[test]
    fn never_throws_bad_cwd() {
        let r = run_gate(
            "true",
            "/no/such/dir-xyz",
            GateOpts {
                timeout_ms: None,
                signal: None,
            },
        );
        assert!(!r.passed);
        assert_ne!(r.exit_code, 0);
    }

    #[test]
    fn output_tail_capped() {
        let r = run_gate(
            "seq 1 2000",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: None,
                signal: None,
            },
        );
        assert!(r.passed);
        assert_eq!(r.command, "seq 1 2000");
        assert!(r.output_tail.len() <= 2048 + 4);
        assert!(r.output_tail.contains("2000"));
    }

    #[test]
    fn gate_output_file_keeps_every_line_and_strips_ansi() {
        let job_id = crate::util::random_uuid();
        let r = run_gate_for_job(
            r#"seq 1 4000; printf '\033[31mansi\033[0m\n'"#,
            &std::env::current_dir().unwrap().to_string_lossy(),
            &job_id,
            gate_opts(),
        );
        assert!(r.passed);
        assert!(r.output_tail.len() <= KEEP + 4);
        let path = PathBuf::from(r.output_path.as_deref().unwrap());
        assert_eq!(path.parent(), job_record_path(&job_id).parent());

        let mut expected = (1..=4000).map(|n| format!("{n}\n")).collect::<String>();
        expected.push_str("ansi\n");
        let output = fs::read_to_string(&path).unwrap();
        assert_eq!(output, expected);
        assert!(!output.contains('\x1b'));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn gate_runs_for_one_job_keep_separate_files() {
        let job_id = crate::util::random_uuid();
        let cwd = std::env::current_dir().unwrap();
        let cwd = cwd.to_string_lossy();
        let first = run_gate_for_job("printf first", &cwd, &job_id, gate_opts());
        let second = run_gate_for_job("printf second >&2", &cwd, &job_id, gate_opts());
        let first_path = PathBuf::from(first.output_path.as_deref().unwrap());
        let second_path = PathBuf::from(second.output_path.as_deref().unwrap());

        assert_ne!(first_path, second_path);
        assert_eq!(
            first_path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            format!("{job_id}-gate.log")
        );
        assert_eq!(
            second_path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            format!("{job_id}-gate-2.log")
        );
        assert_eq!(fs::read_to_string(&first_path).unwrap(), "first");
        assert_eq!(fs::read_to_string(&second_path).unwrap(), "second");
        let _ = fs::remove_file(first_path);
        let _ = fs::remove_file(second_path);
    }

    #[test]
    fn ansi_stripper_handles_escape_sequences_split_across_chunks() {
        let mut stripper = AnsiStripper::default();
        let mut output = Vec::new();

        stripper
            .write_stripped(b"before\x1b[3", &mut output)
            .unwrap();
        stripper
            .write_stripped(b"1mred\x1b[0m-after", &mut output)
            .unwrap();

        assert_eq!(output, b"beforered-after");
    }

    #[test]
    fn output_tail_is_ansi_stripped() {
        let r = run_gate(
            "printf '\\033[31mred\\033[0m'",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: None,
                signal: None,
            },
        );
        assert!(r.passed);
        assert!(r.output_tail.contains("red"), "{r:?}");
        assert!(!r.output_tail.contains('\x1b'), "{r:?}");
    }

    #[test]
    fn hung_gate_killed_by_timeout() {
        let start = Instant::now();
        let r = run_gate(
            "sleep 30",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: Some(200),
                signal: None,
            },
        );
        assert!(start.elapsed().as_millis() < 5000);
        assert!(!r.passed);
        assert!(r.error.unwrap_or_default().contains("timeout or abort"));
    }

    #[test]
    fn gate_ignoring_sigterm_is_sigkilled() {
        let start = Instant::now();
        let r = run_gate(
            "trap '' TERM; sleep 30",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: Some(200),
                signal: None,
            },
        );
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "took {:?}",
            start.elapsed()
        );
        assert!(!r.passed);
    }

    #[test]
    fn aborted_signal_kills_gate() {
        let flag: Abort = Arc::new(AtomicBool::new(false));
        let flag2 = flag.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            flag2.store(true, Ordering::SeqCst);
        });
        let r = run_gate(
            "sleep 30",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: Some(10_000),
                signal: Some(&flag),
            },
        );
        assert!(!r.passed);
        assert!(r.error.unwrap_or_default().contains("timeout or abort"));
    }

    #[test]
    fn killing_the_gate_takes_down_grandchildren_holding_the_pipes() {
        let start = Instant::now();
        let r = run_gate(
            "sleep 30 & sleep 30; wait",
            &std::env::current_dir().unwrap().to_string_lossy(),
            GateOpts {
                timeout_ms: Some(200),
                signal: None,
            },
        );
        assert!(start.elapsed().as_millis() < 5000);
        assert!(!r.passed);
    }
}
