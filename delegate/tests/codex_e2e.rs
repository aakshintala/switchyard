//! Drives the real `delegate` binary as a process against a fake `codex`
//! that replays a synthetic 4-event `codex exec --json` stream.

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const FIXTURE: &str = concat!(
    "{\"type\":\"thread.started\",\"thread_id\":\"THREAD_ID\"}\n",
    "{\"type\":\"turn.started\"}\n",
    "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"pong\\nSTATUS: DONE\"}}\n",
    "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":21804,\"cached_input_tokens\":13184,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":128}}\n",
);

const FAKE_CODEX: &str = r#"#!/bin/sh
# Replays a synthetic `codex exec --json` stream. Every invocation appends its
# argv and captures its stdin bytes exactly, so run + resume assertions can
# read both.
dir="$(dirname "$0")"
{
  printf '%s\n' "$@"
  printf '%s\n' '---'
} >> "$dir/argv.txt"
n=$(cat "$dir/count" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s' "$n" > "$dir/count"
# Pipe-capacity filler before reading stdin: the parent must drain stdout and
# stderr while its writer thread feeds stdin, or this deadlocks.
if [ -n "$DELEGATE_TEST_CODEX_BIG" ]; then
  i=0
  while [ "$i" -lt 3000 ]; do printf 'filler line %s abcdefghijklmnopqrstuvwxyz0123456789\n' "$i"; i=$((i + 1)); done
  i=0
  while [ "$i" -lt 1000 ]; do printf 'err filler %s abcdefghijklmnopqrstuvwxyz\n' "$i" >&2; i=$((i + 1)); done
fi
cat > "$dir/stdin-$n.bin"
# The resume thread is the requested one; a fresh run mints thread-fresh-1.
tid="thread-fresh-1"
prev=""
for a in "$@"; do
  if [ "$prev" = "resume" ]; then tid="$a"; fi
  prev="$a"
done
sed "s/THREAD_ID/$tid/g" "${DELEGATE_TEST_CODEX_STREAM:-$DELEGATE_TEST_CODEX_FIXTURE}"
# A per-invocation stderr marker proves stderr still flows to the terminal
# while stdout carries the JSONL.
printf 'codex-stderr-marker\n' >&2
exit "${DELEGATE_TEST_CODEX_EXIT:-0}"
"#;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("cdm-codex-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let agent = dir.join("codex.sh");
        std::fs::write(&agent, FAKE_CODEX).unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(dir.join("fixture.jsonl"), FIXTURE).unwrap();
        Env { dir }
    }

    /// Write an alternate replay stream consumed via
    /// `DELEGATE_TEST_CODEX_STREAM` + `DELEGATE_TEST_CODEX_EXIT`.
    fn write_stream(&self, name: &str, contents: &str) -> PathBuf {
        let path = self.dir.join(name);
        std::fs::write(&path, contents).unwrap();
        path
    }

    /// The cwd the supervisor resolves: the physical temp path.
    fn cwd(&self) -> String {
        std::fs::canonicalize(&self.dir)
            .unwrap()
            .to_string_lossy()
            .into_owned()
    }

    /// Every recorded argv line across all invocations.
    fn argv(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.join("argv.txt"))
            .unwrap()
            .lines()
            .map(String::from)
            .collect()
    }

    /// Split the argv log into one invocation per leading `exec` line (the
    /// prompt spans several lines, so `---` cannot delimit).
    fn invocations(&self) -> Vec<Vec<String>> {
        let mut calls: Vec<Vec<String>> = Vec::new();
        for line in std::fs::read_to_string(self.dir.join("argv.txt"))
            .unwrap()
            .lines()
        {
            if line == "exec" {
                calls.push(Vec::new());
            }
            if let Some(last) = calls.last_mut() {
                last.push(line.to_string());
            }
        }
        calls
    }

    fn stdin_bytes(&self, n: u32) -> Vec<u8> {
        std::fs::read(self.dir.join(format!("stdin-{n}.bin"))).unwrap()
    }

    fn delegate(&self, args: &[&str], stdin: Option<&[u8]>, big: bool) -> Output {
        self.delegate_with(args, stdin, big, None, "0")
    }

    /// `delegate` with an alternate replay stream and fake exit code for
    /// the fake `codex` child.
    fn delegate_with(
        &self,
        args: &[&str],
        stdin: Option<&[u8]>,
        big: bool,
        stream: Option<&Path>,
        exit: &str,
    ) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("CODEX_BIN", self.dir.join("codex.sh"))
            .env(
                "DELEGATE_TEST_CODEX_FIXTURE",
                self.dir.join("fixture.jsonl"),
            )
            .env("DELEGATE_HEARTBEAT_MS", "100")
            .env("DELEGATE_RETRY_DELAYS_MS", "0")
            .env("DELEGATE_TEST_CODEX_EXIT", exit)
            // Isolate from the developer machine's real host profile.
            .env(
                "DELEGATE_HOST_PROFILE",
                self.dir.join("nonexistent-profile.json"),
            );
        if let Some(stream) = stream {
            cmd.env("DELEGATE_TEST_CODEX_STREAM", stream);
        }
        if big {
            cmd.env("DELEGATE_TEST_CODEX_BIG", "1");
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut si = child.stdin.take().unwrap();
        if let Some(s) = stdin {
            let _ = si.write_all(s);
        }
        drop(si);
        child.wait_with_output().unwrap()
    }

    fn run_write(&self, model: &str, prompt: &[u8]) -> String {
        self.run_write_stream(model, prompt, None, "0")
    }

    /// Run with an alternate replay stream and fake exit code. The JSONL
    /// may contain THREAD_ID, stamped per invocation like the default.
    fn run_write_stream(
        &self,
        model: &str,
        prompt: &[u8],
        stream: Option<&Path>,
        exit: &str,
    ) -> String {
        let out = self.delegate_with(
            &["run", "--model", model],
            Some(prompt),
            false,
            stream,
            exit,
        );
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
        let p: PathBuf = self.dir.join("delegate-jobs").join(format!("{id}.json"));
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn wait_terminal(&self, id: &str) -> Value {
        let out = self.delegate(&["watch", id, "--timeout", "10"], None, false);
        assert_eq!(out.status.code(), Some(0));
        serde_json::from_slice(&out.stdout).unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn until(what: &str, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < Duration::from_secs(10), "timed out: {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn codex_run_finishes_done_with_estimated_cost() {
    let e = Env::new("run");
    let id = e.run_write("codex/gpt-6-luna:medium", b"What is 17 * 23?");
    assert_eq!(id.len(), 36);
    // The session id is minted by the stream: the fake's fresh thread id is
    // what the record carries.
    until("argv", || {
        std::fs::read_to_string(e.dir.join("argv.txt")).is_ok_and(|s| s.lines().any(|l| l == "---"))
    });
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["text"], "pong\nSTATUS: DONE");
    assert_eq!(done["result"]["backend"], "codex");
    assert_eq!(done["result"]["model"], "codex/gpt-6-luna:medium");
    // Cost is estimated from the matching catalogue row, not reported:
    // (8620*0.1 + 5*0.5 + 13184*0.01 + 0*0.125) / 1e6.
    let cost = done["result"]["costUsd"].as_f64().unwrap();
    assert!((cost - 0.00099634).abs() < 1e-12, "{cost}");
    assert_eq!(done["result"]["costEstimated"], true);
    assert_eq!(done["resume"]["sessionId"], "thread-fresh-1");

    // Fresh child argv: exec-parent sandbox/cwd flags first, no prompt bytes.
    let argv = e.argv();
    let cwd = e.cwd();
    assert_eq!(
        argv,
        vec![
            "exec",
            "--json",
            "-s",
            "workspace-write",
            "-C",
            cwd.as_str(),
            "-m",
            "gpt-6-luna",
            "-c",
            "model_reasoning_effort=medium",
            "--",
            "-",
            "---",
        ]
    );
    // The supervisor appends its status block after the prompt; the staged
    // prompt bytes arrive first, exactly.
    let stdin = e.stdin_bytes(1);
    assert!(stdin.starts_with(b"What is 17 * 23?"), "{}", stdin.len());
    assert!(
        stdin.windows(8).any(|w| w == b"STATUS: "),
        "{}",
        stdin.len()
    );
}

#[test]
fn all_five_catalogue_ids_resolve_and_estimate() {
    // (id, expected estimated cost for the shared 8620/13184/5/0 usage)
    let cases = [
        (
            "codex/gpt-6-astra",
            (8620.0 * 10.0 + 5.0 * 50.0 + 13184.0 * 1.0) / 1e6,
        ),
        (
            "codex/gpt-6-luna",
            (8620.0 * 0.1 + 5.0 * 0.5 + 13184.0 * 0.01) / 1e6,
        ),
        (
            "codex/gpt-6-luna:medium",
            (8620.0 * 0.1 + 5.0 * 0.5 + 13184.0 * 0.01) / 1e6,
        ),
        (
            "codex/gpt-6-luna:xhigh",
            (8620.0 * 0.1 + 5.0 * 0.5 + 13184.0 * 0.01) / 1e6,
        ),
        (
            "codex/gpt-6.1-sol",
            (8620.0 * 2.0 + 5.0 * 10.0 + 13184.0 * 0.1) / 1e6,
        ),
    ];
    for (model, want) in cases {
        let e = Env::new(&format!("ids-{}", model.replace(['/', ':'], "-")));
        let id = e.run_write(model, b"hi");
        let done = e.wait_terminal(&id);
        assert_eq!(done["status"], "DONE", "{model}");
        assert_eq!(done["result"]["backend"], "codex", "{model}");
        assert_eq!(done["result"]["model"], model, "{model}");
        let cost = done["result"]["costUsd"].as_f64().unwrap();
        assert!((cost - want).abs() < 1e-12, "{model}: {cost} != {want}");
        assert_eq!(done["result"]["costEstimated"], true, "{model}");
        let argv = e.argv();
        if model.ends_with(":medium") {
            assert!(
                argv.windows(2)
                    .any(|w| w == ["-c", "model_reasoning_effort=medium"]),
                "{model}: {argv:?}"
            );
        } else if model.ends_with(":xhigh") {
            assert!(
                argv.windows(2)
                    .any(|w| w == ["-c", "model_reasoning_effort=xhigh"]),
                "{model}: {argv:?}"
            );
        } else {
            assert!(!argv.iter().any(|a| a == "-c"), "{model}: {argv:?}");
        }
    }
}

#[test]
fn fresh_argv_keeps_a_leading_dash_prompt_on_stdin() {
    let e = Env::new("dash");
    let prompt = "-fix it\nsecond line ünïcode 😀";
    let id = e.run_write("codex/gpt-6.1-sol", prompt.as_bytes());
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE");
    let calls = e.invocations();
    assert_eq!(calls.len(), 1, "{calls:?}");
    // The prompt after `--` is exactly `-`: no prompt byte reaches argv.
    let dash = calls[0].iter().position(|a| a == "--").expect("separator");
    assert_eq!(&calls[0][dash..], ["--", "-", "---"]);
    let stdin = e.stdin_bytes(1);
    assert!(stdin.starts_with(prompt.as_bytes()), "{}", stdin.len());
    // Unsuffixed rows carry no effort override.
    assert!(!calls[0].iter().any(|a| a == "-c"), "{calls:?}");
}

#[test]
fn resume_argv_inserts_cwd_before_resume_and_pipes_the_continuation() {
    let e = Env::new("resume");
    let a = e.run_write("codex/gpt-6-luna", b"first brief");
    let first = e.wait_terminal(&a);
    assert_eq!(first["status"], "DONE");
    assert_eq!(first["resume"]["sessionId"], "thread-fresh-1");

    let out = e.delegate(&["resume", &a], Some(b"follow up"), false);
    assert!(out.status.success());
    let b = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let done = e.wait_terminal(&b);
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["resume"]["sessionId"], "thread-fresh-1");

    let calls = e.invocations();
    assert_eq!(calls.len(), 2, "{calls:?}");
    let cwd = e.cwd();
    assert_eq!(
        calls[1],
        vec![
            "exec",
            "-s",
            "workspace-write",
            "-C",
            cwd.as_str(),
            "resume",
            "thread-fresh-1",
            "--json",
            "-m",
            "gpt-6-luna",
            "--",
            "-",
            "---",
        ]
    );
    // The original brief ran once; the continuation prompt went on stdin.
    let first_stdin = e.stdin_bytes(1);
    assert!(
        first_stdin.starts_with(b"first brief"),
        "{}",
        first_stdin.len()
    );
    let second_stdin = e.stdin_bytes(2);
    assert!(
        second_stdin.starts_with(b"follow up"),
        "{}",
        second_stdin.len()
    );
}

