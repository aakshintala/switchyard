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
                let mut sin = stdin.take()?;
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
    saw_failed: bool,
    fatal_message: Option<String>,
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
        // A turn start is a liveness tick; the phase does not change.
        Some("turn.started") => true,
        Some("item.started") | Some("item.updated") => item_progress(&ev, state, false),
        Some("item.completed") => item_progress(&ev, state, true),
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
        // A failed turn or a stream-level error fails the row. The first
        // fatal message wins; later duplicates are ignored.
        Some("turn.failed") => {
            state.saw_failed = true;
            let message = ev
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(|m| m.as_str())
                .filter(|m| !m.is_empty());
            if state.fatal_message.is_none() {
                state.fatal_message = message.map(str::to_string);
            }
            true
        }
        Some("error") => {
            state.saw_failed = true;
            let message = ev
                .get("message")
                .and_then(|m| m.as_str())
                .filter(|m| !m.is_empty());
            if state.fatal_message.is_none() {
                state.fatal_message = message.map(str::to_string);
            }
            true
        }
        _ => false,
    }
}

/// Progress updates from thread items. Started and updated commands, tool
/// calls and web searches move the phase to running_tool; a completed
/// item moves it back to responding, and the final completed assistant
/// message is the row's final text. Reasoning, error and to-do items
/// never are.
fn item_progress(ev: &serde_json::Value, state: &mut CodexState, terminal: bool) -> bool {
    let item = match ev.get("item") {
        Some(i) => i,
        None => return false,
    };
    let phase = if terminal {
        "responding"
    } else {
        "running_tool"
    };
    match item.get("type").and_then(|t| t.as_str()) {
        Some("agent_message") => {
            let text = match item.get("text").and_then(|t| t.as_str()) {
                Some(t) => t,
                None => return false,
            };
            if terminal {
                state.final_text = Some(text.to_string());
            }
            let truncated: String = text.chars().take(200).collect();
            state.last_assistant = Some(truncated);
            state.phase = Some("responding".into());
            true
        }
        Some("command_execution") => {
            let command = match item.get("command").and_then(|c| c.as_str()) {
                Some(c) if !c.is_empty() => c,
                _ => return false,
            };
            state.last_tool = Some(command.to_string());
            state.phase = Some(phase.into());
            true
        }
        Some("mcp_tool_call") => {
            let server = item.get("server").and_then(|s| s.as_str()).unwrap_or("");
            let tool = item.get("tool").and_then(|t| t.as_str()).unwrap_or("");
            let name = match (server, tool) {
                (s, t) if !s.is_empty() && !t.is_empty() => format!("{s}/{t}"),
                (s, _) if !s.is_empty() => s.to_string(),
                (_, t) => t.to_string(),
            };
            if name.is_empty() {
                return false;
            }
            state.last_tool = Some(name);
            state.phase = Some(phase.into());
            true
        }
        Some("collab_tool_call") | Some("web_search") => {
            let name = if item.get("type").and_then(|t| t.as_str()) == Some("web_search") {
                "web_search".to_string()
            } else {
                match item.get("tool").and_then(|t| t.as_str()) {
                    Some(t) if !t.is_empty() => t.to_string(),
                    _ => return false,
                }
            };
            state.last_tool = Some(name);
            state.phase = Some(phase.into());
            true
        }
        Some("file_change") => {
            if let Some(changes) = item.get("changes").and_then(|c| c.as_array()) {
                for change in changes {
                    if let Some(path) = change.get("path").and_then(|p| p.as_str())
                        && !path.is_empty()
                        && !state.files_touched.contains(&path.to_string())
                    {
                        state.files_touched.push(path.to_string());
                    }
                }
            }
            true
        }
        _ => false,
    }
}

