//! The fiber backend: binary, argv, spawn, and stream-json parsing.
//!
//! `fiber ask --model <ref> [--resume <sid>] -- <prompt>` prints one JSON
//! envelope per line. Every line carries `session_id` (Fiber mints it;
//! delegate cannot choose it), and the last line is always `fiber_exited`:
//! `exit_code`, `text` (the final answer), `usage`, and `error` on failure.
//! Unlike pi, Fiber's exit code is real and `fiber_exited.exit_code`
//! repeats it: success is a clean exit with `exit_code == 0` and no error.
//! A stream with no `fiber_exited` is a crash.

pub(crate) mod doctor;

use super::types::{BackendResult, Event, ProgressSnapshotRaw, Spawned};
use crate::types::{JobSpec, Usage};
use std::collections::HashMap;
use std::sync::atomic::Ordering;

const NO_RESULT: &str = "no result line";

pub(crate) fn resolve_bin(r#override: Option<&str>) -> String {
    if let Some(o) = r#override.filter(|s| !s.is_empty()) {
        return o.to_string();
    }
    if let Ok(env) = std::env::var("FIBER_BIN")
        && !env.is_empty()
    {
        return env;
    }
    if let Ok(out) = std::process::Command::new("which").arg("fiber").output()
        && out.status.success()
    {
        let found = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !found.is_empty() {
            return found;
        }
    }
    crate::util::homedir()
        .join(".local/bin/fiber")
        .to_string_lossy()
        .into_owned()
}

/// Strip the delegate `fiber/` prefix to Fiber's own `provider/model` reference.
pub(crate) fn model_reference(model: &str) -> &str {
    model.strip_prefix("fiber/").unwrap_or(model)
}

/// Argv for a run. `fiber ask` takes one prompt, then an optional `-`;
/// clap consumes a `--` delimiter, so a prompt starting with `-` is passed
/// after `--` and never parses as a flag (verified in Fiber's
/// `crates/main/src/cli.rs`: `AskArgs.prompt` with `num_args = 0..`).
pub(crate) fn argv(model: &str, session: Option<&str>, prompt: &str) -> Vec<String> {
    let reference = model_reference(model);
    let mut args = vec!["ask".into(), "--model".into(), reference.to_string()];
    if let Some(s) = session {
        args.push("--resume".into());
        args.push(s.to_string());
    }
    args.push("--".into());
    args.push(prompt.to_string());
    args
}

pub(crate) fn spawn(spec: &JobSpec) -> Spawned {
    let started = match super::start_child(spec) {
        Ok(s) => s,
        Err(msg) => return super::spawn_failed(&msg),
    };
    // Fiber mints the session id; it arrives in the stream, never in argv.
    let pid = started.pid;
    let reaped = started.reaped;
    let reaped_k = std::sync::Arc::clone(&reaped);
    let stdout = started.stdout;
    let stderr = started.stderr;
    let mut child = started.child;
    Spawned {
        kill: super::killer(pid, reaped_k),
        session_id: None,
        drive: Box::new(move |on| {
            let mut state = FiberState::default();
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
                            tokens_so_far: state.tokens_so_far(),
                            last_assistant: state.last_assistant.clone(),
                            files_touched: state.files_touched.clone(),
                            phase: state.phase.clone(),
                            session_id: state.session_id.clone(),
                        }));
                    }
                },
            );
            finish(state, pumped.clean_exit, &pumped.stderr)
        }),
    }
}

/// Pure parse of a finished `fiber ask` stdout. The spawn driver uses [`finish`] too.
pub fn parse_stdout(stdout: &str, clean_exit: bool, stderr: &str) -> BackendResult {
    let mut state = FiberState::default();
    for line in stdout.split_inclusive('\n') {
        handle_line(line.as_bytes(), &mut state);
    }
    finish(state, clean_exit, stderr)
}

/// One tool call's reviewer trail, keyed by `action_id`. The first request,
/// the first resolution and the first completion for an action win.
#[derive(Debug, Default)]
struct ActionRecord {
    action_id: Option<String>,
    tool_name: Option<String>,
    command: Option<String>,
    resolution: Option<ActionResolution>,
    completion: Option<ActionCompletion>,
}

#[derive(Debug)]
struct ActionResolution {
    decision: String,
    decided_by: Option<String>,
    reason: Option<String>,
}

#[derive(Debug)]
struct ActionCompletion {
    status: String,
    reason: Option<String>,
}