#[test]
fn large_prompt_and_full_pipes_finish_without_deadlock() {
    let e = Env::new("big");
    // A prompt larger than a pipe buffer, with multiline, leading-dash and
    // Unicode content at its edges.
    let mut prompt = String::from("-start ünïcode 😀\n");
    while prompt.len() < 300_000 {
        prompt.push_str("0123456789abcdef\n");
    }
    let out = e.delegate(
        &["run", "--model", "codex/gpt-6-luna"],
        Some(prompt.as_bytes()),
        true,
    );
    assert!(
        out.status.success(),
        "exit {:?}\nstderr: {}\nstdout: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE", "{done}");
    assert_eq!(done["result"]["text"], "pong\nSTATUS: DONE");
    let stdin = e.stdin_bytes(1);
    assert!(stdin.starts_with(prompt.as_bytes()), "{}", stdin.len());
}

#[test]
fn turn_failed_400_is_an_error_with_status_and_stderr() {
    let e = Env::new("failed400");
    let stream = e.write_stream(
        "failed.jsonl",
        concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"THREAD_ID\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"partial\"}}\n",
            "{\"type\":\"turn.failed\",\"error\":{\"message\":\"unexpected status 400 Bad Request: nope\"}}\n",
        ),
    );
    let id = e.run_write_stream("codex/gpt-6-luna", b"brief", Some(&stream), "1");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR", "{done}");
    let result = &done["result"];
    assert!(
        result["text"]
            .as_str()
            .unwrap()
            .contains("unexpected status 400"),
        "{done}"
    );
    assert!(
        result["text"]
            .as_str()
            .unwrap()
            .ends_with("\nSTATUS: ERROR"),
        "{done}"
    );
    assert_eq!(result["providerStatus"], Value::Null);
    // A non-transient status is not retried, so no retries entry carries
    // it; the parser-level provider_status is pinned by unit tests.
    assert!(result.get("retries").is_none(), "{done}");
    assert_eq!(result["sessionId"], "thread-fresh-1");
    // The child's stderr is preserved on the record, and the partial
    // assistant text is never presented as the final answer.
    assert!(
        !result["text"].as_str().unwrap().contains("partial"),
        "{done}"
    );
    assert!(
        result["stderrTail"]
            .as_str()
            .unwrap()
            .contains("codex-stderr-marker"),
        "{done}"
    );
}

