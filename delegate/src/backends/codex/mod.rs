//! The codex backend: binary, argv, spawn, and stream-json parsing.
//!
//! `codex exec --json` prints one JSON object per line. `thread.started`
//! carries the thread id, the last completed `agent_message` item holds the
//! final turn text, and `turn.completed` carries the usage. A non-zero exit,
//! a failed turn or a missing terminal message is an error: the diagnostic
//! text ends in `STATUS: ERROR` because the shared status derivation honors
//! a trailing STATUS line ahead of `is_error`/exit.

pub(crate) mod doctor;

use super::types::{BackendResult, Event, ProgressSnapshotRaw, Spawned};
use crate::types::{JobSpec, Usage};
use std::process::Stdio;
use std::sync::atomic::Ordering;

const NO_RESULT: &str = "no result line";

const EFFORT_LEVELS: [&str; 2] = ["medium", "xhigh"];

pub(crate) fn resolve_bin(r#override: Option<&str>) -> String {
    if let Some(o) = r#override.filter(|s| !s.is_empty()) {
        return o.to_string();
    }
    if let Ok(env) = std::env::var("CODEX_BIN")
        && !env.is_empty()
    {
        return env;
    }
    if let Ok(out) = std::process::Command::new("which").arg("codex").output()
        && out.status.success()
    {
        let found = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !found.is_empty() {
            return found;
        }
    }
    crate::util::homedir()
        .join(".local/bin/codex")
        .to_string_lossy()
        .into_owned()
}

/// Split a delegate `codex/...` id into the CLI model and an optional
/// reasoning effort. Only one leading `codex/` is stripped and only a
/// trailing `:medium`/`:xhigh` becomes an effort override; any other colon
/// belongs to the model itself and is passed through whole.
fn base_and_effort(model: &str) -> (&str, Option<&str>) {
    let base = model.strip_prefix("codex/").unwrap_or(model);
    match base.rsplit_once(':') {
        Some((b, level)) if EFFORT_LEVELS.contains(&level) => (b, Some(level)),
        _ => (base, None),
    }
}

/// Staging argv for a run. The prompt rides after the `--` separator, exactly
/// where the other backends carry it; only codex spawn lowers this staging
/// form into the real child wire argv (inserting `-C <cwd>` from the spec and
/// replacing the trailing prompt with `-`) and pipes the staged prompt to the
/// child's stdin. The staging form is never executed directly.
pub(crate) fn argv(model: &str, session: Option<&str>, prompt: &str) -> Vec<String> {
    let (base, effort) = base_and_effort(model);
    let mut args = vec!["exec".into()];
    let push_effort = |args: &mut Vec<String>| {
        if let Some(level) = effort {
            args.push("-c".into());
            args.push(format!("model_reasoning_effort={level}"));
        }
    };
    match session {
        // `exec` parent flags (sandbox) precede `resume`; resume's own flags
        // follow the thread id.
        Some(thread) => {
            args.push("-s".into());
            args.push("workspace-write".into());
            args.push("resume".into());
            args.push(thread.to_string());
            args.push("--json".into());
            args.push("-m".into());
            args.push(base.to_string());
            push_effort(&mut args);
        }
        None => {
            args.push("--json".into());
            args.push("-s".into());
            args.push("workspace-write".into());
            args.push("-m".into());
            args.push(base.to_string());
            push_effort(&mut args);
        }
    }
    args.push("--".into());
    args.push(prompt.to_string());
    args
}

/// The resume thread id in a staging argv built by [`argv`].
fn session_from_staging_argv(argv: &[String]) -> Option<String> {
    argv.windows(2)
        .find(|w| w[0] == "resume")
        .map(|w| w[1].clone())
}