#[derive(Debug, Default)]
struct FiberState {
    session_id: Option<String>,
    last_tool: Option<String>,
    files_touched: Vec<String>,
    last_assistant: Option<String>,
    phase: Option<String>,
    usage_by_generation: HashMap<String, (f64, f64)>,
    exited: Option<serde_json::Value>,
    exited_session: Option<String>,
    actions: HashMap<String, ActionRecord>,
    action_order: Vec<String>,
    anonymous_actions: u64,
    /// The first `notice` with `payload.code == "no_model"`: Fiber denied
    /// every reviewed tool call for lack of a reviewer model. The run can
    /// still exit 0 with `turn_completed` completed; the result is an error
    /// whose text starts with this message.
    notice_no_model: Option<String>,
}

impl FiberState {
    fn tokens_so_far(&self) -> f64 {
        self.usage_by_generation.values().map(|(i, o)| i + o).sum()
    }

    /// The denial list, in the order each action first appeared. An action
    /// is a denial when a reviewer-set member denied it (`reviewer`,
    /// `no_reviewer` or `budget`) or when its call completed as denied.
    /// Keys with unknown values are omitted, never invented.
    fn denial_list(&self) -> Vec<serde_json::Value> {
        fn reviewer_set(s: &str) -> bool {
            matches!(s, "reviewer" | "no_reviewer" | "budget")
        }
        let mut out = Vec::new();
        for key in &self.action_order {
            let Some(rec) = self.actions.get(key) else {
                continue;
            };
            let resolution_denial = rec.resolution.as_ref().is_some_and(|r| {
                r.decision == "deny" && r.decided_by.as_deref().is_some_and(reviewer_set)
            });
            let completed_denied = rec
                .completion
                .as_ref()
                .is_some_and(|c| c.status == "denied");
            if !(resolution_denial || completed_denied) {
                continue;
            }
            let mut obj = serde_json::Map::new();
            if let Some(name) = &rec.tool_name {
                obj.insert("tool_name".into(), name.clone().into());
            }
            if let Some(id) = &rec.action_id {
                obj.insert("action_id".into(), id.clone().into());
            }
            if let Some(resolution) = &rec.resolution {
                if let Some(decided_by) = &resolution.decided_by {
                    obj.insert("decided_by".into(), decided_by.clone().into());
                }
                if let Some(reason) = &resolution.reason {
                    obj.insert("reason".into(), reason.clone().into());
                }
            } else if let Some(completion) = &rec.completion
                && let Some(reason) = &completion.reason
            {
                obj.insert("reason".into(), reason.clone().into());
            }
            if let Some(command) = &rec.command {
                obj.insert("command".into(), command.clone().into());
            }
            out.push(serde_json::Value::Object(obj));
        }
        out
    }
}

fn finite(v: Option<&serde_json::Value>) -> f64 {
    v.and_then(|n| n.as_f64())
        .filter(|n| n.is_finite())
        .unwrap_or(0.0)
}

fn cache_write_tokens(tokens: Option<&serde_json::Value>) -> f64 {
    let Some(cw) = tokens.and_then(|t| t.get("cache_write")) else {
        return 0.0;
    };
    if let Some(n) = cw.as_f64().filter(|n| n.is_finite()) {
        return n;
    }
    if let Some(obj) = cw.as_object() {
        return obj
            .values()
            .filter_map(|v| v.as_f64())
            .filter(|n| n.is_finite())
            .sum();
    }
    0.0
}

/// A non-empty string field of a payload object, or `None` when unknown.
fn non_empty(payload: Option<&serde_json::Value>, key: &str) -> Option<String> {
    payload
        .and_then(|p| p.get(key))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// One string argument of a tool call (`command`, `path`, ...). `arguments`
/// is an object, or a string holding raw text when it was not JSON.
fn tool_argument(arguments: Option<&serde_json::Value>, key: &str) -> Option<String> {
    match arguments {
        Some(serde_json::Value::Object(obj)) => obj
            .get(key)
            .and_then(|c| c.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string),
        Some(serde_json::Value::String(raw)) => serde_json::from_str::<serde_json::Value>(raw)
            .ok()
            .and_then(|v| tool_argument(Some(&v), key)),
        _ => None,
    }
}

/// The `command` argument of a tool call.
fn request_command(arguments: Option<&serde_json::Value>) -> Option<String> {
    tool_argument(arguments, "command")
}

/// The record for one event's action. An event without `action_id` gets its
/// own key, so it is never merged with another.
fn action_record<'a>(ev: &serde_json::Value, state: &'a mut FiberState) -> &'a mut ActionRecord {
    let key = ev
        .get("action_id")
        .and_then(|a| a.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| {
            state.anonymous_actions += 1;
            format!("\u{0}anonymous:{}", state.anonymous_actions)
        });
    if !state.actions.contains_key(&key) {
        let action_id = if key.starts_with('\u{0}') {
            None
        } else {
            Some(key.clone())
        };
        state.action_order.push(key.clone());
        state.actions.insert(
            key.clone(),
            ActionRecord {
                action_id,
                ..Default::default()
            },
        );
    }
    state.actions.get_mut(&key).expect("just inserted")
}

