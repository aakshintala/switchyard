//! End-to-end regression for Claude-style background Bash sessions.

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const FAKE_CLAUDE: &str = r#"#!/bin/sh
dir=$(dirname "$0")
cat > "$dir/prompt"
prompt=$(cat "$dir/prompt")
case "$prompt" in
  *BACKGROUND_SESSION*)
    # The backend's direct child is a new-session Bash, with a live child of its own.
    perl -MPOSIX -e 'POSIX::setsid() or die; exec @ARGV' /bin/bash -c 'sleep 30 & child=$!; read -r _ < "$1"; kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; : > "$2"' background "$dir/background.fifo" "$dir/background-exited" </dev/null >/dev/null 2>&1 &
    bg=$!
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s-background"}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"turn ended","session_id":"s-background"}'
    echo "$bg" > "$dir/background.pid"
    echo "$$" > "$dir/agent.pid"
    wait "$bg"
    while :; do :; done
    ;;
esac
"#;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("delegate-claude-idle-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let claude = dir.join("claude.sh");
        std::fs::write(&claude, FAKE_CLAUDE).unwrap();
        std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
        Self { dir }
    }

    fn delegate(&self, args: &[&str], stdin: Option<&str>) -> Output {
        let mut child = Command::new(env!("CARGO_BIN_EXE_delegate"))
            .args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("XDG_CACHE_HOME", self.dir.join("xdg-cache"))
            .env("CLAUDE_BIN", self.dir.join("claude.sh"))
            .env("DELEGATE_HEARTBEAT_MS", "100")
            .env_remove("CLAUDECODE")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut si = child.stdin.take().unwrap();
        if let Some(input) = stdin {
            let _ = si.write_all(input.as_bytes());
        }
        drop(si);
        child.wait_with_output().unwrap()
    }

    fn ok(&self, args: &[&str], prompt: &str) -> String {
        let out = self.delegate(args, Some(prompt));
        assert!(
            out.status.success(),
            "exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    fn record(&self, id: &str) -> Value {
        let path = self
            .dir
            .join("xdg-cache/delegate/jobs")
            .join(format!("{id}.json"));
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        if let Ok(pid) = std::fs::read_to_string(self.dir.join("agent.pid"))
            .map(|s| s.trim().parse::<i32>().unwrap_or(0))
            && pid > 0
        {
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct FifoRelease(PathBuf);

impl FifoRelease {
    fn release(&self) {
        if let Ok(mut fifo) = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&self.0)
        {
            let _ = fifo.write_all(b"\n");
        }
    }
}

impl Drop for FifoRelease {
    fn drop(&mut self) {
        self.release();
    }
}

fn until(what: &str, mut condition: impl FnMut() -> bool) {
    let start = Instant::now();
    while !condition() {
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "timed out: {what}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn alive(pid: i64) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

#[test]
fn live_new_session_background_command_holds_claude_job_until_exit() {
    let env = Env::new();
    let fifo = env.dir.join("background.fifo");
    let fifo_name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
    let release = FifoRelease(fifo);

    let idle_ms: u64 = 400;
    let id = env.ok(
        &[
            "run",
            "--model",
            "claude-sonnet-5-5",
            "--idle-ms",
            &idle_ms.to_string(),
        ],
        "BACKGROUND_SESSION",
    );
    let pid_file = env.dir.join("background.pid");
    let mut background_pid = 0_i64;
    until("Claude-style background process starts", || {
        background_pid = std::fs::read_to_string(&pid_file)
            .ok()
            .and_then(|s| s.trim().parse::<i64>().ok())
            .unwrap_or(0);
        if background_pid > 0 {
            true
        } else {
            let record = env.record(&id);
            assert_eq!(
                record["status"], "RUNNING",
                "job ended before detached child started: {record}"
            );
            false
        }
    });
    let backend_pid: i64 = std::fs::read_to_string(env.dir.join("agent.pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();

    // The Claude backend leads its process group. Its direct Bash child has a
    // different PGID and, because it called setsid(), starts a separate session.
    let mut ps_text = String::new();
    until(
        "Claude-style backend and background process appear in ps",
        || {
            let ps = Command::new("ps")
                .args([
                    "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "stat=",
                ])
                .output()
                .expect("run ps");
            assert!(ps.status.success());
            ps_text = String::from_utf8_lossy(&ps.stdout).into_owned();
            [backend_pid, background_pid].into_iter().all(|wanted| {
                ps_text.lines().any(|line| {
                    line.split_whitespace()
                        .next()
                        .and_then(|pid| pid.parse::<i64>().ok())
                        == Some(wanted)
                })
            })
        },
    );
    let row_for = |pid: i64| {
        ps_text
            .lines()
            .find(|line| {
                line.split_whitespace()
                    .next()
                    .and_then(|pid| pid.parse::<i64>().ok())
                    == Some(pid)
            })
            .unwrap_or_else(|| panic!("process {pid} missing from ps"))
    };
    let backend_row = row_for(backend_pid);
    assert_eq!(
        backend_row
            .split_whitespace()
            .nth(2)
            .unwrap()
            .parse::<i64>()
            .unwrap(),
        backend_pid,
        "backend must lead its isolated group: {backend_row}"
    );
    let command_row = row_for(background_pid);
    let fields = command_row.split_whitespace().collect::<Vec<_>>();
    assert_eq!(
        fields[1].parse::<i64>().unwrap(),
        backend_pid,
        "Bash command must be a direct backend child: {command_row}"
    );
    assert_eq!(
        fields[2].parse::<i64>().unwrap(),
        background_pid,
        "Bash command must lead its process group after setsid: {command_row}"
    );

    let still_live_since = Instant::now();
    until(
        "job stays running for an idle window with a detached child",
        || {
            assert!(alive(background_pid), "detached Bash exited too early");
            let record = env.record(&id);
            assert_eq!(
                record["status"], "RUNNING",
                "job ended while its detached child was alive: {record}"
            );
            still_live_since.elapsed() >= Duration::from_millis(idle_ms)
        },
    );

    release.release();
    until("detached Bash exits", || {
        env.dir.join("background-exited").is_file()
    });

    let mut done = None;
    until(
        "idle watchdog kills after the detached command exits",
        || {
            done = Some(env.record(&id));
            done.as_ref()
                .is_some_and(|record| record["status"] != "RUNNING")
        },
    );
    let done = done.unwrap();
    assert_eq!(done["status"], "STALLED");
    let message = done["result"]["text"].as_str().unwrap();
    assert!(
        message.contains("Idle watchdog killed this job"),
        "{message}"
    );
}