#[test]
fn error_event_429_is_an_error_without_retry() {
    let e = Env::new("failed429");
    let stream = e.write_stream(
        "error.jsonl",
        "{\"type\":\"thread.started\",\"thread_id\":\"THREAD_ID\"}\n\
         {\"type\":\"error\",\"message\":\"exceeded retry limit, last status: 429 Too Many Requests\"}\n",
    );
    let id = e.run_write_stream("codex/gpt-6-luna", b"brief", Some(&stream), "1");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR", "{done}");
    // 429 is excluded from the supervisor's transient set, so no retry
    // entry carries it.
    assert!(done["result"].get("retries").is_none(), "{done}");
    assert!(
        done["result"]["text"]
            .as_str()
            .unwrap()
            .ends_with("\nSTATUS: ERROR"),
        "{done}"
    );
}

#[test]
fn missing_completion_and_message_are_errors() {
    let e = Env::new("nocompletion");
    // A completed message with no turn.completed, clean exit.
    let stream = e.write_stream(
        "nocompletion.jsonl",
        concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"THREAD_ID\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"hi\"}}\n",
        ),
    );
    let id = e.run_write_stream("codex/gpt-6-luna", b"brief", Some(&stream), "0");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR", "{done}");
    assert!(
        done["result"]["text"]
            .as_str()
            .unwrap()
            .starts_with("no result line"),
        "{done}"
    );
    // A completed turn with no agent message.
    let stream = e.write_stream(
        "nomessage.jsonl",
        "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1}}\n",
    );
    let id = e.run_write_stream("codex/gpt-6-luna", b"brief", Some(&stream), "0");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR", "{done}");
}