/// Extract an explicit HTTP status from a fatal Codex error message. Only
/// the two shapes Codex itself renders are recognized: `unexpected
/// status {NNN}` (UnexpectedResponseError) and `last status: {NNN}`
/// (RetryLimitReachedError). Anything else, including a bare number or a
/// user_message override that hides the status, yields None.
fn status_in_message(message: &str) -> Option<u16> {
    let mut best: Option<(usize, u16)> = None;
    for needle in ["unexpected status ", "last status: "] {
        let mut from = 0;
        while let Some(found) = message[from..].find(needle) {
            let abs = from + found;
            let tail = &message[abs + needle.len()..];
            let digits: String = tail.chars().take(3).collect();
            let boundary_ok = tail.chars().nth(3).is_none_or(|c| !c.is_ascii_digit());
            if digits.len() == 3
                && digits.bytes().all(|b| b.is_ascii_digit())
                && boundary_ok
                && let Ok(status) = digits.parse::<u16>()
            {
                if best.is_none_or(|(pos, _)| abs < pos) {
                    best = Some((abs, status));
                }
                break;
            }
            from = abs + needle.len();
        }
    }
    best.map(|(_, status)| status)
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

/// Turn terminal `turn` events (or the lack of one) into the normalized
/// result. Success needs a completed turn with no failure, a completed
/// agent message and a clean exit; anything else is an error whose
/// diagnostic text ends in `STATUS: ERROR`, because the shared status
/// derivation honors a trailing STATUS line ahead of `is_error`/exit
/// and must never read an early `STATUS: DONE` from a crashed stream as
/// success. Fatal stream messages carry the diagnostic; otherwise the
/// no-result diagnostic applies. CANCELLED is the supervisor's status,
/// never ours. `launched_session` is the resume thread id the run was
/// launched with, used when the stream never sent a header.
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
    match (
        &state.final_text,
        state.saw_failed,
        state.saw_turn_completed,
        clean_exit,
    ) {
        (Some(text), false, true, true) => BackendResult {
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
        _ => {
            let provider_status = state.fatal_message.as_deref().and_then(status_in_message);
            let diagnostic = state
                .fatal_message
                .as_deref()
                .filter(|m| !m.is_empty())
                .unwrap_or(NO_RESULT);
            BackendResult {
                text: format!("{diagnostic}\nSTATUS: ERROR"),
                session_id,
                is_error: Some(true),
                clean_exit,
                stderr: stderr.to_string(),
                provider_status,
                ..Default::default()
            }
        }
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
    fn multiple_agent_messages_select_the_final_completed_text() {
        let stream = concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"t\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"first\"}}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"b\",\"type\":\"agent_message\",\"text\":\"second\\nSTATUS: DONE\"}}\n",
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":1}}\n",
        );
        let res = parse_stdout(stream, true, "");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(res.text, "second\nSTATUS: DONE");
    }

    #[test]
    fn final_line_without_a_trailing_newline_still_parses() {
        let mut stream = four_event_stream();
        stream.pop();
        let res = parse_stdout(&stream, true, "");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(res.text, "pong\nSTATUS: DONE");
    }

    #[test]
    fn turn_start_is_a_progress_tick_without_a_phase_change() {
        let mut state = CodexState::default();
        assert!(state.phase.is_none());
        assert!(handle_line(b"{\"type\":\"turn.started\"}", &mut state));
        assert!(state.phase.is_none());
        assert!(state.session_id.is_none());
    }

    #[test]
    fn item_activity_drives_phase_last_tool_and_files_touched() {
        let mut state = CodexState::default();
        // A started command moves to running_tool with the command name.
        assert!(handle_line(
            br#"{"type":"item.started","item":{"id":"c","type":"command_execution","command":"cargo test","status":"in_progress"}}"#,
            &mut state
        ));
        assert_eq!(state.last_tool.as_deref(), Some("cargo test"));
        assert_eq!(state.phase.as_deref(), Some("running_tool"));
        assert!(state.final_text.is_none());
        // A completed command returns to responding with no final text.
        assert!(handle_line(
            br#"{"type":"item.completed","item":{"id":"c","type":"command_execution","command":"cargo test","status":"completed"}}"#,
            &mut state
        ));
        assert_eq!(state.phase.as_deref(), Some("responding"));
        assert!(state.final_text.is_none());
        // Empty and missing commands record nothing.
        assert!(!handle_line(
            br#"{"type":"item.started","item":{"id":"c","type":"command_execution","command":""}}"#,
            &mut state
        ));
        assert!(!handle_line(
            br#"{"type":"item.started","item":{"id":"c","type":"command_execution"}}"#,
            &mut state
        ));
        // MCP tool calls compose server and tool names.
        assert!(handle_line(
            br#"{"type":"item.started","item":{"id":"m","type":"mcp_tool_call","server":"gh","tool":"issue_read"}}"#,
            &mut state
        ));
        assert_eq!(state.last_tool.as_deref(), Some("gh/issue_read"));
        assert_eq!(state.phase.as_deref(), Some("running_tool"));
        let mut bare = CodexState::default();
        assert!(handle_line(
            br#"{"type":"item.updated","item":{"id":"m","type":"mcp_tool_call","server":"gh"}}"#,
            &mut bare
        ));
        assert_eq!(bare.last_tool.as_deref(), Some("gh"));
        assert!(handle_line(
            br#"{"type":"item.updated","item":{"id":"m","type":"mcp_tool_call","tool":"t"}}"#,
            &mut bare
        ));
        assert_eq!(bare.last_tool.as_deref(), Some("t"));
        assert!(!handle_line(
            br#"{"type":"item.updated","item":{"id":"m","type":"mcp_tool_call"}}"#,
            &mut bare
        ));
        // Collab tool calls record the tool; web searches record the kind.
        assert!(handle_line(
            br#"{"type":"item.started","item":{"id":"k","type":"collab_tool_call","tool":"spawn_agent"}}"#,
            &mut state
        ));
        assert_eq!(state.last_tool.as_deref(), Some("spawn_agent"));
        assert!(!handle_line(
            br#"{"type":"item.started","item":{"id":"k","type":"collab_tool_call"}}"#,
            &mut state
        ));
        assert!(handle_line(
            br#"{"type":"item.started","item":{"id":"w","type":"web_search","query":"rust"}}"#,
            &mut state
        ));
        assert_eq!(state.last_tool.as_deref(), Some("web_search"));
        // File changes record touched paths without becoming final text.
        assert!(handle_line(
            br#"{"type":"item.completed","item":{"id":"f","type":"file_change","status":"completed","changes":[{"path":"src/a.ts","kind":"update"},{"path":"","kind":"add"}]}}"#,
            &mut state
        ));
        assert_eq!(state.files_touched, vec!["src/a.ts"]);
        assert!(state.final_text.is_none());
        // A nonterminal agent message is progress, not final text.
        assert!(handle_line(
            br#"{"type":"item.updated","item":{"id":"a","type":"agent_message","text":"thinking out loud"}}"#,
            &mut state
        ));
        assert_eq!(state.last_assistant.as_deref(), Some("thinking out loud"));
        assert!(state.final_text.is_none());
        // Error and to-do items are nonfatal: ignored, never final text.
        assert!(!handle_line(
            br#"{"type":"item.completed","item":{"id":"e","type":"error","message":"flaky tool"}}"#,
            &mut state
        ));
        assert!(!handle_line(
            br#"{"type":"item.completed","item":{"id":"d","type":"todo_list","items":[]}}"#,
            &mut state
        ));
        assert!(!handle_line(br#"{"type":"item.started"}"#, &mut state));
        assert!(!handle_line(
            br#"{"type":"item.started","item":{"id":"x","type":"future_item"}}"#,
            &mut state
        ));
    }

    #[test]
    fn turn_failed_and_error_events_fail_with_the_first_fatal_message() {
        let mut state = CodexState::default();
        assert!(handle_line(
            b"{\"type\":\"thread.started\",\"thread_id\":\"t-fail\"}",
            &mut state
        ));
        assert!(handle_line(
            br#"{"type":"turn.failed","error":{"message":"unexpected status 503 Service Unavailable: upstream down"}}"#,
            &mut state
        ));
        // A duplicate failure keeps the first message.
        assert!(handle_line(
            br#"{"type":"error","message":"exceeded retry limit, last status: 503 Service Unavailable"}"#,
            &mut state
        ));
        let res = finish(state, false, "some stderr", None, None);
        assert_eq!(res.is_error, Some(true));
        assert!(
            res.text
                .contains("unexpected status 503 Service Unavailable: upstream down"),
            "{}",
            res.text
        );
        assert!(res.text.ends_with("STATUS: ERROR"), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("t-fail"));
        assert_eq!(res.stderr, "some stderr");
        // The earliest anchored status in the kept message wins.
        assert_eq!(res.provider_status, Some(503));
        assert!(res.usage.is_none());
    }

    #[test]
    fn failure_without_a_message_uses_the_no_result_diagnostic() {
        let mut state = CodexState::default();
        assert!(handle_line(b"{\"type\":\"turn.failed\"}", &mut state));
        let res = finish(state, false, "", None, None);
        assert_eq!(res.is_error, Some(true));
        assert!(res.text.starts_with("no result line"), "{}", res.text);
        assert!(res.text.ends_with("STATUS: ERROR"), "{}", res.text);
        assert_eq!(res.provider_status, None);
    }

    #[test]
    fn failed_stream_diagnostics_are_errors_despite_agent_text() {
        let stream = concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"t\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"partial\\nSTATUS: DONE\"}}\n",
            "{\"type\":\"turn.failed\",\"error\":{\"message\":\"boom\"}}\n",
        );
        let res = parse_stdout(stream, false, "");
        assert_eq!(res.is_error, Some(true));
        assert!(!res.text.contains("partial"), "{}", res.text);
        assert!(res.text.ends_with("STATUS: ERROR"), "{}", res.text);
    }

    #[test]
    fn missing_completion_and_message_are_errors() {
        // A message without a completed turn.
        let stream = concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"t\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"hi\"}}\n",
        );
        let res = parse_stdout(stream, true, "");
        assert_eq!(res.is_error, Some(true));
        assert!(res.text.starts_with("no result line"), "{}", res.text);
        // A completed turn without an agent message.
        let res = parse_stdout(
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1}}\n",
            true,
            "",
        );
        assert_eq!(res.is_error, Some(true));
    }

    #[test]
    fn nonzero_exit_despite_a_message_is_an_error() {
        let res = parse_stdout(&four_event_stream(), false, "");
        assert_eq!(res.is_error, Some(true));
        assert!(!res.text.contains("pong"), "{}", res.text);
        assert!(res.text.ends_with("STATUS: ERROR"), "{}", res.text);
    }

    #[test]
    fn provider_status_only_comes_from_recognized_http_shapes() {
        for (message, want) in [
            ("unexpected status 500 Internal Server Error: x", Some(500)),
            (
                "unexpected status 503 Service Unavailable: upstream",
                Some(503),
            ),
            ("unexpected status 599 whatever", Some(599)),
            ("unexpected status 401 Unauthorized: bad key", Some(401)),
            ("unexpected status 429 Too Many Requests: slow", Some(429)),
            ("unexpected status 400 Bad Request: nope", Some(400)),
            ("unexpected status 600 x", Some(600)),
            (
                "exceeded retry limit, last status: 503 Service Unavailable",
                Some(503),
            ),
            (
                "exceeded retry limit, last status: 401 Unauthorized, request id: abc",
                Some(401),
            ),
            ("unexpected status 5030: four digits", None),
            ("unexpected status 50: two digits", None),
            ("unexpected status \u{00e9}503: unicode", None),
            ("quota exceeded after 429 requests", None),
            ("503 Service Unavailable", None),
            ("upstream returned {\"status\":503}", None),
            ("", None),
        ] {
            assert_eq!(status_in_message(message), want, "{message}");
        }
        // A number in assistant text is never a provider status.
        let stream = four_event_stream().replace("pong", "saw 503 errors");
        let res = parse_stdout(&stream, true, "");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(res.provider_status, None);
    }

    #[test]
    fn present_cache_write_is_recorded_and_missing_cache_write_is_zero() {
        let stream = concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"t\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"hi\\nSTATUS: DONE\"}}\n",
            "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":10,\"cache_write_input_tokens\":7,\"output_tokens\":3}}\n",
        );
        let res = parse_stdout(stream, true, "");
        assert_eq!(res.is_error, Some(false));
        let usage = res.usage.as_ref().expect("usage");
        assert_eq!(usage.input_tokens, 90.0);
        assert_eq!(usage.cache_read_tokens, 10.0);
        assert_eq!(usage.cache_write_tokens, 7.0);
        assert_eq!(usage.output_tokens, 3.0);
        // An omitted cache-write field defaults to zero.
        let stream = stream.replace(",\"cache_write_input_tokens\":7", "");
        let res = parse_stdout(&stream, true, "");
        assert_eq!(res.is_error, Some(false));
        assert_eq!(res.usage.as_ref().expect("usage").cache_write_tokens, 0.0);
    }

    #[test]
    fn malformed_or_negative_usage_yields_success_without_usage() {
        for usage in [
            "{\"input_tokens\":\"lots\",\"cached_input_tokens\":0,\"output_tokens\":1}",
            "{\"input_tokens\":10,\"cached_input_tokens\":-4,\"output_tokens\":1}",
            "{\"input_tokens\":10,\"cached_input_tokens\":0}",
        ] {
            let stream = format!(
                concat!(
                    "{{\"type\":\"thread.started\",\"thread_id\":\"t\"}}\n",
                    "{{\"type\":\"item.completed\",\"item\":{{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"hi\\nSTATUS: DONE\"}}}}\n",
                    "{{\"type\":\"turn.completed\",\"usage\":{u}}}\n",
                ),
                u = usage,
            );
            let res = parse_stdout(&stream, true, "");
            assert_eq!(res.is_error, Some(false), "{usage}");
            assert!(res.usage.is_none(), "{usage}");
        }
    }

    #[test]
    fn resume_continuation_argv_inserts_cwd_ahead_of_resume() {
        // A row without an effort suffix sends no effort flag; the
        // continuation prompt stages at the end, then lowers to stdin
        // with `-C <cwd>` inserted ahead of `resume`.
        let prompt = "Your previous turn stopped on a transient provider error (HTTP 503).";
        let staged = argv("codex/gpt-6-astra", Some("thread-9"), prompt);
        assert_eq!(
            staged,
            vec![
                "exec",
                "-s",
                "workspace-write",
                "resume",
                "thread-9",
                "--json",
                "-m",
                "gpt-6-astra",
                "--",
                prompt,
            ]
        );
        let wire: Vec<String> = staged.iter().map(|s| s.to_string()).collect();
        let (child, stdin) = lower_to_wire(&wire, "/work/tree");
        assert_eq!(
            child,
            vec![
                "exec",
                "-s",
                "workspace-write",
                "-C",
                "/work/tree",
                "resume",
                "thread-9",
                "--json",
                "-m",
                "gpt-6-astra",
                "--",
                "-",
            ]
        );
        assert_eq!(stdin, prompt);
    }

    #[test]
    fn session_extraction_needs_a_resume_thread_id() {
        let staged = |parts: &[&str]| parts.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            session_from_staging_argv(&staged(&["exec", "resume", "t-1", "--", "-"])),
            Some("t-1".to_string())
        );
        // `resume` with no following id, and a fresh form, resume nothing.
        assert_eq!(
            session_from_staging_argv(&staged(&["exec", "resume"])),
            None
        );
        assert_eq!(
            session_from_staging_argv(&staged(&["exec", "--json", "--", "-"])),
            None
        );
        assert_eq!(session_from_staging_argv(&[]), None);
    }

    #[test]
    fn non_http_failures_carry_no_provider_status() {
        for message in [
            "interrupted",
            "cancelled",
            "https://example.com/a 503 ok",
            "unexpected status500: no space",
            "unexpected status : empty",
        ] {
            let stream = format!(
                concat!(
                    "{{\"type\":\"thread.started\",\"thread_id\":\"t\"}}\n",
                    "{{\"type\":\"turn.failed\",\"error\":{{\"message\":{m:?}}}}}\n",
                ),
                m = message,
            );
            let res = parse_stdout(&stream, false, "");
            assert_eq!(res.is_error, Some(true), "{message}");
            assert!(res.text.contains(message), "{message}: {}", res.text);
            assert_eq!(res.provider_status, None, "{message}");
        }
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
        // A spawn failure carries no recognized status, so it is never retried.
        assert_eq!(res.provider_status, None);
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
