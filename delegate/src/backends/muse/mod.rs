//! The muse backend: binary, argv, spawn, and stream-json parsing.
//!
//! `muse exec --json` prints one JSON object per line. Parsing is fail-closed:
//! success requires a completed terminal record, usage evidence for the
//! requested model and no failed calls.
//!
//! The sandbox is off by default on every host, so the worktree is the only
//! containment; a host profile with `museSandbox: true` turns the muse
//! sandbox back on. Every run passes `--disable-approval` and `--trust-workspace`
//! (so Muse loads the repo's AGENTS.md and rules), never `--yolo`.
//! A rate-limit or provider-error envelope has no mapping yet (no capture
//! exists), so `provider_status` stays `None` and such a run surfaces as a
//! non-completed terminal, which is not retried.

use super::types::{BackendResult, Event, ProgressSnapshotRaw, Spawned};
use crate::models::MUSE_EFFORT_LEVELS;
use crate::types::{Allowance, AllowanceWindow, JobSpec, Usage};
use serde_json::Value;
use std::sync::atomic::Ordering;

// Hard per-job wall cap when the job carries no tool-idle limit: the same
// 1_800_000 ms default `cli.rs` gives `tool_idle_ms`.
const DEFAULT_WALL_TIMEOUT_MS: u64 = 1_800_000;

#[derive(Debug, Default)]
struct MuseState {
    session_id: Option<String>,
    saw_session_stream: bool,
    usage_payload: Option<Value>,
    terminal: Option<Value>,
    last_tool: Option<String>,
    last_assistant: Option<String>,
    phase: Option<String>,
    wall_exceeded: bool,
    wall_timeout_ms: Option<u64>,
}

/// Parse a finished Muse JSONL stream. The requested model is the base id without `muse/`.
pub fn parse_stdout(stdout: &str, model: &str, clean_exit: bool, stderr: &str) -> BackendResult {
    let mut state = MuseState::default();
    for line in stdout.split_inclusive('\n') {
        handle_line(line.as_bytes(), &mut state);
    }
    finish(state, model, clean_exit, stderr, None)
}

pub(crate) fn resolve_bin(r#override: Option<&str>) -> String {
    if let Some(o) = r#override.filter(|s| !s.is_empty()) {
        return o.to_string();
    }
    if let Ok(env) = std::env::var("MUSE_BIN")
        && !env.is_empty()
    {
        return env;
    }
    if let Ok(out) = std::process::Command::new("which").arg("muse").output()
        && out.status.success()
    {
        let found = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !found.is_empty() {
            return found;
        }
    }
    crate::util::homedir()
        .join(".local/bin/muse")
        .to_string_lossy()
        .into_owned()
}

/// Split a delegate `muse/...` id into the child model and an optional reasoning
/// effort. Only one leading `muse/` is stripped and only a trailing
/// `:<level>` from [`MUSE_EFFORT_LEVELS`] becomes an effort; any other colon
/// belongs to the model itself and is passed through whole.
pub(crate) fn base_and_effort(model: &str) -> (&str, Option<&str>) {
    let base = model.strip_prefix("muse/").unwrap_or(model);
    match base.rsplit_once(':') {
        Some((b, level)) if MUSE_EFFORT_LEVELS.contains(&level) => (b, Some(level)),
        _ => (base, None),
    }
}

/// Staging argv for a run. The prompt rides after the `--` separator, exactly
/// where the child takes it; spawn lowers this staging form into the real
/// child wire argv (inserting `--workspace <cwd>` from the spec), so the
/// staging form itself is never executed and must never be mistaken for
/// child wire argv in tests: assert the actual child argv through a fake
/// process instead. `--reasoning-effort` is sent only when the id carries a
/// level; otherwise Muse uses its own default.
pub(crate) fn argv(model: &str, session: Option<&str>, prompt: &str) -> Vec<String> {
    // The session id is chosen before launch: resume passes the stored id, a
    // fresh run mints one (muse creates the session if absent).
    let session = session
        .map(str::to_string)
        .unwrap_or_else(crate::util::random_uuid);
    let (base, effort) = base_and_effort(model);
    let mut args: Vec<String> = vec![
        "exec".into(),
        "--json".into(),
        "--disable-approval".into(),
        "--trust-workspace".into(),
        "--model".into(),
        base.to_string(),
    ];
    if let Some(level) = effort {
        args.push("--reasoning-effort".into());
        args.push(level.to_string());
    }
    args.push("--session-id".into());
    args.push(session);
    args.push("--".into());
    args.push(prompt.to_string());
    args
}

/// The `--session-id` value in an argv built by [`argv`].
fn session_from_argv(argv: &[String]) -> Option<String> {
    argv.windows(2)
        .find(|w| w[0] == "--session-id")
        .map(|w| w[1].clone())
}

/// Lower a staging argv plus the spec cwd into the real child argv. The
/// staging form always ends in `-- <prompt>` (a separator plus a single
/// trailing prompt element); the child replaces that separator with
/// `--workspace <cwd>` followed by a fresh `--`, and the prompt stays the
/// last element even when it is `--`.
fn lower(staging: &[String], cwd: &str) -> Vec<String> {
    let prompt = staging.last().cloned().unwrap_or_default();
    let mut wire = staging[..staging.len().saturating_sub(2)].to_vec();
    wire.push("--workspace".into());
    wire.push(cwd.to_string());
    wire.push("--".into());
    wire.push(prompt);
    wire
}

/// Apply the per-host sandbox switch to a staging argv. Sandbox on leaves
/// the argv unchanged; sandbox off inserts one `--disable-sandbox` directly
/// before the final `--` separator (at len-2, so a prompt of `--` stays the
/// prompt). Only this function adds the flag.
pub(crate) fn with_sandbox(mut argv: Vec<String>, sandbox_on: bool) -> Vec<String> {
    if !sandbox_on {
        let at = argv.len().saturating_sub(2);
        argv.insert(at, "--disable-sandbox".into());
    }
    argv
}

/// Wall cap for a run in milliseconds: the job spec's tool-idle limit, or
/// the default when the job carries none. `Some(None)` disables the cap.
fn wall_cap_ms(tool_idle_ms: Option<Option<f64>>) -> Option<u64> {
    match tool_idle_ms {
        None => Some(DEFAULT_WALL_TIMEOUT_MS),
        Some(inner) => inner.map(|ms| ms as u64),
    }
}

