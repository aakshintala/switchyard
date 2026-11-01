//! Opt-in real-Fiber resume tests: `delegate resume` continues a supervised
//! hub session after a NEEDS_CONTEXT answer and after a failed gate.
//!
//! These tests need a real `fiber` binary, a reachable hub, and a live Muse
//! model. They skip with a printed reason when the binary or hub is missing.
//! Each test spends two live turns. Run with:
//! `FIBER_BIN=<path to fiber> cargo test --test fiber_live -- --nocapture`.

use std::cell::RefCell;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde_json::Value;

const MODEL: &str = "fiber/opencode-go/muse-spark-1.3-contributor";
const SKIP_BINARY: &str = "skipping: FIBER_BIN is unset (set it to a real fiber binary to run)";

/// The real fiber binary, or `None` when the tests must skip. `FIBER_BIN` set
/// but empty is a test failure, never a fallback to a `fiber` on PATH.
fn real_fiber() -> Option<PathBuf> {
    match std::env::var_os("FIBER_BIN") {
        None => None,
        Some(v) if v.is_empty() => {
            panic!("FIBER_BIN is set but empty: set it to a real fiber binary to run")
        }
        Some(v) => Some(PathBuf::from(v)),
    }
}

fn live_fiber() -> Option<PathBuf> {
    let Some(real) = real_fiber() else {
        eprintln!("{SKIP_BINARY}");
        return None;
    };
    let socket = delegate::backends::fiber::hub::fiber_home()
        .and_then(|home| delegate::backends::fiber::hub::hub_socket_path(&home));
    let socket = match socket {
        Ok(socket) => socket,
        Err(error) => {
            eprintln!("skipping: {error}");
            return None;
        }
    };
    if let Err(error) = UnixStream::connect(&socket) {
        eprintln!(
            "skipping: hub socket {} is not reachable: {error}",
            socket.display()
        );
        return None;
    }
    Some(real)
}

struct LiveEnv {
    root: PathBuf,
    work: PathBuf,
    fiber_bin: PathBuf,
    jobs: RefCell<Vec<String>>,
}