/// Lower a staging argv plus the spec cwd into the real child argv and the
/// stdin prompt bytes, without losing bytes. Inserts `-C <cwd>` after the
/// `-s workspace-write` pair and replaces the trailing staged prompt with
/// `-`, so no prompt byte ever reaches the child's argv.
fn lower_to_wire(staging: &[String], cwd: &str) -> (Vec<String>, String) {
    let sep = staging.iter().rposition(|s| s == "--");
    let prompt = match sep {
        Some(i) if i + 1 < staging.len() => staging[i + 1..].join("\n"),
        _ => String::new(),
    };
    let mut child: Vec<String> = match sep {
        Some(i) => staging[..=i].to_vec(),
        None => staging.to_vec(),
    };
    if sep.is_none() {
        child.push("--".into());
    }
    child.push("-".into());
    if let Some(i) = child
        .windows(2)
        .position(|w| w[0] == "-s" && w[1] == "workspace-write")
    {
        child.splice(i + 2..i + 2, ["-C".into(), cwd.to_string()]);
    } else {
        child.splice(1..1, ["-C".into(), cwd.to_string()]);
    }
    (child, prompt)
}

pub(crate) fn spawn(spec: &JobSpec) -> Spawned {
    // The stream usually repeats this id in its `thread.started` header; when
    // it doesn't (a crash before the first line), the result still carries it.
    let launched_session = session_from_staging_argv(&spec.argv);
    let (wire_argv, prompt) = lower_to_wire(&spec.argv, &spec.cwd);
    let mut wired = spec.clone();
    wired.argv = wire_argv;
    let started = match super::start_child_with_stdin(&wired, Stdio::piped()) {
        Ok(s) => s,
        Err(msg) => return super::spawn_failed(&msg),
    };
    let pid = started.pid;
    let reaped = started.reaped;
    let reaped_k = std::sync::Arc::clone(&reaped);
    let stdout = started.stdout;
    let stderr = started.stderr;
    let mut child = started.child;
    Spawned {
        kill: super::killer(pid, reaped_k),
        session_id: launched_session.clone(),
        drive: Box::new(move |on| {
            // The writer runs on its own thread while pump drains the pipes,
            // so a child that fills stdout before reading stdin cannot
            // deadlock a large prompt. It is always joined before returning.
            let mut stdin = child.stdin.take();
            let writer = std::thread::spawn(move || -> Option<String> {
                let Some(mut sin) = stdin.take() else {
                    return None;
                };
                use std::io::Write;
                match sin.write_all(prompt.as_bytes()) {
                    Ok(()) => None,
                    Err(e) => Some(format!("codex stdin write failed: {e}")),
                }
                // `sin` drops here, so the child sees EOF.
            });
            let mut state = CodexState::default();
            let pumped = super::pump(
                stdout,
                stderr,
                on,
                move || {
                    let clean = child.wait().map(|s| s.success()).unwrap_or(false);
                    reaped.store(true, Ordering::SeqCst);
                    clean
                },
                |line| {
                    if handle_line(line, &mut state) {
                        on(Event::Progress(ProgressSnapshotRaw {
                            last_tool: state.last_tool.clone(),
                            tokens_so_far: 0.0,
                            last_assistant: state.last_assistant.clone(),
                            files_touched: state.files_touched.clone(),
                            phase: state.phase.clone(),
                            session_id: state
                                .session_id
                                .clone()
                                .or_else(|| launched_session.clone()),
                        }));
                    }
                },
            );
            let stdin_err = writer
                .join()
                .unwrap_or_else(|_| Some("codex stdin writer panicked".to_string()));
            finish(
                state,
                pumped.clean_exit,
                &pumped.stderr,
                launched_session.as_deref(),
                stdin_err,
            )
        }),
    }
}

/// Pure parse of a finished `codex exec --json` stdout. The spawn driver uses
/// [`finish`] too.
pub fn parse_stdout(stdout: &str, clean_exit: bool, stderr: &str) -> BackendResult {
    let mut state = CodexState::default();
    for line in stdout.split_inclusive('\n') {
        handle_line(line.as_bytes(), &mut state);
    }
    finish(state, clean_exit, stderr, None, None)
}

#[derive(Debug, Default)]
struct CodexState {
    session_id: Option<String>,
    final_text: Option<String>,
    saw_turn_completed: bool,
    input_tokens: Option<f64>,
    cached_input_tokens: Option<f64>,
    output_tokens: Option<f64>,
    cache_write_tokens: Option<f64>,
    last_tool: Option<String>,
    last_assistant: Option<String>,
    files_touched: Vec<String>,
    phase: Option<String>,
}

