//! Parser for `muse exec --json` output. Parsing is fail-closed: success requires
//! a completed terminal record, usage evidence for the requested model and no failed calls.

use super::types::BackendResult;
use crate::types::{Allowance, AllowanceWindow, Usage};
use serde_json::Value;

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

/// Fold one JSONL record into parser state and report only meaningful progress.
fn handle_line(line: &[u8], state: &mut MuseState) -> bool {
    let line = String::from_utf8_lossy(line);
    let Ok(record) = serde_json::from_str::<Value>(line.trim()) else {
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
                        Some(format!("muse: {failed_calls} failed model call(s)"))
                    } else {
                        None
                    }
                }
            }
        } else {
            Some("muse: no model evidence in run.usage".to_string())
        }
    };

    if let Some(text) = diagnostic {
        return error_result(text, session_id, usage, clean_exit, stderr);
    }

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
        is_error: Some(false),
        duration_ms: None,
        clean_exit,
        stderr: stderr.to_string(),
        permission_denials: Vec::new(),
        provider_status: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::output::derive_status;
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
        assert_eq!(usage.calls, Some(3));
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
        assert_eq!(answer.usage.as_ref().unwrap().calls, Some(1));
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
        assert_eq!(usage.calls, Some(0));
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
            (Some(1), true, "muse: 1 failed model call(s)"),
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
        }
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
        assert_eq!(result.usage.as_ref().unwrap().calls, None);

        let mut records = json_records(TOOL_CALLS_FIX);
        record_mut(&mut records, "run.usage")["payload"]["calls"] = json!(-1);
        let result = parse_fixture(&encode_records(&records));
        assert_eq!(result.usage.as_ref().unwrap().calls, None);

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
        assert_eq!(usage.calls, Some(8));
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
            assert_eq!(
                state.last_assistant.as_deref().unwrap().chars().count(),
                expected_length
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

        let success_records = json_records(TOOL_CALLS_FIX);
        assert_eq!(json_records(REMINDER_STALL).len(), success_records.len());
        let mut progress_count = 0;
        let mut success_state = MuseState::default();
        for record in success_records {
            progress_count += usize::from(handle_line(
                serde_json::to_string(&record).unwrap().as_bytes(),
                &mut success_state,
            ));
        }
        assert!(progress_count > 0);

        let result = parse_fixture(REMINDER_STALL);
        assert_eq!(result.is_error, Some(true));
        assert_eq!(result.text, "muse: no terminal record");
        assert_eq!(
            result.session_id.as_deref(),
            Some("01a1653f-ca82-7951-8f76-d61aefdad36f")
        );
        assert_eq!(result.usage, None);
    }
}