impl LiveEnv {
    fn new(name: &str, real: &std::path::Path) -> Self {
        let root =
            std::env::temp_dir().join(format!("delegate-fiber-live-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let work = root.join("work");
        std::fs::create_dir_all(&work).unwrap();
        LiveEnv {
            root,
            work,
            fiber_bin: real.to_path_buf(),
            jobs: RefCell::new(Vec::new()),
        }
    }

    fn delegate(&self, args: &[&str], stdin: Option<&str>) -> std::process::Output {
        let mut child = Command::new(env!("CARGO_BIN_EXE_delegate"))
            .args(args)
            .current_dir(&self.work)
            .env("TMPDIR", &self.root)
            .env("XDG_CACHE_HOME", self.root.join("xdg-cache"))
            .env_remove("CLAUDECODE")
            .env("FIBER_BIN", &self.fiber_bin)
            .env(
                "DELEGATE_HOST_PROFILE",
                self.root.join("nonexistent-profile.json"),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        if let Some(prompt) = stdin {
            child
                .stdin
                .take()
                .unwrap()
                .write_all(prompt.as_bytes())
                .unwrap();
        }
        child.wait_with_output().unwrap()
    }

    fn run_ok(&self, extra: &[&str], prompt: &str) -> String {
        let mut args: Vec<&str> = vec!["run", "--model", MODEL];
        args.extend(extra);
        let out = self.delegate(&args, Some(prompt));
        assert!(
            out.status.success(),
            "delegate run failed: exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
        self.jobs.borrow_mut().push(id.clone());
        id
    }

    fn resume_ok(&self, id: &str, prompt: &str) -> String {
        let out = self.delegate(&["resume", id], Some(prompt));
        assert!(
            out.status.success(),
            "delegate resume failed: exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        let new = String::from_utf8(out.stdout).unwrap().trim().to_string();
        self.jobs.borrow_mut().push(new.clone());
        new
    }

    fn watch(&self, id: &str) -> Value {
        let out = self.delegate(&["watch", id, "--timeout", "300"], None);
        assert!(
            out.status.success(),
            "delegate watch failed: exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }

    fn try_record(&self, id: &str) -> Option<Value> {
        let raw =
            std::fs::read_to_string(self.root.join("delegate-jobs").join(format!("{id}.json")))
                .ok()?;
        serde_json::from_str(&raw).ok()
    }

    /// Prints every launched job record to stderr when the test fails.
    fn dump_guard(&self) -> Dump<'_> {
        Dump { env: self }
    }
}

struct Dump<'a> {
    env: &'a LiveEnv,
}

impl Drop for Dump<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            for id in self.env.jobs.borrow().iter() {
                match self.env.try_record(id) {
                    Some(rec) => eprintln!("job {id}: {rec:#}"),
                    None => eprintln!("job {id}: no record"),
                }
            }
        }
    }
}

impl Drop for LiveEnv {
    fn drop(&mut self) {
        for id in self.jobs.borrow().iter() {
            let terminal = self
                .try_record(id)
                .and_then(|r| r.get("status").and_then(|s| s.as_str()).map(str::to_string))
                .is_some_and(|s| s != "RUNNING");
            if !terminal {
                let _ = Command::new(env!("CARGO_BIN_EXE_delegate"))
                    .args(["cancel", id])
                    .current_dir(&self.work)
                    .env("TMPDIR", &self.root)
                    .env("XDG_CACHE_HOME", self.root.join("xdg-cache"))
                    .env("FIBER_BIN", &self.fiber_bin)
                    .output();
            }
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn live_fiber_needs_context_resume() {
    let Some(real) = live_fiber() else {
        return;
    };
    let env = LiveEnv::new("needs-context", &real);
    let _dump = env.dump_guard();
    let id = env.run_ok(
        &[],
        "Remember the number 4721. Do not call any tools. You need a codeword from the \
         orchestrator to proceed: end your reply with a question asking for it, and a final \
         line containing exactly STATUS: NEEDS_CONTEXT",
    );
    let first = env.watch(&id);
    assert_eq!(first["status"], "NEEDS_CONTEXT", "{first:#}");
    let sid = first["resume"]["sessionId"].as_str().unwrap().to_string();
    assert!(!sid.is_empty(), "{first:#}");

    let b = env.resume_ok(
        &id,
        "The codeword is plum. Do not call any tools. Reply with the codeword and the number \
         from my first message, and end with a final line containing exactly STATUS: DONE",
    );
    let done = env.watch(&b);
    assert_eq!(done["status"], "DONE", "{done:#}");
    let text = done["result"]["text"].as_str().unwrap_or("");
    assert!(
        text.contains("plum") && text.contains("4721"),
        "resumed turn must use the first prompt's fact: {text}"
    );
    assert_eq!(done["resume"]["sessionId"], sid.as_str(), "{done:#}");
}

#[test]
fn live_fiber_gate_failure_repair() {
    let Some(real) = live_fiber() else {
        return;
    };
    let env = LiveEnv::new("gate-repair", &real);
    let _dump = env.dump_guard();
    let gate = "test -f zebra-17.txt";
    let id = env.run_ok(
        &["--gate", gate],
        "The repair filename is zebra-17.txt. Do not call any tools and do not create any \
         file now. Reply with OK and end with a final line containing exactly STATUS: DONE",
    );
    let first = env.watch(&id);
    assert_eq!(first["status"], "DONE_WITH_CONCERNS", "{first:#}");
    assert_eq!(first["result"]["gateResult"]["passed"], false, "{first:#}");
    let sid = first["resume"]["sessionId"].as_str().unwrap().to_string();
    assert!(!sid.is_empty(), "{first:#}");

    // No `--gate` flag: resume inherits the stored gate and reruns it.
    let b = env.resume_ok(
        &id,
        "The gate failed. Create the file whose name I gave in my first message, containing \
         ok and nothing else. Do not write the filename in your reply. You may use the file \
         tools only to create that one file. End with a final line containing exactly \
         STATUS: DONE",
    );
    let done = env.watch(&b);
    assert_eq!(done["status"], "DONE", "{done:#}");
    assert_eq!(done["result"]["gateResult"]["passed"], true, "{done:#}");
    assert_eq!(done["resume"]["sessionId"], sid.as_str(), "{done:#}");
    let body = std::fs::read_to_string(env.work.join("zebra-17.txt")).unwrap_or_default();
    assert_eq!(body, "ok", "repair must create the remembered file");
}