fn record_request(ev: &serde_json::Value, state: &mut FiberState) {
    let rec = action_record(ev, state);
    if rec.tool_name.is_none() {
        let payload = ev.get("payload");
        rec.tool_name = non_empty(payload, "name");
        rec.command = request_command(payload.and_then(|p| p.get("arguments")));
    }
}

fn record_resolution(ev: &serde_json::Value, state: &mut FiberState) {
    let rec = action_record(ev, state);
    if rec.resolution.is_none() {
        let payload = ev.get("payload");
        rec.resolution = Some(ActionResolution {
            decision: non_empty(payload, "decision").unwrap_or_default(),
            decided_by: non_empty(payload, "decided_by"),
            reason: non_empty(payload, "reason"),
        });
    }
}

fn record_completion(ev: &serde_json::Value, state: &mut FiberState) {
    let rec = action_record(ev, state);
    if rec.completion.is_none() {
        let payload = ev.get("payload");
        rec.completion = Some(ActionCompletion {
            status: non_empty(payload, "status").unwrap_or_default(),
            reason: non_empty(payload, "reason"),
        });
    }
}

/// Fold one stdout line into the state. Unparseable lines are ignored.
/// Returns whether a progress event should fire.
fn handle_line(line: &[u8], state: &mut FiberState) -> bool {
    let trimmed = String::from_utf8_lossy(line).trim().to_string();
    if trimmed.is_empty() {
        return false;
    }
    let ev: serde_json::Value = match serde_json::from_str(&trimmed) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let Some(kind) = ev.get("kind").and_then(|k| k.as_str()) else {
        return false;
    };
    let mut changed = false;
    if state.session_id.is_none()
        && let Some(sid) = ev.get("session_id").and_then(|s| s.as_str())
        && !sid.is_empty()
    {
        state.session_id = Some(sid.to_string());
        changed = true;
    }
    let payload = ev.get("payload");
    match kind {
        "tool_call_requested" => {
            record_request(&ev, state);
            if let Some(name) = payload.and_then(|p| p.get("name")).and_then(|n| n.as_str())
                && !name.is_empty()
            {
                state.last_tool = Some(name.to_string());
            }
            state.phase = Some("running_tool".into());
            if (state.last_tool.as_deref() == Some("edit")
                || state.last_tool.as_deref() == Some("write"))
                && let Some(path) = tool_path(payload.and_then(|p| p.get("arguments")))
                && !state.files_touched.contains(&path)
            {
                state.files_touched.push(path);
            }
            true
        }
        "text_completed" => {
            if let Some(text) = payload.and_then(|p| p.get("text")).and_then(|t| t.as_str()) {
                let truncated: String = text.chars().take(200).collect();
                state.last_assistant = Some(truncated);
                state.phase = Some("responding".into());
                return true;
            }
            changed
        }
        "assistant_message_delta" => changed,
        "usage_recorded" => {
            let generation = payload
                .and_then(|p| p.get("generation_id"))
                .and_then(|g| g.as_str())
                .unwrap_or("");
            if generation.is_empty() {
                return changed;
            }
            let tokens = payload.and_then(|p| p.get("tokens"));
            let input = finite(tokens.and_then(|t| t.get("input")));
            let output = finite(tokens.and_then(|t| t.get("output")));
            let prev = state.usage_by_generation.get(generation).copied();
            if prev != Some((input, output)) {
                state
                    .usage_by_generation
                    .insert(generation.to_string(), (input, output));
                return true;
            }
            changed
        }
        "permission_resolved" => {
            record_resolution(&ev, state);
            changed
        }
        "tool_call_completed" => {
            record_completion(&ev, state);
            changed
        }
        "turn_completed" => changed,
        "notice" => {
            if state.notice_no_model.is_none()
                && payload.and_then(|p| p.get("code")).and_then(|c| c.as_str()) == Some("no_model")
                && let Some(message) = payload
                    .and_then(|p| p.get("message"))
                    .and_then(|m| m.as_str())
            {
                state.notice_no_model = Some(message.to_string());
            }
            changed
        }
        "fiber_exited" => {
            state.exited = Some(ev.clone());
            state.exited_session = ev
                .get("session_id")
                .and_then(|s| s.as_str())
                .map(str::to_string);
            changed
        }
        _ => changed,
    }
}

/// The `path` argument of an `edit` or `write` call.
fn tool_path(arguments: Option<&serde_json::Value>) -> Option<String> {
    tool_argument(arguments, "path")
}