#[test]
fn nonzero_exit_despite_a_message_is_an_error() {
    let e = Env::new("unclean");
    let id = e.run_write_stream("codex/gpt-6-luna", b"brief", None, "7");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR", "{done}");
    let text = done["result"]["text"].as_str().unwrap();
    assert!(!text.contains("pong"), "{done}");
    assert!(text.ends_with("\nSTATUS: ERROR"), "{done}");
}

#[test]
fn resume_fallback_keeps_the_launched_thread_on_immediate_death() {
    let e = Env::new("resumefallback");
    let first = e.run_write("codex/gpt-6-luna", b"first brief");
    let sid = e.wait_terminal(&first)["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(sid, "thread-fresh-1");
    // The resumed child dies before its first event: the launched thread
    // id is still the record's session.
    let stream = e.write_stream("empty.jsonl", "");
    let out = e.delegate_with(
        &["resume", &first],
        Some(b"follow up"),
        false,
        Some(&stream),
        "1",
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let id = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "ERROR", "{done}");
    assert_eq!(done["resume"]["sessionId"], sid);
    assert!(
        done["result"]["text"]
            .as_str()
            .unwrap()
            .ends_with("\nSTATUS: ERROR"),
        "{done}"
    );
}

#[test]
fn negative_usage_never_estimates_a_negative_cost() {
    let e = Env::new("negativeusage");
    let stream = e.write_stream(
        "negative.jsonl",
        concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"THREAD_ID\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"hi\\nSTATUS: DONE\"}}\n",
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":-4,\"output_tokens\":3}}\n",
        ),
    );
    let id = e.run_write_stream("codex/gpt-6-luna", b"brief", Some(&stream), "0");
    let done = e.wait_terminal(&id);
    assert_eq!(done["status"], "DONE", "{done}");
    assert!(done["result"]["usage"].is_null(), "{done}");
    assert!(done["result"]["costUsd"].is_null(), "{done}");
    assert_eq!(done["result"]["costEstimated"], true);
}