pub(crate) fn spawn(spec: &JobSpec) -> Spawned {
    // The stream usually repeats this id in its `session` header; when it
    // doesn't (a crash before the first line), the result still carries it.
    let launched_session = session_from_argv(&spec.argv);
    let base = base_and_effort(&spec.model).0.to_string();
    let tool_idle_ms = spec.tool_idle_ms;
    let wall_started_at = std::time::Instant::now();
    let mut wired = spec.clone();
    wired.argv = lower(&spec.argv, &spec.cwd);
    let started = match super::start_child(&wired) {
        Ok(s) => s,
        Err(msg) => return super::spawn_failed(&msg),
    };
    let pid = started.pid;
    let reaped = started.reaped;
    let reaped_k = std::sync::Arc::clone(&reaped);
    let stdout = started.stdout;
    let stderr = started.stderr;
    let mut child = started.child;
    let reaped_wall = std::sync::Arc::clone(&reaped);
    Spawned {
        kill: super::killer(pid, reaped_k),
        session_id: launched_session.clone(),
        drive: Box::new(move |on| {
            let mut state = MuseState::default();
            let cap = wall_cap_ms(tool_idle_ms);
            let wall_exceeded = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let wall_watchdog = cap.map(|cap| {
                let (stop_tx, stop_rx) = std::sync::mpsc::channel();
                let timed_out = std::sync::Arc::clone(&wall_exceeded);
                let wall_kill = super::killer(pid, std::sync::Arc::clone(&reaped_wall));
                let remaining =
                    std::time::Duration::from_millis(cap).saturating_sub(wall_started_at.elapsed());
                let thread = std::thread::spawn(move || {
                    if stop_rx.recv_timeout(remaining).is_err() {
                        timed_out.store(true, Ordering::SeqCst);
                        wall_kill();
                    }
                });
                (stop_tx, thread)
            });
            // Raw chunk and stderr liveness never count as progress: only a
            // tool result, a model message or a terminal record refreshes
            // the idle clock, so a reminder-task loop goes STALLED.
            let forward = |event: Event| {
                if matches!(event, Event::Progress(_)) {
                    on(event);
                }
            };
            let pumped = super::pump(
                stdout,
                stderr,
                &forward,
                move || {
                    let clean = child.wait().map(|s| s.success()).unwrap_or(false);
                    reaped.store(true, Ordering::SeqCst);
                    clean
                },
                |line| {
                    if handle_line(line, &mut state) {
                        forward(Event::Progress(ProgressSnapshotRaw {
                            last_tool: state.last_tool.clone(),
                            tokens_so_far: 0.0,
                            last_assistant: state.last_assistant.clone(),
                            files_touched: Vec::new(),
                            phase: state.phase.clone(),
                            session_id: state
                                .session_id
                                .clone()
                                .or_else(|| launched_session.clone()),
                        }));
                    }
                },
            );
            if let Some((stop_tx, thread)) = wall_watchdog {
                let _ = stop_tx.send(());
                thread.join().expect("wall watchdog panicked");
            }
            if wall_exceeded.load(Ordering::SeqCst) {
                state.wall_exceeded = true;
                state.wall_timeout_ms = cap;
            }
            finish(
                state,
                &base,
                pumped.clean_exit,
                &pumped.stderr,
                launched_session.as_deref(),
            )
        }),
    }
}

/// Fold one JSONL record into parser state and report only meaningful progress.
fn handle_line(line: &[u8], state: &mut MuseState) -> bool {
    let Ok(record) = serde_json::from_slice::<Value>(line) else {
        return false;
    };

    if !state.saw_session_stream
        && record
            .get("stream")
            .and_then(|stream| stream.get("kind"))
            .and_then(Value::as_str)
            == Some("session")
    {
        state.saw_session_stream = true;
        state.session_id = record
            .get("stream")
            .and_then(|stream| stream.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string);
    }

    let Some(payload_type) = record.get("payload_type").and_then(Value::as_str) else {
        return false;
    };
    let payload = record.get("payload").unwrap_or(&Value::Null);
    match payload_type {
        "tool.result" => {
            if let Some(tool) = payload
                .get("correlation_facts")
                .and_then(|facts| facts.get("tool_name"))
                .and_then(Value::as_str)
            {
                state.last_tool = Some(tool.to_string());
            }
            true
        }
        "run.output.delta" => {
            if let Some(text) = payload.get("text").and_then(Value::as_str) {
                state.last_assistant = Some(text.chars().take(200).collect());
            }
            state.phase = Some("responding".into());
            true
        }
        "run.usage" => {
            state.usage_payload = Some(payload.clone());
            false
        }
        _ if payload_type.starts_with("run.terminal.") => {
            if state.terminal.is_none() {
                state.terminal = Some(payload.clone());
            }
            true
        }
        _ => false,
    }
}

fn finite_number(value: Option<&Value>) -> f64 {
    value
        .and_then(Value::as_f64)
        .filter(|number| number.is_finite())
        .unwrap_or(0.0)
}

fn finite_optional(value: Option<&Value>) -> Option<f64> {
    value
        .and_then(Value::as_f64)
        .filter(|number| number.is_finite())
}

fn allowance_window(value: Option<&Value>) -> Option<AllowanceWindow> {
    let value = value?;
    let used_percent = finite_optional(value.get("used_percent"))?;
    let resets_at_ms = finite_optional(value.get("resets_at_ms"))?;
    Some(AllowanceWindow {
        used_percent,
        resets_at_ms,
    })
}

fn allowance(value: Option<&Value>) -> Option<Allowance> {
    let value = value.filter(|value| !value.is_null())?;
    Some(Allowance {
        window: allowance_window(value.get("window")),
        weekly: allowance_window(value.get("weekly")),
        as_of_ms: finite_optional(value.get("as_of_ms")),
    })
}

fn parse_usage(payload: &Value) -> Usage {
    let models = payload.get("models").and_then(Value::as_array);
    let (input_tokens, cache_read_tokens, output_tokens) = models.into_iter().flatten().fold(
        (0.0, 0.0, 0.0),
        |(input_sum, cached_sum, output_sum), model| {
            let input = finite_number(model.get("input_tokens"));
            let cached = finite_number(model.get("cached_tokens"));
            (
                input_sum + (input - cached).max(0.0),
                cached_sum + cached,
                output_sum + finite_number(model.get("output_tokens")),
            )
        },
    );
    Usage {
        input_tokens,
        output_tokens,
        cache_read_tokens,
        cache_write_tokens: 0.0,
        calls: payload.get("calls").and_then(Value::as_u64),
        allowance: allowance(payload.get("allowance")),
    }
}