/// Turn the terminal `fiber_exited` (or the lack of one) into the normalized result.
fn finish(state: FiberState, clean_exit: bool, stderr: &str) -> BackendResult {
    let permission_denials = state.denial_list();
    let session_id = state.session_id.or(state.exited_session);
    let notice_no_model = state.notice_no_model;
    let Some(exited) = state.exited else {
        // No `fiber_exited`: the process died before finishing. The stderr
        // tail is the text; without stderr it is still an error with no text.
        let text = if stderr.is_empty() {
            NO_RESULT.to_string()
        } else {
            stderr.to_string()
        };
        return BackendResult {
            text: prefix_notice(text, notice_no_model.as_deref()),
            session_id,
            is_error: Some(true),
            clean_exit,
            stderr: stderr.to_string(),
            permission_denials,
            ..Default::default()
        };
    };
    let payload = exited.get("payload").cloned().unwrap_or_default();
    let exit_code = payload
        .get("exit_code")
        .and_then(|c| c.as_i64())
        .unwrap_or(1);
    let has_error = payload.get("error").is_some() || notice_no_model.is_some();
    let is_error = Some(!(clean_exit && exit_code == 0 && !has_error));
    let text = payload
        .get("text")
        .and_then(|t| t.as_str())
        .map(str::to_string)
        .or_else(|| {
            payload
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(|m| m.as_str())
                .map(str::to_string)
        })
        .unwrap_or_default();
    let text = prefix_notice(text, notice_no_model.as_deref());
    let (usage, cost_usd) = usage_and_cost(&payload);
    let provider_status = payload
        .get("error")
        .and_then(|e| e.get("provider"))
        .and_then(|p| p.get("status"))
        .and_then(|s| s.as_u64())
        .and_then(|s| u16::try_from(s).ok());
    BackendResult {
        text,
        session_id,
        usage,
        cost_usd,
        is_error,
        duration_ms: None,
        clean_exit,
        stderr: stderr.to_string(),
        permission_denials,
        provider_status,
    }
}

/// Put a `no_model` notice message first: the result text starts with it,
/// followed by the run's own text when there is any.
fn prefix_notice(text: String, notice: Option<&str>) -> String {
    match notice {
        None => text,
        Some(message) if text.is_empty() || text == message => message.to_string(),
        Some(message) => format!("{message}\n{text}"),
    }
}