/// A finite f64 field, or None when it is missing, malformed or negative.
fn num(obj: Option<&serde_json::Value>, key: &str) -> Option<f64> {
    obj.and_then(|u| u.get(key))
        .and_then(|n| n.as_f64())
        .filter(|n| n.is_finite() && *n >= 0.0)
}

/// Fold one stdout line into the state. Unparseable and unknown lines are
/// ignored. Returns whether a progress event should fire.
fn handle_line(line: &[u8], state: &mut CodexState) -> bool {
    let trimmed = String::from_utf8_lossy(line).trim().to_string();
    if trimmed.is_empty() {
        return false;
    }
    let ev: serde_json::Value = match serde_json::from_str(&trimmed) {
        Ok(v) => v,
        Err(_) => return false,
    };
    match ev.get("type").and_then(|t| t.as_str()) {
        Some("thread.started") => {
            if let Some(id) = ev.get("thread_id").and_then(|i| i.as_str()) {
                let changed = state.session_id.as_deref() != Some(id);
                state.session_id = Some(id.to_string());
                changed
            } else {
                false
            }
        }
        Some("item.completed") => {
            let item = ev.get("item");
            let kind = item.and_then(|i| i.get("type")).and_then(|t| t.as_str());
            if kind != Some("agent_message") {
                return false;
            }
            match item.and_then(|i| i.get("text")).and_then(|t| t.as_str()) {
                Some(text) => {
                    state.final_text = Some(text.to_string());
                    let truncated: String = text.chars().take(200).collect();
                    state.last_assistant = Some(truncated);
                    state.phase = Some("responding".into());
                    true
                }
                None => false,
            }
        }
        Some("turn.completed") => {
            if let Some(usage) = ev.get("usage") {
                state.input_tokens = num(Some(usage), "input_tokens");
                state.cached_input_tokens = num(Some(usage), "cached_input_tokens");
                state.output_tokens = num(Some(usage), "output_tokens");
                state.cache_write_tokens = num(Some(usage), "cache_write_input_tokens");
            }
            state.saw_turn_completed = true;
            true
        }
        _ => false,
    }
}

/// Normalized usage for a completed turn: input minus cached input,
/// cache-read as cached input, output without reasoning double-counting,
/// cache-write defaulting to zero. None unless every required field parsed.
fn normalized_usage(state: &CodexState) -> Option<Usage> {
    let (input, cached, output) = (
        state.input_tokens?,
        state.cached_input_tokens?,
        state.output_tokens?,
    );
    Some(Usage {
        input_tokens: input - cached,
        output_tokens: output,
        cache_read_tokens: cached,
        cache_write_tokens: state.cache_write_tokens.unwrap_or(0.0),
    })
}