fn one_line(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn error_result(
    text: String,
    session_id: Option<String>,
    usage: Option<Usage>,
    clean_exit: bool,
    stderr: &str,
) -> BackendResult {
    BackendResult {
        text,
        session_id,
        usage,
        is_error: Some(true),
        clean_exit,
        stderr: stderr.to_string(),
        ..BackendResult::default()
    }
}

/// Validate the stream and return either the terminal answer or a diagnostic.
fn finish(
    state: MuseState,
    model: &str,
    clean_exit: bool,
    stderr: &str,
    launched_session: Option<&str>,
) -> BackendResult {
    let session_id = state
        .session_id
        .clone()
        .or_else(|| launched_session.map(str::to_string));
    let usage = state.usage_payload.as_ref().map(parse_usage);
    // A failed model call that the run recovered from is not a diagnostic
    // for the answer: it is noted on stderr and the answer is kept.
    let mut failed_calls_note = None;
    let diagnostic = if state.wall_exceeded {
        Some(format!(
            "muse: wall timeout ({} ms)",
            state.wall_timeout_ms.unwrap_or(DEFAULT_WALL_TIMEOUT_MS)
        ))
    } else if state.terminal.is_none() {
        Some("muse: no terminal record".to_string())
    } else {
        let terminal = state.terminal.as_ref().unwrap();
        let terminal_name = terminal.get("terminal").and_then(Value::as_str);
        if terminal_name != Some("completed") {
            let name = terminal_name.map(one_line).unwrap_or_else(|| "?".into());
            let reason = terminal.get("reason").and_then(Value::as_str).map(one_line);
            Some(match reason {
                Some(reason) => format!("muse: run ended {:?} (reason {:?})", name, reason),
                None => format!("muse: run ended {:?}", name),
            })
        } else if let Some(payload) = state.usage_payload.as_ref() {
            let models = payload.get("models").and_then(Value::as_array);
            if models.is_none_or(Vec::is_empty) {
                Some("muse: no model evidence in run.usage".to_string())
            } else {
                let models = models.unwrap();
                if models
                    .iter()
                    .any(|entry| entry.get("model").and_then(Value::as_str) != Some(model))
                {
                    let reported = models
                        .iter()
                        .map(|entry| {
                            entry
                                .get("model")
                                .and_then(Value::as_str)
                                .map(one_line)
                                .unwrap_or_else(|| "?".into())
                        })
                        .collect::<Vec<_>>()
                        .join(", ");
                    Some(format!(
                        "muse: model mismatch: requested {}, run.usage reported [{}]",
                        one_line(model),
                        reported
                    ))
                } else {
                    let failed_calls = payload
                        .get("failed_calls")
                        .map(|value| value.as_u64().unwrap_or(1))
                        .unwrap_or(0);
                    if failed_calls != 0 {
                        failed_calls_note =
                            Some(format!("muse: {failed_calls} failed model call(s)"));
                    }
                    None
                }
            }
        } else {
            Some("muse: no model evidence in run.usage".to_string())
        }
    };

    if let Some(text) = diagnostic {
        return error_result(text, session_id, usage, clean_exit, stderr);
    }

    let (is_error, stderr) = match failed_calls_note {
        Some(note) if stderr.trim().is_empty() => (Some(true), format!("{note}\n")),
        Some(note) => (Some(true), format!("{}\n{note}\n", stderr.trim_end())),
        None => (Some(false), stderr.to_string()),
    };
    BackendResult {
        text: state
            .terminal
            .as_ref()
            .and_then(|terminal| terminal.get("text"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        session_id,
        usage,
        cost_usd: None,
        is_error,
        duration_ms: None,
        clean_exit,
        stderr,
        permission_denials: Vec::new(),
        provider_status: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::output::derive_status;
    use crate::test_env::EnvGuard;
    use crate::types::RunStatus;
    use serde_json::{Value, json};

    const MODEL: &str = "muse-spark-1.3-contributor";
    const TOOL_CALLS_FIX: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/contract/muse/tool-calls-fix.stdout"
    ));
    const RESUME_FIRST: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/contract/muse/resume-first.stdout"
    ));
    const RESUME_ANSWER: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/contract/muse/resume-answer.stdout"
    ));
    const BAD_MODEL: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/contract/muse/error-bad-model.stdout"
    ));
    const SANDBOX_ALLOWANCE: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/contract/muse/sandbox-allowance.stdout"
    ));
    const REMINDER_STALL: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/contract/muse/reminder-stall.stdout"
    ));

    fn parse_fixture(stdout: &str) -> BackendResult {
        parse_stdout(stdout, MODEL, true, "")
    }

    fn json_records(stream: &str) -> Vec<Value> {
        stream
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }

    fn encode_records(records: &[Value]) -> String {
        records
            .iter()
            .map(serde_json::to_string)
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
            .join("\n")
    }

    fn record_mut<'a>(records: &'a mut [Value], payload_type: &str) -> &'a mut Value {
        records
            .iter_mut()
            .find(|record| record["payload_type"] == payload_type)
            .unwrap_or_else(|| panic!("missing {payload_type}"))
    }

    fn line(payload_type: &str, payload: Value) -> Vec<u8> {
        json!({
            "schema_version": 1,
            "id": "envelope-id",
            "stream": {"kind": "run", "id": "run-id"},
            "sequence": 1,
            "record_type": "event",
            "payload_type": payload_type,
            "payload": payload
        })
        .to_string()
        .into_bytes()
    }

    #[test]
    fn tool_calls_fixture_normalizes_usage_and_result() {
        let result = parse_fixture(TOOL_CALLS_FIX);
        assert_eq!(result.text, "done");
        assert_eq!(
            result.session_id.as_deref(),
            Some("01a1653e-f945-7f52-a4aa-139bcbf0e597")
        );
        assert_eq!(result.is_error, Some(false));
        assert!(result.clean_exit);
        let usage = result.usage.unwrap();
        assert_eq!(usage.input_tokens, 33_189.0);
        assert_eq!(usage.cache_read_tokens, 64_610.0);
        assert_eq!(usage.output_tokens, 213.0);
        assert_eq!(usage.cache_write_tokens, 0.0);
        assert_eq!(usage.allowance, None);
        assert_eq!(result.cost_usd, None);
        assert_eq!(result.provider_status, None);
    }

    #[test]
    fn resume_fixtures_keep_the_session_and_usage_for_each_turn() {
        let first = parse_fixture(RESUME_FIRST);
        let answer = parse_fixture(RESUME_ANSWER);
        assert_eq!(first.text, "ok");
        assert_eq!(answer.text, "4417");
        assert_eq!(first.session_id, answer.session_id);
        assert_eq!(
            answer.session_id.as_deref(),
            Some("ebc0e1b6-e7cd-42a5-a350-b4326fbc9d90")
        );
        assert_eq!(answer.usage.as_ref().unwrap().input_tokens, 113.0);
        assert_eq!(answer.usage.as_ref().unwrap().cache_read_tokens, 32_753.0);
        assert_eq!(answer.usage.as_ref().unwrap().output_tokens, 188.0);
    }

    #[test]
    fn bad_model_fixture_fails_closed_without_agent_text() {
        let result = parse_fixture(BAD_MODEL);
        assert_eq!(result.is_error, Some(true));
        assert_eq!(result.text, "muse: no model evidence in run.usage");
        assert_eq!(
            result.session_id.as_deref(),
            Some("01a1653f-ca82-7951-8f76-d61aefdad36f")
        );
        let usage = result.usage.unwrap();
        assert_eq!(usage.input_tokens, 0.0);
        assert_eq!(usage.output_tokens, 0.0);
        assert_eq!(usage.cache_read_tokens, 0.0);
        assert_eq!(
            derive_status(&result.text, result.is_error, true),
            RunStatus::Error
        );
    }

    #[test]
    fn allowance_from_sandbox_capture_is_normalized() {
        let result = parse_fixture(SANDBOX_ALLOWANCE);
        let allowance = result.usage.unwrap().allowance.unwrap();
        let window = allowance.window.unwrap();
        assert_eq!(window.used_percent, 0.0);
        assert_eq!(window.resets_at_ms, 1_792_728_796_000.0);
        let weekly = allowance.weekly.unwrap();
        assert_eq!(weekly.used_percent, 0.0);
        assert_eq!(weekly.resets_at_ms, 1_792_972_800_000.0);
        assert_eq!(allowance.as_of_ms, Some(1_792_711_757_414.0));
    }

    #[test]
    fn model_evidence_requires_every_model_to_match_and_rejects_empty_evidence() {
        let mut records = json_records(TOOL_CALLS_FIX);
        let usage = record_mut(&mut records, "run.usage");
        usage["payload"]["models"] = json!([
            {"model": "other-model"},
            {"model": MODEL}
        ]);
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.is_error, Some(true));
        assert_eq!(
            result.text,
            "muse: model mismatch: requested muse-spark-1.3-contributor, run.usage reported [other-model, muse-spark-1.3-contributor]"
        );

        let mut records = json_records(TOOL_CALLS_FIX);
        record_mut(&mut records, "run.usage")["payload"]["models"] = json!([]);
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.is_error, Some(true));
        assert_eq!(result.text, "muse: no model evidence in run.usage");

        for models in [json!([{}]), json!([{"model": null}])] {
            let mut records = json_records(TOOL_CALLS_FIX);
            record_mut(&mut records, "run.usage")["payload"]["models"] = models;
            let result = parse_fixture(&encode_records(&records));
            assert_eq!(result.is_error, Some(true));
            assert_eq!(
                result.text,
                "muse: model mismatch: requested muse-spark-1.3-contributor, run.usage reported [?]"
            );
        }
    }

    #[test]
    fn failed_calls_zero_or_absent_is_success_and_one_is_error() {
        for (failed_calls, expected_error, expected_text) in [
            (Some(0), false, "done"),
            (None, false, "done"),
            (Some(1), true, "done"),
        ] {
            let mut records = json_records(TOOL_CALLS_FIX);
            let usage = record_mut(&mut records, "run.usage");
            if let Some(failed_calls) = failed_calls {
                usage["payload"]["failed_calls"] = json!(failed_calls);
            } else {
                usage["payload"]
                    .as_object_mut()
                    .unwrap()
                    .remove("failed_calls");
            }
            let result = parse_fixture(&encode_records(&records));
            assert_eq!(result.is_error, Some(expected_error));
            assert_eq!(result.text, expected_text);
            assert_eq!(
                result.stderr.contains("muse: 1 failed model call(s)"),
                failed_calls == Some(1)
            );
        }
    }

    #[test]
    fn failed_model_call_keeps_a_status_line_in_the_answer() {
        let mut records = json_records(TOOL_CALLS_FIX);
        record_mut(&mut records, "run.terminal.completed")["payload"]["text"] =
            json!("needs the file path\nSTATUS: NEEDS_CONTEXT");
        record_mut(&mut records, "run.usage")["payload"]["failed_calls"] = json!(1);
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.text, "needs the file path\nSTATUS: NEEDS_CONTEXT");
        assert_eq!(result.is_error, Some(true));
        assert_eq!(
            result.session_id.as_deref(),
            Some("01a1653e-f945-7f52-a4aa-139bcbf0e597")
        );
        assert!(result.stderr.contains("muse: 1 failed model call(s)"));
        assert_eq!(
            derive_status(&result.text, result.is_error, true),
            RunStatus::NeedsContext
        );
    }

    #[test]
    fn failed_model_call_without_a_status_line_stays_error_with_the_answer() {
        let mut records = json_records(TOOL_CALLS_FIX);
        record_mut(&mut records, "run.usage")["payload"]["failed_calls"] = json!(1);
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.text, "done");
        assert_eq!(result.is_error, Some(true));
        assert!(result.stderr.contains("muse: 1 failed model call(s)"));
        assert_eq!(
            derive_status(&result.text, result.is_error, true),
            RunStatus::Error
        );
    }

    #[test]
    fn terminal_state_and_reason_are_diagnostic_only() {
        for (reason, expected) in [
            (None, "muse: run ended \"failed\""),
            (Some("x"), "muse: run ended \"failed\" (reason \"x\")"),
        ] {
            let mut records = json_records(TOOL_CALLS_FIX);
            let terminal = record_mut(&mut records, "run.terminal.completed");
            terminal["payload_type"] = json!("run.terminal.failed");
            terminal["payload"]["terminal"] = json!("failed");
            terminal["payload"]["reason"] = reason.map_or(Value::Null, |value| json!(value));
            let result = parse_fixture(&encode_records(&records));
            assert_eq!(result.is_error, Some(true));
            assert_eq!(result.text, expected);
        }
    }

    #[test]
    fn absent_terminal_or_usage_fails_closed() {
        let mut records = json_records(TOOL_CALLS_FIX);
        records.retain(|record| {
            !record["payload_type"]
                .as_str()
                .unwrap_or_default()
                .starts_with("run.terminal.")
        });
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.text, "muse: no terminal record");
        assert_eq!(result.is_error, Some(true));

        let mut records = json_records(TOOL_CALLS_FIX);
        records.retain(|record| record["payload_type"] != "run.usage");
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.text, "muse: no model evidence in run.usage");
        assert_eq!(result.is_error, Some(true));
        assert_eq!(result.usage, None);
    }

    #[test]
    fn cached_tokens_never_make_input_usage_negative_at_or_around_the_boundary() {
        for (input, cached, expected) in [(5, 4, 1.0), (5, 5, 0.0), (5, 6, 0.0)] {
            let mut records = json_records(TOOL_CALLS_FIX);
            let usage = record_mut(&mut records, "run.usage");
            usage["payload"]["models"] = json!([{
                "model": MODEL,
                "input_tokens": input,
                "cached_tokens": cached,
                "output_tokens": 7
            }]);
            let result = parse_fixture(&encode_records(&records));
            assert_eq!(result.usage.unwrap().input_tokens, expected);
        }
    }

    #[test]
    fn allowance_windows_that_are_null_or_malformed_are_omitted_independently() {
        let mut records = json_records(SANDBOX_ALLOWANCE);
        let payload = &mut record_mut(&mut records, "run.usage")["payload"];
        payload["allowance"]["window"] = Value::Null;
        payload["allowance"]["weekly"]["used_percent"] = json!("not-a-number");
        let result = parse_fixture(&encode_records(&records));
        let allowance = result.usage.unwrap().allowance.unwrap();
        assert_eq!(allowance.window, None);
        assert_eq!(allowance.weekly, None);
        assert_eq!(allowance.as_of_ms, Some(1_792_711_757_414.0));
    }

    #[test]
    fn usage_calls_are_optional_and_bad_numbers_do_not_discard_other_fields() {
        let mut records = json_records(TOOL_CALLS_FIX);
        let usage = record_mut(&mut records, "run.usage");
        usage["payload"].as_object_mut().unwrap().remove("calls");
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.is_error, Some(false));

        let mut records = json_records(TOOL_CALLS_FIX);
        record_mut(&mut records, "run.usage")["payload"]["calls"] = json!(-1);
        let _ = parse_fixture(&encode_records(&records));

        let mut records = json_records(TOOL_CALLS_FIX);
        let usage = record_mut(&mut records, "run.usage");
        usage["payload"]["models"][0]["input_tokens"] = json!("not-a-number");
        let result = parse_fixture(&encode_records(&records));
        let usage = result.usage.unwrap();
        assert_eq!(usage.input_tokens, 0.0);
        assert_eq!(usage.cache_read_tokens, 64_610.0);
        assert_eq!(usage.output_tokens, 213.0);
    }

    #[test]
    fn the_last_run_usage_record_supplies_the_result_usage() {
        let mut records = json_records(TOOL_CALLS_FIX);
        let mut duplicate = record_mut(&mut records, "run.usage").clone();
        duplicate["payload"]["models"] = json!([{
            "model": MODEL,
            "input_tokens": 31,
            "cached_tokens": 7,
            "output_tokens": 11
        }]);
        duplicate["payload"]["calls"] = json!(8);
        duplicate["payload"]["failed_calls"] = json!(0);
        records.push(duplicate);
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.is_error, Some(false));
        let usage = result.usage.unwrap();
        assert_eq!(usage.input_tokens, 24.0);
        assert_eq!(usage.cache_read_tokens, 7.0);
        assert_eq!(usage.output_tokens, 11.0);
    }

    #[test]
    fn unknown_and_unparseable_lines_and_failed_task_records_are_ignored() {
        let mut records = json_records(TOOL_CALLS_FIX);
        record_mut(&mut records, "task.lifecycle.completed")["payload_type"] =
            json!("task.lifecycle.failed");
        let stream = format!(
            "muse: startup banner\nnot-json\n{{\"not_an_envelope\":true}}\n{}",
            encode_records(&records)
        );
        let result = parse_fixture(&stream);
        assert_eq!(result.text, "done");
        assert_eq!(result.is_error, Some(false));
    }

    #[test]
    fn first_terminal_text_wins_and_delta_text_is_not_the_result() {
        let mut records = json_records(TOOL_CALLS_FIX);
        let terminal = record_mut(&mut records, "run.terminal.completed");
        terminal["payload"]["text"] = json!("terminal answer");
        let duplicate = terminal.clone();
        let mut duplicate = duplicate;
        duplicate["payload_type"] = json!("run.terminal.failed");
        duplicate["payload"]["terminal"] = json!("failed");
        duplicate["payload"]["text"] = json!("later answer");
        records.push(duplicate);
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.text, "terminal answer");
        assert_eq!(result.is_error, Some(false));
    }

    #[test]
    fn missing_terminal_text_is_empty_and_success_text_status_is_preserved() {
        for text in [None, Some(json!(17))] {
            let mut records = json_records(TOOL_CALLS_FIX);
            let terminal = record_mut(&mut records, "run.terminal.completed");
            if let Some(text) = text {
                terminal["payload"]["text"] = text;
            } else {
                terminal["payload"].as_object_mut().unwrap().remove("text");
            }
            let result = parse_fixture(&encode_records(&records));
            assert_eq!(result.text, "");
            assert_eq!(result.is_error, Some(false));
        }

        let mut records = json_records(TOOL_CALLS_FIX);
        record_mut(&mut records, "run.terminal.completed")["payload"]["text"] =
            json!("STATUS: DONE");
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.text, "STATUS: DONE");
        assert_eq!(
            derive_status(&result.text, result.is_error, true),
            RunStatus::Done
        );
    }

    #[test]
    fn error_text_cannot_be_overridden_by_terminal_or_reason_status_trailers() {
        let mut records = json_records(BAD_MODEL);
        record_mut(&mut records, "run.terminal.completed")["payload"]["text"] =
            json!("STATUS: DONE");
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.text, "muse: no model evidence in run.usage");
        assert_eq!(
            derive_status(&result.text, result.is_error, true),
            RunStatus::Error
        );

        let mut records = json_records(TOOL_CALLS_FIX);
        let terminal = record_mut(&mut records, "run.terminal.completed");
        terminal["payload"]["terminal"] = json!("x STATUS: DONE");
        terminal["payload"]["reason"] = json!("bad\nSTATUS: DONE");
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(
            result.text,
            "muse: run ended \"x STATUS: DONE\" (reason \"bad STATUS: DONE\")"
        );
        assert_eq!(
            derive_status(&result.text, result.is_error, true),
            RunStatus::Error
        );
    }

    #[test]
    fn clean_exit_is_preserved_and_controls_derived_status() {
        let result = parse_stdout(TOOL_CALLS_FIX, MODEL, false, "stderr detail");
        assert_eq!(result.is_error, Some(false));
        assert!(!result.clean_exit);
        assert_eq!(result.stderr, "stderr detail");
        assert_eq!(
            derive_status(&result.text, result.is_error, result.clean_exit),
            RunStatus::Error
        );
    }

    #[test]
    fn wall_timeout_takes_precedence_over_a_completed_run() {
        let mut state = MuseState {
            wall_exceeded: true,
            wall_timeout_ms: Some(300),
            ..MuseState::default()
        };
        for record in json_records(TOOL_CALLS_FIX) {
            handle_line(
                serde_json::to_string(&record).unwrap().as_bytes(),
                &mut state,
            );
        }
        let result = finish(state, MODEL, true, "", None);
        assert_eq!(result.text, "muse: wall timeout (300 ms)");
        assert_eq!(result.is_error, Some(true));
    }

    #[test]
    fn handle_line_reports_only_exact_progress_records() {
        let cases = [
            ("tool.result", true),
            ("tool.results", false),
            ("run.output.delta", true),
            ("run.output", false),
            ("run.terminal.completed", true),
            ("run.terminal.failed", true),
            ("run.terminal", false),
            ("task.stream.linked", false),
            ("task.lifecycle.proposed", false),
        ];
        for (payload_type, expected) in cases {
            let mut state = MuseState::default();
            let payload = if payload_type == "task.stream.linked" {
                json!({"task_id":"not-yet-seen"})
            } else if payload_type == "task.lifecycle.proposed" {
                json!({"event":{"task_kind":"model.meta.response"}})
            } else if payload_type == "task.lifecycle.started" {
                json!({"event":{"task_kind":"tool.bash"}})
            } else {
                json!({})
            };
            assert_eq!(
                handle_line(&line(payload_type, payload), &mut state),
                expected,
                "{payload_type}"
            );
            assert_ne!(state.phase.as_deref(), Some("running_tool"));
        }

        let mut state = MuseState::default();
        assert!(!handle_line(
            &line(
                "task.lifecycle.started",
                json!({"event":{"task_kind":"tool.bash"}})
            ),
            &mut state
        ));
    }

    #[test]
    fn progress_records_update_assistant_tool_and_session_snapshots() {
        for (length, expected_length) in [(199, 199), (200, 200), (201, 200)] {
            let mut state = MuseState::default();
            let text = "x".repeat(length);
            assert!(handle_line(
                &line("run.output.delta", json!({"text":text})),
                &mut state
            ));
            let expected_text = text.chars().take(expected_length).collect::<String>();
            assert_eq!(
                state.last_assistant.as_deref(),
                Some(expected_text.as_str())
            );
            assert_eq!(state.phase.as_deref(), Some("responding"));
        }

        let mut state = MuseState {
            phase: Some("responding".into()),
            ..MuseState::default()
        };
        assert!(handle_line(
            &line(
                "tool.result",
                json!({"correlation_facts":{"tool_name":"read_file"}})
            ),
            &mut state
        ));
        assert_eq!(state.last_tool.as_deref(), Some("read_file"));
        assert_eq!(state.phase.as_deref(), Some("responding"));

        let session_line = json!({
            "stream":{"kind":"session","id":"first-session-id"},
            "payload_type":"task.lifecycle.started",
            "payload":{}
        })
        .to_string();
        assert!(!handle_line(session_line.as_bytes(), &mut state));
        assert_eq!(state.session_id.as_deref(), Some("first-session-id"));
        let second_session_line = json!({
            "stream":{"kind":"session","id":"later-session-id"},
            "payload_type":"run.lifecycle.started",
            "payload":{}
        })
        .to_string();
        assert!(!handle_line(second_session_line.as_bytes(), &mut state));
        assert_eq!(state.session_id.as_deref(), Some("first-session-id"));

        let mut state = MuseState::default();
        let other_stream = json!({
            "id":"envelope-id",
            "stream":{"kind":"run","id":"run-id"},
            "payload_type":"run.lifecycle.started",
            "payload":{}
        })
        .to_string();
        assert!(!handle_line(other_stream.as_bytes(), &mut state));
        let result = finish(state, MODEL, true, "", Some("launched-session-id"));
        assert_eq!(result.session_id.as_deref(), Some("launched-session-id"));
    }

    #[test]
    fn synthetic_reminder_loop_never_counts_as_progress_or_returns_a_result() {
        // Synthetic fixture: repeating reminder task lifecycle records without tool results or model output.
        let mut state = MuseState::default();
        for record in json_records(REMINDER_STALL) {
            assert!(!handle_line(
                serde_json::to_string(&record).unwrap().as_bytes(),
                &mut state
            ));
            assert_ne!(state.phase.as_deref(), Some("running_tool"));
        }

        let result = parse_fixture(REMINDER_STALL);
        assert_eq!(result.is_error, Some(true));
        assert_eq!(result.text, "muse: no terminal record");
        assert_eq!(
            result.session_id.as_deref(),
            Some("01a1653f-ca82-7951-8f76-d61aefdad36f")
        );
        assert_eq!(result.usage, None);
    }

    // Process-env mutation serialises on the shared #681 helper: `MUSE_BIN`,
    // `HOME` and `TMPDIR` are process-global and the spawn tests each point
    // them at their own fake.
    static FAKE_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    fn fake_muse_script(dir: &std::path::Path, body: &str) -> std::path::PathBuf {
        let path = dir.join("muse.sh");
        std::fs::write(&path, body).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn scratch_dir(name: &str) -> std::path::PathBuf {
        let id = FAKE_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("muse-{name}-{}-{id}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("repo")).unwrap();
        dir
    }

    fn job_spec(bin: &str, argv: Vec<String>, cwd: &str) -> crate::types::JobSpec {
        crate::types::JobSpec {
            bin: bin.to_string(),
            argv,
            cwd: cwd.to_string(),
            model: "muse/muse-spark-1.3-contributor".to_string(),
            backend: "muse".to_string(),
            path: None,
            head_before: None,
            gate: String::new(),
            idle_ms: None,
            tool_idle_ms: None,
            wall_ms: None,
            price_map: std::collections::HashMap::new(),
            resume_context: crate::types::ResumeContext {
                model: "muse/muse-spark-1.3-contributor".to_string(),
                gate: String::new(),
            },
        }
    }

    #[test]
    fn staging_argv_uses_the_model_and_avoids_host_flags() {
        let first = argv("muse/muse-spark-1.3-contributor", None, "hi");
        assert!(first.iter().any(|arg| arg == "muse-spark-1.3-contributor"));
        let resume = argv("muse/muse-spark-1.3-contributor", Some("S"), "hi");
        assert!(resume.iter().any(|arg| arg == "S"));

        // The staging form never carries sandbox or workspace flags, nor `--yolo`.
        for staging in [first, resume] {
            assert!(!staging.iter().any(|a| a == "--yolo"));
            assert!(!staging.iter().any(|a| a == "--disable-sandbox"));
            assert!(!staging.iter().any(|a| a == "--workspace"));
        }

        // Only one leading `muse/` is stripped.
        let nested = argv("muse/muse/x", None, "hi");
        assert!(nested.iter().any(|arg| arg == "muse/x"));
    }

    #[test]
    fn effort_suffix_is_split_only_when_it_is_a_muse_level() {
        assert_eq!(
            base_and_effort("muse/muse-spark-1.3-contributor:high"),
            ("muse-spark-1.3-contributor", Some("high"))
        );
        assert_eq!(
            base_and_effort("muse/muse-spark-1.3-contributor"),
            ("muse-spark-1.3-contributor", None)
        );
        // A colon that is not a Muse level stays in the model name.
        assert_eq!(
            base_and_effort("muse/muse-spark:beta"),
            ("muse-spark:beta", None)
        );
        // Only one leading `muse/` is stripped; the suffix is read after it.
        assert_eq!(
            base_and_effort("muse/muse/x:ultra"),
            ("muse/x", Some("ultra"))
        );
    }

    #[test]
    fn effort_flag_is_sent_only_when_the_id_carries_a_level() {
        let suffixed = argv("muse/muse-spark-1.3-contributor:high", None, "hi");
        let pair = suffixed
            .windows(2)
            .find(|w| w[0] == "--reasoning-effort")
            .expect("--reasoning-effort");
        assert_eq!(pair[1], "high");
        assert!(suffixed.iter().any(|a| a == "muse-spark-1.3-contributor"));
        assert!(!suffixed.iter().any(|a| a.contains(':')));

        let bare = argv("muse/muse-spark-1.3-contributor", Some("S"), "hi");
        assert!(!bare.iter().any(|a| a == "--reasoning-effort"), "{bare:?}");
        assert!(!bare.iter().any(|a| a == "low"), "{bare:?}");
    }

    #[test]
    fn spawn_strips_the_effort_suffix_from_the_child_model_and_its_evidence() {
        let _lock = crate::test_env::lock();
        let dir = scratch_dir("spawn-effort");
        let _home = EnvGuard::set("HOME", dir.to_str().unwrap());
        let _tmp = EnvGuard::set("TMPDIR", dir.to_str().unwrap());
        let fixture = dir.join("tool-calls-fix.stdout");
        std::fs::write(&fixture, TOOL_CALLS_FIX).unwrap();
        let argv_record = dir.join("argv.txt");
        let fake = fake_muse_script(
            &dir,
            &format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}\ncat {}\n",
                argv_record.display(),
                fixture.display()
            ),
        );
        let _bin = EnvGuard::set("MUSE_BIN", fake.to_str().unwrap());
        let cwd = dir.join("repo").to_string_lossy().into_owned();
        let model = "muse/muse-spark-1.3-contributor:high";
        let mut spec = job_spec(&resolve_bin(None), argv(model, None, "hi"), &cwd);
        spec.model = model.to_string();

        let spawned = spawn(&spec);
        let result = (spawned.drive)(&|_| {});
        // The fixture reports the bare model, so evidence matches only when the suffix is stripped.
        assert_eq!(result.is_error, Some(false), "{}", result.text);

        let recorded: Vec<String> = std::fs::read_to_string(&argv_record)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        let model_at = recorded.iter().position(|a| a == "--model").unwrap();
        assert_eq!(recorded[model_at + 1], "muse-spark-1.3-contributor");
        let effort_at = recorded
            .iter()
            .position(|a| a == "--reasoning-effort")
            .unwrap();
        assert_eq!(recorded[effort_at + 1], "high");
    }

    #[test]
    fn trust_workspace_is_on_fresh_and_resumed_runs() {
        let fresh = argv("muse/muse-spark-1.3-contributor", None, "hi");
        let resumed = argv("muse/muse-spark-1.3-contributor", Some("S"), "hi");
        for staging in [fresh, resumed] {
            assert!(staging.iter().any(|a| a == "--trust-workspace"));
        }
    }

    #[test]
    fn lowering_carries_the_workspace_and_prompt() {
        let staging = argv("muse/muse-spark-1.3-contributor", Some("S"), "hi");
        let wire = lower(&staging, "/work/repo");
        for expected in ["--workspace", "/work/repo", "--", "hi"] {
            assert!(wire.iter().any(|arg| arg == expected));
        }
    }

    #[test]
    fn backend_dispatch_reaches_the_muse_backend() {
        let backend = crate::backends::Backend::from_name("muse");
        assert_eq!(backend, Some(crate::backends::Backend::Muse));
        assert_eq!(backend.unwrap().name(), "muse");
        let staging = backend.unwrap().argv("muse/m", Some("s"), "hi");
        assert!(staging.iter().any(|arg| arg == "exec"));
        assert!(staging.iter().any(|arg| arg == "s"));
    }

    #[test]
    fn binary_resolution_prefers_override_then_env() {
        let _lock = crate::test_env::lock();
        assert_eq!(resolve_bin(Some("/custom/muse")), "/custom/muse");
        let _guard = EnvGuard::set("MUSE_BIN", "/env/muse");
        assert_eq!(resolve_bin(None), "/env/muse");
    }

    #[test]
    fn spawn_runs_the_lowered_wire_argv_and_reports_the_fixture_result() {
        let _lock = crate::test_env::lock();
        let dir = scratch_dir("spawn");
        let _home = EnvGuard::set("HOME", dir.to_str().unwrap());
        let _tmp = EnvGuard::set("TMPDIR", dir.to_str().unwrap());
        let fixture = dir.join("tool-calls-fix.stdout");
        std::fs::write(&fixture, TOOL_CALLS_FIX).unwrap();
        let argv_record = dir.join("argv.txt");
        let fake = fake_muse_script(
            &dir,
            &format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}\ncat {}\n",
                argv_record.display(),
                fixture.display()
            ),
        );
        let _bin = EnvGuard::set("MUSE_BIN", fake.to_str().unwrap());
        let cwd = dir.join("repo").to_string_lossy().into_owned();
        let staging = argv("muse/muse-spark-1.3-contributor", None, "hi");
        let spec = job_spec(&resolve_bin(None), staging.clone(), &cwd);
        assert_eq!(spec.bin, fake.to_str().unwrap());

        let spawned = spawn(&spec);
        let launched = spawned.session_id.clone().expect("launch session");
        assert!(!launched.is_empty());
        assert!(staging.iter().any(|arg| arg == &launched));
        // The fake ignores stdin (null) and exits at once: the drive returns.
        let result = (spawned.drive)(&|_| {});
        assert_eq!(result.text, "done");
        assert_eq!(result.is_error, Some(false));
        assert_eq!(
            result.session_id.as_deref(),
            Some("01a1653e-f945-7f52-a4aa-139bcbf0e597")
        );
        assert!(result.clean_exit);

        let recorded: Vec<String> = std::fs::read_to_string(&argv_record)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        for expected in ["--workspace", cwd.as_str(), "--", "hi"] {
            assert!(recorded.iter().any(|arg| arg == expected));
        }
        assert!(!recorded.iter().any(|a| a == "--disable-sandbox"));
    }

    #[test]
    fn sandbox_switch_adds_disable_flag_when_off() {
        let staging = argv("muse/muse-spark-1.3-contributor", Some("S"), "hi");
        let on = with_sandbox(staging.clone(), true);
        assert!(!on.iter().any(|arg| arg == "--disable-sandbox"));
        let off = with_sandbox(staging, false);
        assert!(off.iter().any(|arg| arg == "--disable-sandbox"));
    }

    #[test]
    fn spawn_failure_is_an_error_result() {
        let spec = job_spec("/nonexistent/muse-xyz", vec!["exec".into()], "/tmp");
        let spawned = spawn(&spec);
        assert!(spawned.session_id.is_none());
        (spawned.kill)();
        let result = (spawned.drive)(&|_| {});
        assert!(!result.clean_exit);
        assert_eq!(result.is_error, Some(true));
        assert!(!result.text.is_empty());
    }

    #[test]
    fn wall_cap_comes_from_the_spec_or_the_default_and_disables_on_null() {
        assert_eq!(wall_cap_ms(None), Some(1_800_000));
        assert_eq!(wall_cap_ms(Some(None)), None);
        assert_eq!(wall_cap_ms(Some(Some(300.0))), Some(300));
    }

    /// Drive a finished stream on a thread and return its events with the
    /// result, failing instead of hanging when the child outlives `timeout`.
    fn drive_with_timeout(
        spawned: crate::backends::types::Spawned,
        timeout: std::time::Duration,
    ) -> (Vec<String>, crate::backends::types::BackendResult) {
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let collected = std::sync::Arc::clone(&events);
        let on = move |event: crate::backends::types::Event| {
            collected.lock().unwrap().push(
                match event {
                    crate::backends::types::Event::Progress(_) => "progress",
                    crate::backends::types::Event::Stderr => "stderr",
                    crate::backends::types::Event::Activity => "activity",
                }
                .to_string(),
            );
        };
        let drive = spawned.drive;
        let kill = spawned.kill;
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(drive(&on));
        });
        let result = match rx.recv_timeout(timeout) {
            Ok(result) => result,
            Err(_) => {
                kill();
                let _ = rx.recv();
                panic!("drive returned before the deadline");
            }
        };
        kill();
        (events.lock().unwrap().clone(), result)
    }

    #[test]
    fn reminder_loop_delivers_no_event_at_all() {
        let _lock = crate::test_env::lock();
        let dir = scratch_dir("stall-drive");
        let _home = EnvGuard::set("HOME", dir.to_str().unwrap());
        let _tmp = EnvGuard::set("TMPDIR", dir.to_str().unwrap());
        let fake = fake_muse_script(
            &dir,
            &format!("#!/bin/sh\ncat {}\n", dir.join("fixture.stdout").display()),
        );
        std::fs::write(dir.join("fixture.stdout"), REMINDER_STALL).unwrap();
        let _bin = EnvGuard::set("MUSE_BIN", fake.to_str().unwrap());
        let cwd = dir.join("repo").to_string_lossy().into_owned();
        let spec = job_spec(&resolve_bin(None), argv("muse/m", None, "hi"), &cwd);
        let spawned = spawn(&spec);
        // Receiving the result is the drain barrier: the fake exited only
        // after stdout reached EOF and every fixture record was processed.
        let (events, result) = drive_with_timeout(spawned, std::time::Duration::from_secs(8));
        assert!(events.is_empty(), "{events:?}");
        assert_eq!(result.text, "muse: no terminal record");
    }

    #[test]
    fn progress_run_delivers_only_progress_events() {
        let _lock = crate::test_env::lock();
        let dir = scratch_dir("progress-drive");
        let _home = EnvGuard::set("HOME", dir.to_str().unwrap());
        let _tmp = EnvGuard::set("TMPDIR", dir.to_str().unwrap());
        std::fs::write(dir.join("fixture.stdout"), TOOL_CALLS_FIX).unwrap();
        let fake = fake_muse_script(
            &dir,
            &format!("#!/bin/sh\ncat {}\n", dir.join("fixture.stdout").display()),
        );
        let _bin = EnvGuard::set("MUSE_BIN", fake.to_str().unwrap());
        let cwd = dir.join("repo").to_string_lossy().into_owned();
        let spec = job_spec(&resolve_bin(None), argv("muse/m", None, "hi"), &cwd);
        let spawned = spawn(&spec);
        let (events, result) = drive_with_timeout(spawned, std::time::Duration::from_secs(10));
        assert!(!events.is_empty());
        assert!(events.iter().all(|e| e == "progress"), "{events:?}");
        assert_eq!(result.text, "done");
    }

    #[test]
    fn stderr_only_child_hits_the_wall_cap_without_stdout() {
        let _lock = crate::test_env::lock();
        let dir = scratch_dir("wall-drive");
        let _home = EnvGuard::set("HOME", dir.to_str().unwrap());
        let _tmp = EnvGuard::set("TMPDIR", dir.to_str().unwrap());
        let fake = fake_muse_script(
            &dir,
            "#!/bin/sh\nprintf '%s\\n' 'muse: still running' >&2\nexec tail -f /dev/null\n",
        );
        let _bin = EnvGuard::set("MUSE_BIN", fake.to_str().unwrap());
        let cwd = dir.join("repo").to_string_lossy().into_owned();
        let mut spec = job_spec(&resolve_bin(None), argv("muse/m", None, "hi"), &cwd);
        spec.tool_idle_ms = Some(Some(300.0));
        let spawned = spawn(&spec);
        let (events, result) = drive_with_timeout(spawned, std::time::Duration::from_secs(10));
        assert!(events.is_empty(), "{events:?}");
        assert_eq!(result.text, "muse: wall timeout (300 ms)");
        assert_eq!(result.is_error, Some(true));
    }
}