fn usage_and_cost(payload: &serde_json::Value) -> (Option<Usage>, Option<f64>) {
    let Some(usage) = payload.get("usage") else {
        return (None, None);
    };
    let Some(tokens) = usage.get("tokens") else {
        return (None, None);
    };
    let input = finite(tokens.get("input"));
    let output = finite(tokens.get("output"));
    let cache_read = finite(tokens.get("cache_read"));
    let cache_write = cache_write_tokens(Some(tokens));
    let cost = usage
        .get("cost")
        .and_then(|c| c.as_f64())
        .filter(|n| n.is_finite())
        .unwrap_or(0.0);
    let subscription = usage
        .get("subscription_cost")
        .and_then(|c| c.as_f64())
        .filter(|n| n.is_finite())
        .unwrap_or(0.0);
    (
        Some(Usage {
            input_tokens: input,
            output_tokens: output,
            cache_read_tokens: cache_read,
            cache_write_tokens: cache_write,
            calls: None,
            allowance: None,
        }),
        Some(cost + subscription),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recorded(name: &str) -> (String, String) {
        let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/recorded/fiber");
        let stdout = std::fs::read_to_string(dir.join(format!("{name}.jsonl")))
            .unwrap_or_else(|e| panic!("{name}.jsonl: {e}"));
        let stderr =
            std::fs::read_to_string(dir.join(format!("{name}.stderr"))).unwrap_or_default();
        (stdout, stderr)
    }

    #[test]
    fn fresh_run_has_no_resume_and_resume_reuses_the_session() {
        let fresh = argv("fiber/opencode-go/muse-spark-1.3-contributor", None, "hi");
        assert_eq!(
            fresh,
            vec![
                "ask",
                "--model",
                "opencode-go/muse-spark-1.3-contributor",
                "--",
                "hi",
            ]
        );
        let resume = argv(
            "fiber/opencode-go/muse-spark-1.3-contributor",
            Some("s_36e63d22c39750e1"),
            "go",
        );
        assert_eq!(
            resume,
            vec![
                "ask",
                "--model",
                "opencode-go/muse-spark-1.3-contributor",
                "--resume",
                "s_36e63d22c39750e1",
                "--",
                "go",
            ]
        );
    }

    #[test]
    fn argv_keeps_a_prompt_starting_with_a_dash_after_separator() {
        let a = argv(
            "fiber/opencode-go/muse-spark-1.3-contributor",
            None,
            "-fix it",
        );
        let dash = a.iter().position(|s| s == "--").expect("separator");
        assert_eq!(&a[dash + 1..], ["-fix it"]);
        let r = argv(
            "fiber/opencode-go/muse-spark-1.3-contributor",
            Some("s_abc"),
            "-x",
        );
        let dash = r.iter().position(|s| s == "--").expect("separator");
        assert_eq!(&r[dash + 1..], ["-x"]);
        assert!(r.windows(2).any(|w| w == ["--resume", "s_abc"]));
    }

    #[test]
    fn explicit_override_wins() {
        assert_eq!(resolve_bin(Some("/custom/fiber")), "/custom/fiber");
    }

    #[test]
    fn env_used_when_no_override() {
        let _env = crate::test_env::lock();
        let prev = std::env::var("FIBER_BIN").ok();
        unsafe { std::env::set_var("FIBER_BIN", "/env/fiber") };
        assert_eq!(resolve_bin(None), "/env/fiber");
        match prev {
            Some(v) => unsafe { std::env::set_var("FIBER_BIN", v) },
            None => unsafe { std::env::remove_var("FIBER_BIN") },
        }
    }

    #[test]
    fn model_reference_strips_only_the_fiber_prefix() {
        assert_eq!(
            model_reference("fiber/opencode-go/muse-spark-1.3-contributor"),
            "opencode-go/muse-spark-1.3-contributor"
        );
        assert_eq!(
            model_reference("opencode-go/muse-spark-1.3-contributor"),
            "opencode-go/muse-spark-1.3-contributor"
        );
    }

    #[test]
    fn echo_fixture_parses_to_done() {
        let (stdout, stderr) = recorded("echo");
        let res = parse_stdout(&stdout, true, &stderr);
        assert_eq!(res.text, "DONE");
        assert_eq!(res.session_id.as_deref(), Some("s_36e63d22c39750e1"));
        assert_eq!(res.is_error, Some(false));
        assert!(res.clean_exit);
        assert_eq!(res.provider_status, None);
        let usage = res.usage.as_ref().expect("usage");
        assert_eq!(usage.input_tokens, 5712.0);
        assert_eq!(usage.output_tokens, 106.0);
        assert_eq!(usage.cache_read_tokens, 5489.0);
        assert_eq!(usage.cache_write_tokens, 0.0);
        let cost = res.cost_usd.expect("cost");
        assert!((cost - 0.000603378).abs() < 1e-12, "{cost}");
    }

    #[test]
    fn echo_fixture_reports_tool_and_tokens_progress() {
        let (stdout, _) = recorded("echo");
        let mut state = FiberState::default();
        for line in stdout.split_inclusive('\n') {
            handle_line(line.as_bytes(), &mut state);
        }
        assert_eq!(state.last_tool.as_deref(), Some("shell"));
        assert_eq!(state.phase.as_deref(), Some("responding"));
        assert_eq!(state.last_assistant.as_deref(), Some("DONE"));
        assert!(
            (state.tokens_so_far() - 5818.0).abs() < 1e-9,
            "{}",
            state.tokens_so_far()
        );
        assert_eq!(state.session_id.as_deref(), Some("s_36e63d22c39750e1"));
        // A shell call carries no path: nothing touched.
        assert!(state.files_touched.is_empty());
    }

    #[test]
    fn resume_fixture_answers_again() {
        let (stdout, stderr) = recorded("resume");
        let res = parse_stdout(&stdout, true, &stderr);
        assert_eq!(res.text, "AGAIN");
        assert_eq!(res.session_id.as_deref(), Some("s_36e63d22c39750e1"));
        assert_eq!(res.is_error, Some(false));
        let usage = res.usage.as_ref().expect("usage");
        assert_eq!(usage.input_tokens, 73.0);
        assert_eq!(usage.output_tokens, 25.0);
        assert_eq!(usage.cache_read_tokens, 5617.0);
        assert!((res.cost_usd.unwrap() - 0.000023534).abs() < 1e-12);
    }

    #[test]
    fn badmodel_fixture_is_an_error_without_usage() {
        let (stdout, stderr) = recorded("badmodel");
        assert!(!stdout.is_empty());
        let res = parse_stdout(&stdout, false, &stderr);
        assert_eq!(res.is_error, Some(true));
        assert!(!res.clean_exit);
        assert!(res.usage.is_none());
        assert_eq!(res.cost_usd, None);
        assert_eq!(res.provider_status, None);
        assert!(res.text.contains("nope"), "{}", res.text);
        assert_eq!(res.stderr, stderr);
    }

    #[test]
    fn provider_status_comes_from_fiber_exited_error() {
        let line = serde_json::json!({
            "kind": "fiber_exited",
            "session_id": "s_abc",
            "ts": 1,
            "schema_version": 1,
            "seq": 2,
            "payload": {
                "exit_code": 1,
                "error": {
                    "code": "provider_failed",
                    "message": "upstream",
                    "provider": {"name": "opencode-go", "status": 503, "message": "unavailable"}
                }
            }
        })
        .to_string();
        let res = parse_stdout(&line, false, "boom");
        assert_eq!(res.is_error, Some(true));
        assert_eq!(res.provider_status, Some(503));
        assert_eq!(res.text, "upstream");
    }

    #[test]
    fn usage_recorded_with_the_same_generation_id_replaces_the_earlier() {
        let first = serde_json::json!({
            "kind": "usage_recorded",
            "session_id": "s_1",
            "ts": 1,
            "schema_version": 1,
            "seq": 1,
            "payload": {
                "generation_id": "g1",
                "model": "opencode-go/muse-spark-1.3-contributor",
                "tokens": {"input": 100, "output": 10, "cache_read": 0, "cache_write": {}},
                "cost": 0.0,
                "input_bytes": 1
            }
        })
        .to_string();
        let correction = serde_json::json!({
            "kind": "usage_recorded",
            "session_id": "s_1",
            "ts": 2,
            "schema_version": 1,
            "seq": 2,
            "payload": {
                "generation_id": "g1",
                "model": "opencode-go/muse-spark-1.3-contributor",
                "tokens": {"input": 120, "output": 20, "cache_read": 0, "cache_write": {}},
                "cost": 0.0,
                "input_bytes": 1
            }
        })
        .to_string();
        let mut state = FiberState::default();
        assert!(handle_line(first.as_bytes(), &mut state));
        assert_eq!(state.tokens_so_far(), 110.0);
        assert!(handle_line(correction.as_bytes(), &mut state));
        assert_eq!(state.tokens_so_far(), 140.0);
    }

    #[test]
    fn edit_and_write_calls_record_their_path() {
        let mut state = FiberState::default();
        for (name, path) in [("edit", "src/a.ts"), ("write", "src/b.ts"), ("shell", "x")] {
            let line = serde_json::json!({
                "kind": "tool_call_requested",
                "session_id": "s_1",
                "ts": 1,
                "schema_version": 1,
                "seq": 1,
                "payload": {"name": name, "arguments": {"path": path}}
            })
            .to_string();
            handle_line(line.as_bytes(), &mut state);
        }
        assert_eq!(state.last_tool.as_deref(), Some("shell"));
        assert_eq!(state.files_touched, vec!["src/a.ts", "src/b.ts"]);
    }

    #[test]
    fn stream_without_fiber_exited_is_a_crash_with_stderr_as_text() {
        let (stdout, _) = recorded("echo");
        let truncated: String = stdout
            .lines()
            .filter(|l| !l.contains("\"fiber_exited\""))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(!truncated.is_empty());
        assert_ne!(truncated.len(), stdout.len());
        let res = parse_stdout(&truncated, false, "killed");
        assert_eq!(res.is_error, Some(true));
        assert_eq!(res.text, "killed");
        assert_eq!(res.session_id.as_deref(), Some("s_36e63d22c39750e1"));
        assert!(res.usage.is_none());
        assert!(!res.clean_exit);
    }

    #[test]
    fn session_id_arrives_in_progress_before_the_end() {
        let mut state = FiberState::default();
        let line = r#"{"kind":"session_started","session_id":"s_new","ts":1,"schema_version":1,"seq":0,"payload":{}}"#;
        assert!(handle_line(line.as_bytes(), &mut state));
        assert_eq!(state.session_id.as_deref(), Some("s_new"));
    }

    #[test]
    fn no_model_notice_is_an_error_despite_a_clean_exit() {
        // The run exited 0 with `turn_completed` completed, but Fiber
        // denied every reviewed tool call for lack of a reviewer model.
        let (stdout, _) = recorded("echo");
        let message = "Fiber denied every reviewed tool call: no reviewer model is configured.";
        let notice = serde_json::json!({
            "kind": "notice",
            "session_id": "s_36e63d22c39750e1",
            "ts": 1791485249434i64,
            "schema_version": 1,
            "payload": {"code": "no_model", "message": message}
        })
        .to_string();
        let with_notice: String = stdout
            .lines()
            .flat_map(|l| {
                if l.contains("\"fiber_exited\"") {
                    vec![notice.as_str(), l]
                } else {
                    vec![l]
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert_ne!(with_notice.len(), stdout.len());
        let res = parse_stdout(&with_notice, true, "");
        assert_eq!(res.is_error, Some(true));
        assert!(res.clean_exit);
        assert!(res.text.starts_with(message), "{}", res.text);
        assert_eq!(res.session_id.as_deref(), Some("s_36e63d22c39750e1"));
        // The run's own answer is kept after the notice message.
        assert!(res.text.contains("DONE"), "{}", res.text);
    }

    fn ev_line(kind: &str, action_id: &str, payload: serde_json::Value, seq: u64) -> String {
        serde_json::json!({
            "kind": kind,
            "session_id": "s_inline",
            "ts": seq,
            "schema_version": 1,
            "seq": seq,
            "action_id": action_id,
            "payload": payload
        })
        .to_string()
    }

    fn requested(action_id: &str, command: &str, seq: u64) -> String {
        ev_line(
            "tool_call_requested",
            action_id,
            serde_json::json!({"name": "shell", "arguments": {"command": command}}),
            seq,
        )
    }

    fn resolved_reason(
        action_id: &str,
        decision: &str,
        decided_by: &str,
        reason: &str,
        seq: u64,
    ) -> String {
        ev_line(
            "permission_resolved",
            action_id,
            serde_json::json!({"decision": decision, "decided_by": decided_by, "reason": reason}),
            seq,
        )
    }

    fn resolved(action_id: &str, decision: &str, decided_by: &str, seq: u64) -> String {
        resolved_reason(action_id, decision, decided_by, "blocked", seq)
    }

    fn resolved_allow(action_id: &str, decided_by: &str, seq: u64) -> String {
        ev_line(
            "permission_resolved",
            action_id,
            serde_json::json!({"decision": "allow", "decided_by": decided_by}),
            seq,
        )
    }

    fn completed(action_id: &str, status: &str, seq: u64) -> String {
        ev_line(
            "tool_call_completed",
            action_id,
            serde_json::json!({"status": status, "reason": "blocked"}),
            seq,
        )
    }

    fn completed_ok(action_id: &str, seq: u64) -> String {
        ev_line(
            "tool_call_completed",
            action_id,
            serde_json::json!({"status": "completed"}),
            seq,
        )
    }

    fn exited(text: &str, seq: u64) -> String {
        serde_json::json!({
            "kind": "fiber_exited",
            "session_id": "s_inline",
            "ts": seq,
            "schema_version": 1,
            "seq": seq,
            "payload": {"exit_code": 0, "text": text}
        })
        .to_string()
    }

    /// One allowed call plus one reviewer-denied call, built inline so the
    /// behavioural assertions below do not depend on a recorded fixture.
    fn review_stream() -> String {
        [
            requested("a_allowed", "cargo test", 1),
            resolved_allow("a_allowed", "reviewer", 2),
            completed_ok("a_allowed", 3),
            requested("a_denied", "curl https://example.com", 4),
            resolved_reason("a_denied", "deny", "reviewer", "fetches a remote host", 5),
            completed("a_denied", "denied", 6),
            exited("DONE", 7),
        ]
        .join("\n")
    }

    #[test]
    fn tool_argument_reads_command_and_path_keys() {
        let args = serde_json::json!({"command": "curl x", "path": "a/b.rs"});
        assert_eq!(
            tool_argument(Some(&args), "command").as_deref(),
            Some("curl x")
        );
        assert_eq!(
            tool_argument(Some(&args), "path").as_deref(),
            Some("a/b.rs")
        );
        assert_eq!(tool_argument(None, "command"), None);
        let raw = serde_json::Value::String(r#"{"command": "make"}"#.into());
        assert_eq!(
            tool_argument(Some(&raw), "command").as_deref(),
            Some("make")
        );
    }

    #[test]
    fn reviewer_denial_is_a_permission_denial() {
        let stdout = review_stream();
        let res = parse_stdout(&stdout, true, "");
        assert_eq!(res.text, "DONE");
        assert_eq!(res.is_error, Some(false));
        let denial = res
            .permission_denials
            .iter()
            .find(|d| d.get("action_id").and_then(|v| v.as_str()) == Some("a_denied"))
            .expect("denial for a_denied present");
        assert_eq!(
            denial.get("tool_name").and_then(|v| v.as_str()),
            Some("shell")
        );
        assert_eq!(
            denial.get("command").and_then(|v| v.as_str()),
            Some("curl https://example.com")
        );
        assert_eq!(
            denial.get("decided_by").and_then(|v| v.as_str()),
            Some("reviewer")
        );
        assert_eq!(
            denial.get("action_id").and_then(|v| v.as_str()),
            Some("a_denied")
        );
        assert_eq!(
            denial.get("reason").and_then(|v| v.as_str()),
            Some("fetches a remote host")
        );
    }

    #[test]
    fn allowed_reviewed_call_is_not_a_denial() {
        let stdout = review_stream();
        let res = parse_stdout(&stdout, true, "");
        assert!(
            res.permission_denials
                .iter()
                .all(|d| d.get("action_id").and_then(|v| v.as_str()) != Some("a_allowed")),
            "{:?}",
            res.permission_denials
        );
    }

    #[test]
    fn no_reviewer_and_budget_denials_count() {
        let stdout = [
            requested("a_nr", "curl x", 1),
            resolved("a_nr", "deny", "no_reviewer", 2),
            completed("a_nr", "denied", 3),
            requested("a_bq", "curl y", 4),
            resolved("a_bq", "deny", "budget", 5),
            completed("a_bq", "denied", 6),
        ]
        .join("\n");
        let res = parse_stdout(&stdout, false, "");
        let by_id: std::collections::HashMap<&str, &str> = res
            .permission_denials
            .iter()
            .map(|d| {
                (
                    d.get("action_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("missing"),
                    d.get("decided_by")
                        .and_then(|v| v.as_str())
                        .unwrap_or("missing"),
                )
            })
            .collect();
        assert_eq!(by_id.get("a_nr"), Some(&"no_reviewer"));
        assert_eq!(by_id.get("a_bq"), Some(&"budget"));
    }

    #[test]
    fn resolution_denial_without_completion_counts() {
        let stdout = [
            requested("a_r", "curl x", 1),
            resolved("a_r", "deny", "reviewer", 2),
        ]
        .join("\n");
        let res = parse_stdout(&stdout, false, "");
        let denial = res
            .permission_denials
            .iter()
            .find(|d| d.get("action_id").and_then(|v| v.as_str()) == Some("a_r"))
            .expect("denial for a_r present");
        assert_eq!(
            denial.get("decided_by").and_then(|v| v.as_str()),
            Some("reviewer")
        );
    }

    #[test]
    fn completed_denial_without_resolution_counts_without_decided_by() {
        let stdout = [requested("a_c", "curl x", 1), completed("a_c", "denied", 2)].join("\n");
        let res = parse_stdout(&stdout, false, "");
        let denial = res
            .permission_denials
            .iter()
            .find(|d| d.get("action_id").and_then(|v| v.as_str()) == Some("a_c"))
            .expect("denial for a_c present");
        assert!(denial.get("decided_by").is_none(), "{:?}", denial);
    }

    #[test]
    fn person_denial_only_counts_through_its_completion() {
        let stdout = [
            requested("a_p", "curl x", 1),
            resolved("a_p", "deny", "person", 2),
        ]
        .join("\n");
        let res = parse_stdout(&stdout, false, "");
        assert!(
            res.permission_denials
                .iter()
                .all(|d| d.get("action_id").and_then(|v| v.as_str()) != Some("a_p")),
            "{:?}",
            res.permission_denials
        );
    }

    #[test]
    fn duplicate_events_yield_one_denial() {
        let stdout = [
            requested("a_d", "curl x", 1),
            requested("a_d", "curl x", 2),
            resolved("a_d", "deny", "reviewer", 3),
            resolved("a_d", "deny", "reviewer", 4),
            completed("a_d", "denied", 5),
            completed("a_d", "denied", 6),
        ]
        .join("\n");
        let res = parse_stdout(&stdout, false, "");
        // The ticket #421 body: each denial is joined to its tool_call_requested.
        assert!(
            res.permission_denials
                .iter()
                .any(|d| d.get("action_id").and_then(|v| v.as_str()) == Some("a_d")),
            "{:?}",
            res.permission_denials
        );
        assert_eq!(
            res.permission_denials
                .iter()
                .filter(|d| d.get("action_id").and_then(|v| v.as_str()) == Some("a_d"))
                .count(),
            1
        );
    }

    #[test]
    fn denials_survive_a_truncated_stream() {
        let stdout = review_stream();
        let truncated: String = stdout
            .lines()
            .filter(|l| !l.contains("\"fiber_exited\""))
            .collect::<Vec<_>>()
            .join("\n");
        assert_ne!(truncated.len(), stdout.len());
        let res = parse_stdout(&truncated, false, "killed");
        assert_eq!(res.is_error, Some(true));
        assert!(
            res.permission_denials
                .iter()
                .any(|d| d.get("action_id").and_then(|v| v.as_str()) == Some("a_denied")),
            "{:?}",
            res.permission_denials
        );
    }

    #[test]
    fn malformed_lines_are_ignored() {
        let stdout = review_stream();
        let with_junk: String = stdout
            .lines()
            .flat_map(|l| [l, "this is not json"])
            .collect::<Vec<_>>()
            .join("\n");
        let res = parse_stdout(&with_junk, true, "");
        assert_eq!(res.text, "DONE");
        assert!(
            res.permission_denials
                .iter()
                .any(|d| d.get("action_id").and_then(|v| v.as_str()) == Some("a_denied")),
            "{:?}",
            res.permission_denials
        );
    }
}