/// Turn the terminal `turn.completed` (or the lack of one) into the normalized
/// result. Success needs a completed turn, a completed agent message and a
/// clean exit; anything else is an error whose diagnostic text ends in
/// `STATUS: ERROR`, because the shared status derivation honors a trailing
/// STATUS line ahead of `is_error`/exit and must never read an early
/// `STATUS: DONE` from a crashed stream as success. CANCELLED is the
/// supervisor's status, never ours. `launched_session` is the resume thread
/// id the run was launched with, used when the stream never sent a header.
fn finish(
    state: CodexState,
    clean_exit: bool,
    stderr: &str,
    launched_session: Option<&str>,
    stdin_err: Option<String>,
) -> BackendResult {
    let session_id = state
        .session_id
        .clone()
        .or_else(|| launched_session.map(str::to_string));
    if let Some(err) = stdin_err {
        return BackendResult {
            text: format!("{err}\nSTATUS: ERROR"),
            session_id,
            is_error: Some(true),
            clean_exit,
            stderr: stderr.to_string(),
            ..Default::default()
        };
    }
    match (&state.final_text, state.saw_turn_completed, clean_exit) {
        (Some(text), true, true) => BackendResult {
            text: text.clone(),
            session_id,
            usage: normalized_usage(&state),
            cost_usd: None,
            is_error: Some(false),
            duration_ms: None,
            clean_exit,
            stderr: stderr.to_string(),
            permission_denials: Vec::new(),
            provider_status: None,
        },
        _ => BackendResult {
            text: format!("{NO_RESULT}\nSTATUS: ERROR"),
            session_id,
            is_error: Some(true),
            clean_exit,
            stderr: stderr.to_string(),
            ..Default::default()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const THREAD: &str = "01a15538-example";

    fn four_event_stream() -> String {
        concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"THREAD\"}\n",
            "{\"type\":\"turn.started\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"pong\\nSTATUS: DONE\"}}\n",
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":21804,\"cached_input_tokens\":13184,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":128}}\n",
        )
        .replace("THREAD", THREAD)
    }

    #[test]
    fn successful_stream_normalizes_usage_without_reasoning_double_counting() {
        let res = parse_stdout(&four_event_stream(), true, "");
        assert_eq!(res.text, "pong\nSTATUS: DONE");
        assert_eq!(res.session_id.as_deref(), Some(THREAD));
        assert_eq!(res.is_error, Some(false));
        assert!(res.clean_exit);
        assert_eq!(res.cost_usd, None);
        // 21804 total input minus 13184 cached; output 5 excludes reasoning.
        let usage = res.usage.as_ref().expect("usage");
        assert_eq!(usage.input_tokens, 8620.0);
        assert_eq!(usage.cache_read_tokens, 13184.0);
        assert_eq!(usage.output_tokens, 5.0);
        assert_eq!(usage.cache_write_tokens, 0.0);
    }

    #[test]
    fn fresh_staging_argv_has_no_cwd_and_resume_carries_the_thread() {
        let fresh = argv("codex/gpt-6-luna", None, "hi");
        assert_eq!(
            fresh,
            vec![
                "exec",
                "--json",
                "-s",
                "workspace-write",
                "-m",
                "gpt-6-luna",
                "--",
                "hi",
            ]
        );
        let resume = argv("codex/gpt-6-luna", Some(THREAD), "go");
        assert_eq!(
            resume,
            vec![
                "exec",
                "-s",
                "workspace-write",
                "resume",
                THREAD,
                "--json",
                "-m",
                "gpt-6-luna",
                "--",
                "go",
            ]
        );
        assert_eq!(session_from_staging_argv(&fresh), None);
        assert_eq!(session_from_staging_argv(&resume).as_deref(), Some(THREAD));
    }

    #[test]
    fn effort_suffix_becomes_a_config_flag_once() {
        let medium = argv("codex/gpt-6-luna:medium", None, "hi");
        assert!(
            medium
                .windows(2)
                .any(|w| w == ["-c", "model_reasoning_effort=medium"]),
            "{medium:?}"
        );
        assert!(!medium.iter().any(|a| a.contains("codex/")), "{medium:?}");
        let xhigh = argv("codex/gpt-6-luna:xhigh", Some(THREAD), "go");
        assert!(
            xhigh
                .windows(2)
                .any(|w| w == ["-c", "model_reasoning_effort=xhigh"]),
            "{xhigh:?}"
        );
        let plain = argv("codex/gpt-6-luna", None, "hi");
        assert!(!plain.iter().any(|a| a == "-c"), "{plain:?}");
        let sol = argv("codex/gpt-6.1-sol", None, "hi");
        assert!(!sol.iter().any(|a| a == "-c"), "{sol:?}");
    }

    #[test]
    fn prefix_strips_once_and_unknown_colons_survive() {
        let (base, effort) = base_and_effort("codex/codex/gpt-6-luna");
        assert_eq!(base, "codex/gpt-6-luna");
        assert_eq!(effort, None);
        let (base, effort) = base_and_effort("codex/gpt-6-luna:beta");
        assert_eq!(base, "gpt-6-luna:beta");
        assert_eq!(effort, None);
        let (base, effort) = base_and_effort("codex/gpt-6-luna:xhigh");
        assert_eq!(base, "gpt-6-luna");
        assert_eq!(effort, Some("xhigh"));
    }

    #[test]
    fn wire_lowering_inserts_cwd_and_moves_the_prompt_to_stdin() {
        let staging = argv("codex/gpt-6-luna:medium", None, "-fix it\nline 2");
        let (child, prompt) = lower_to_wire(&staging, "/work/tree");
        assert_eq!(
            child,
            vec![
                "exec",
                "--json",
                "-s",
                "workspace-write",
                "-C",
                "/work/tree",
                "-m",
                "gpt-6-luna",
                "-c",
                "model_reasoning_effort=medium",
                "--",
                "-",
            ]
        );
        assert_eq!(prompt, "-fix it\nline 2");
        assert!(!child.iter().any(|a| a.contains("fix it")), "{child:?}");

        let staging = argv("codex/gpt-6-luna:xhigh", Some(THREAD), "go");
        let (child, prompt) = lower_to_wire(&staging, "/work/tree");
        assert_eq!(
            child,
            vec![
                "exec",
                "-s",
                "workspace-write",
                "-C",
                "/work/tree",
                "resume",
                THREAD,
                "--json",
                "-m",
                "gpt-6-luna",
                "-c",
                "model_reasoning_effort=xhigh",
                "--",
                "-",
            ]
        );
        assert_eq!(prompt, "go");
    }

    #[test]
    fn wire_lowering_without_a_separator_appends_one() {
        let (child, prompt) = lower_to_wire(&["exec".into(), "--json".into()], "/w");
        assert_eq!(child.last().unwrap(), "-");
        assert!(child.windows(2).any(|w| w == ["-C", "/w"]));
        assert_eq!(prompt, "");
        // A trailing separator with no staged prompt yields empty stdin.
        let (child, prompt) = lower_to_wire(&["exec".into(), "--".into()], "/w");
        assert_eq!(child.last().unwrap(), "-");
        assert_eq!(prompt, "");
    }

    #[test]
    fn explicit_override_wins() {
        assert_eq!(resolve_bin(Some("/custom/codex")), "/custom/codex");
        // An empty override falls through to the environment, not the fallback.
        let prev = std::env::var("CODEX_BIN").ok();
        unsafe { std::env::set_var("CODEX_BIN", "/env/codex") };
        assert_eq!(resolve_bin(Some("")), "/env/codex");
        match prev {
            Some(v) => unsafe { std::env::set_var("CODEX_BIN", v) },
            None => unsafe { std::env::remove_var("CODEX_BIN") },
        }
    }

    #[test]
    fn env_used_when_no_override() {
        let prev = std::env::var("CODEX_BIN").ok();
        unsafe { std::env::set_var("CODEX_BIN", "/env/codex") };
        assert_eq!(resolve_bin(None), "/env/codex");
        // Empty env falls through to PATH or home fallback, never empty.
        unsafe { std::env::set_var("CODEX_BIN", "") };
        let bin = resolve_bin(None);
        assert!(!bin.is_empty(), "empty CODEX_BIN must fall through");
        assert!(bin.ends_with("bin/codex") || bin.contains("codex"), "{bin}");
        match prev {
            Some(v) => unsafe { std::env::set_var("CODEX_BIN", v) },
            None => unsafe { std::env::remove_var("CODEX_BIN") },
        }
    }

    #[test]
    fn home_fallback_when_which_finds_no_codex() {
        let prev_path = std::env::var_os("PATH");
        let prev_codex = std::env::var("CODEX_BIN").ok();
        let empty = std::env::temp_dir().join(format!("cdm-codex-nobin-{}", std::process::id()));
        std::fs::create_dir_all(&empty).unwrap();
        unsafe { std::env::set_var("PATH", &empty) };
        unsafe { std::env::remove_var("CODEX_BIN") };
        let bin = resolve_bin(None);
        assert!(
            bin.ends_with(".local/bin/codex"),
            "home fallback when PATH has no codex: {bin}"
        );
        match prev_path {
            Some(v) => unsafe { std::env::set_var("PATH", v) },
            None => unsafe { std::env::remove_var("PATH") },
        }
        match prev_codex {
            Some(v) => unsafe { std::env::set_var("CODEX_BIN", v) },
            None => unsafe { std::env::remove_var("CODEX_BIN") },
        }
        let _ = std::fs::remove_dir_all(&empty);
    }

    #[test]
    fn thread_started_without_an_id_and_non_assistant_items_change_nothing() {
        let mut state = CodexState::default();
        // A header without an id sets no session and emits no progress.
        assert!(!handle_line(b"{\"type\":\"thread.started\"}", &mut state));
        assert!(state.session_id.is_none());
        // Reasoning and tool items are never final text.
        assert!(!handle_line(
            b"{\"type\":\"item.completed\",\"item\":{\"id\":\"r\",\"type\":\"reasoning\",\"text\":\"hmm\"}}",
            &mut state
        ));
        assert!(!handle_line(
            b"{\"type\":\"item.completed\",\"item\":{\"id\":\"t\",\"type\":\"tool_call\",\"text\":\"run\"}}",
            &mut state
        ));
        // An agent message without text is not completion either.
        assert!(!handle_line(
            b"{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\"}}",
            &mut state
        ));
        assert!(state.final_text.is_none());
        // A completed turn without usage still succeeds; usage stays absent.
        let mut with_message = CodexState::default();
        assert!(handle_line(
            b"{\"type\":\"thread.started\",\"thread_id\":\"t1\"}",
            &mut with_message
        ));
        assert!(handle_line(
            br#"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"hi"}}"#,
            &mut with_message
        ));
        assert!(handle_line(
            b"{\"type\":\"turn.completed\"}",
            &mut with_message
        ));
        assert!(with_message.saw_turn_completed);
        assert!(with_message.input_tokens.is_none());
        let res = finish(with_message, true, "", None, None);
        assert_eq!(res.is_error, Some(false));
        assert_eq!(res.text, "hi");
        assert!(res.usage.is_none());
        assert_eq!(res.session_id.as_deref(), Some("t1"));
    }

    #[test]
    fn launched_session_survives_a_headerless_stream() {
        let res = finish(
            CodexState::default(),
            false,
            "boom",
            Some("launch-tid"),
            None,
        );
        assert_eq!(res.session_id.as_deref(), Some("launch-tid"));
        assert_eq!(res.is_error, Some(true));
        assert_eq!(res.stderr, "boom");
        assert!(res.text.ends_with("STATUS: ERROR"), "{}", res.text);
    }

    #[test]
    fn stdin_write_failure_is_an_error_that_keeps_the_thread() {
        let mut state = CodexState::default();
        assert!(handle_line(
            b"{\"type\":\"thread.started\",\"thread_id\":\"t9\"}",
            &mut state
        ));
        let res = finish(
            state,
            true,
            "",
            None,
            Some("codex stdin write failed: broken pipe".into()),
        );
        assert_eq!(res.is_error, Some(true));
        assert!(res.text.contains("broken pipe"), "{}", res.text);
        assert!(res.text.ends_with("STATUS: ERROR"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("t9"));
    }

    #[test]
    fn unknown_and_malformed_lines_are_ignored() {
        let mut state = CodexState::default();
        assert!(!handle_line(
            b"{\"type\":\"future.unknown\",\"x\":1}",
            &mut state
        ));
        assert!(!handle_line(b"not json", &mut state));
        assert!(!handle_line(b"", &mut state));
        assert!(!handle_line(b"{\"no-type\":true}", &mut state));
        let res = finish(state, true, "", None, None);
        assert_eq!(res.is_error, Some(true));
    }

    #[test]
    fn spawn_failure_is_an_error_result() {
        let spec = crate::job::tests::spec_of(|s| {
            s.bin = "/nonexistent/codex".into();
            s.argv = argv("codex/gpt-6-luna", None, "hi");
        });
        let spawned = spawn(&spec);
        (spawned.kill)();
        let res = (spawned.drive)(&|_| {});
        assert!(!res.clean_exit);
        assert_eq!(res.is_error, Some(true));
        assert!(!res.text.is_empty());
    }

    #[test]
    fn real_child_runs_and_sigterm_kills_it() {
        let spec = crate::job::tests::spec_of(|s| {
            s.bin = "/bin/sh".into();
            // A shell child ignores the piped prompt; sleep keeps it alive.
            s.argv = vec!["-c".into(), "exec sleep 30".into()];
            s.cwd = "/tmp".into();
        });
        // Bypass lowering: this argv has no `--`, so the whole prompt path is
        // exercised only through the fake e2e tests.
        let started =
            super::super::start_child_with_stdin(&spec, Stdio::piped()).expect("start shell");
        let kill = super::super::killer(started.pid, std::sync::Arc::clone(&started.reaped));
        let mut child = started.child;
        let t = std::thread::spawn(move || child.wait().map(|s| s.success()).unwrap_or(false));
        std::thread::sleep(std::time::Duration::from_millis(100));
        kill();
        assert!(!t.join().unwrap());
    }
}
