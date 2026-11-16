use crate::backends::fiber::hub::{self, HubSession, HubSessionLine};
use crate::session::msp;
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::time::Duration;

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}

/// How long the bridge waits for Fiber to exit after `close` with `now`.
pub(crate) const CLOSE_NOW_WAIT: Duration = Duration::from_secs(1);

pub fn main(args: &[String]) -> i32 {
    let Some(model) = args
        .windows(2)
        .find(|pair| pair[0] == "--model")
        .map(|pair| pair[1].clone())
    else {
        eprintln!("Fiber session host requires --model");
        return 2;
    };
    let cwd = std::env::current_dir()
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_default();
    let socket = match hub::fiber_home().and_then(|home| hub::hub_socket_path(&home)) {
        Ok(socket) => socket,
        Err(error) => {
            eprintln!("{error}");
            return 1;
        }
    };
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    let mut session: Option<HubSession> = None;
    let mut session_id = String::new();
    let mut running = false;
    let (input_tx, input_rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if input_tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut idle_exited = false;
    loop {
        if let Some(link) = session.as_ref() {
            while let Some(message) = link.try_recv() {
                match message {
                    HubSessionLine::Line(line) => {
                        if let Ok(event) = serde_json::from_str::<Value>(&line) {
                            let kind = event.get("kind").and_then(Value::as_str).unwrap_or("");
                            if kind == "turn_started" {
                                running = true;
                                idle_exited = false;
                            }
                            if kind == "turn_completed" {
                                running = false;
                            }
                            if kind == "fiber_exited" {
                                idle_exited = !running;
                                if idle_exited {
                                    emit_idle_exit(&mut stdout);
                                } else {
                                    emit_event(&mut stdout, &event);
                                }
                            } else {
                                emit_event(&mut stdout, &event);
                            }
                        }
                    }
                    HubSessionLine::Lost(error) => {
                        eprintln!("{error}");
                        return 1;
                    }
                    HubSessionLine::Ready(_) => {}
                }
            }
        }
        let line = match input_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(line) => line,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        };
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(id) = value.get("id").and_then(Value::as_i64) else {
            continue;
        };
        let method = value
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let params = value.get("params").cloned().unwrap_or(Value::Null);
        let result = match method {
            "initialize" => Ok(json!({"protocolVersion":1})),
            "session/start" => {
                let cwd = params
                    .get("workspaceRoot")
                    .and_then(Value::as_str)
                    .unwrap_or(&cwd)
                    .to_string();
                let link = hub::spawn_session(model.clone(), cwd, PathBuf::from(&socket));
                match link.recv(Duration::from_secs(60)) {
                    Ok(HubSessionLine::Ready(id)) => {
                        session_id = id.clone();
                        session = Some(link);
                        Ok(json!({"session":{"sessionId":id}}))
                    }
                    Ok(HubSessionLine::Lost(error)) | Err(error) => Err((-32000, error)),
                    Ok(HubSessionLine::Line(_)) => {
                        Err((-32000, "unexpected hub startup line".into()))
                    }
                }
            }
            "turn/start" | "turn/steer" => {
                let Some(link) = session.as_ref() else {
                    write_error(&mut stdout, id, -32000, "session is not started");
                    continue;
                };
                let text = params
                    .get("input")
                    .and_then(Value::as_array)
                    .and_then(|a| a.first())
                    .and_then(|v| v.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let command_id = params
                    .get("commandId")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let steering = should_steer(method, running);
                let make_command = |steer: bool| {
                    let raw = if steer {
                        hub::steer_command(&command_id, &session_id, text)
                    } else {
                        hub::prompt_command(&command_id, &session_id, text)
                    };
                    serde_json::from_str::<Value>(&raw).unwrap_or(Value::Null)
                };
                let mut steer = steering;
                if link.send(make_command(steer)).is_err() {
                    write_error(&mut stdout, id, -32000, "hub writer stopped");
                    continue;
                }
                match await_disposition(
                    link,
                    &mut stdout,
                    &command_id,
                    id,
                    &mut running,
                    steer,
                    &session_id,
                    text,
                ) {
                    Ok((disposition, turn_id)) => {
                        if disposition == "retry-steer" {
                            steer = true;
                            if link.send(make_command(true)).is_err() {
                                write_error(&mut stdout, id, -32000, "hub writer stopped");
                                continue;
                            }
                            match await_disposition(
                                link,
                                &mut stdout,
                                &command_id,
                                id,
                                &mut running,
                                steer,
                                &session_id,
                                text,
                            ) {
                                Ok((d, tid)) => {
                                    if d == "started" {
                                        idle_exited = false;
                                    }
                                    write_result(
                                        &mut stdout,
                                        id,
                                        json!({"turnId":tid,"disposition":d}),
                                    );
                                }
                                Err((code, message)) => {
                                    write_error(&mut stdout, id, code, &message);
                                    if !message.starts_with("hub rejected")
                                        || message.contains("session_not_found")
                                    {
                                        return 1;
                                    }
                                }
                            }
                        } else {
                            if disposition == "started" {
                                idle_exited = false;
                            }
                            write_result(
                                &mut stdout,
                                id,
                                json!({"turnId":turn_id,"disposition":disposition}),
                            );
                        }
                    }
                    Err((code, message)) => {
                        write_error(&mut stdout, id, code, &message);
                        if !message.starts_with("hub rejected")
                            || message.contains("session_not_found")
                        {
                            return 1;
                        }
                    }
                }
                continue;
            }
            "turn/interrupt" => {
                if let Some(link) = session.as_ref() {
                    let raw = hub::cancel_command(&msp::uuid7(now_ms()), &session_id);
                    let command = serde_json::from_str(&raw).unwrap_or(Value::Null);
                    let _ = link.send(command);
                    Ok(json!({"interrupted":true}))
                } else {
                    Ok(json!({"interrupted":true}))
                }
            }
            "initialized" => continue,
            _ => Ok(Value::Null),
        };
        match result {
            Ok(value) => write_result(&mut stdout, id, value),
            Err((code, message)) => write_error(&mut stdout, id, code, &message),
        }
    }
    if let Some(link) = session.as_ref() {
        while let Some(message) = link.try_recv() {
            if let HubSessionLine::Line(line) = message
                && let Ok(event) = serde_json::from_str::<Value>(&line)
            {
                let kind = event.get("kind").and_then(Value::as_str).unwrap_or("");
                if kind == "turn_completed" {
                    running = false;
                }
                if kind == "fiber_exited" {
                    idle_exited = !running;
                    if idle_exited {
                        emit_idle_exit(&mut stdout);
                    } else {
                        emit_event(&mut stdout, &event);
                    }
                } else {
                    emit_event(&mut stdout, &event);
                }
            }
        }
        if !idle_exited {
            let close_id = msp::uuid7(now_ms());
            let raw = serde_json::json!({"id":close_id,"command":"close","session_id":session_id});
            let _ = link.send(raw);
            if !await_exit(link, &mut stdout, &mut running, stop_grace()) {
                let now = msp::uuid7(now_ms());
                let _ = link.send(serde_json::json!({"id":now,"command":"close","session_id":session_id,"args":{"now":true}}));
                let _ = await_exit(link, &mut stdout, &mut running, CLOSE_NOW_WAIT);
            }
        }
    }
    0
}

fn should_steer(method: &str, running: bool) -> bool {
    method == "turn/steer" && running
}

#[allow(clippy::too_many_arguments)]
fn await_disposition(
    link: &HubSession,
    out: &mut impl Write,
    command_id: &str,
    rpc_id: i64,
    running: &mut bool,
    steer: bool,
    session_id: &str,
    text: &str,
) -> Result<(String, String), (i64, String)> {
    loop {
        let line = match link.recv(Duration::from_secs(120)) {
            Ok(HubSessionLine::Line(line)) => line,
            Ok(HubSessionLine::Lost(error)) | Err(error) => return Err((-32000, error)),
            Ok(HubSessionLine::Ready(_)) => continue,
        };
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let kind = v.get("kind").and_then(Value::as_str).unwrap_or("");
        let payload = v.get("payload").unwrap_or(&Value::Null);
        if kind == "turn_started" {
            let found = payload
                .get("input")
                .and_then(Value::as_array)
                .is_some_and(|a| {
                    a.iter()
                        .any(|i| i.get("command_id").and_then(Value::as_str) == Some(command_id))
                });
            if found {
                emit_event(out, &v);
                *running = true;
                return Ok(("started".into(), envelope_turn_id(&v)));
            }
        }
        if matches!(kind, "steering_applied" | "steering_queue")
            && payload.get("command_id").and_then(Value::as_str) == Some(command_id)
        {
            return Ok(("steered".into(), envelope_turn_id(&v)));
        }
        if kind == "command_rejected"
            && payload.get("command_id").and_then(Value::as_str) == Some(command_id)
        {
            let code = payload
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("rejected");
            if !steer && code == "busy" {
                return Ok(("retry-steer".into(), String::new()));
            }
            return Err((
                -32000,
                format!(
                    "hub rejected {code}: {}",
                    payload.get("message").and_then(Value::as_str).unwrap_or("")
                ),
            ));
        }
        if kind == "turn_completed" {
            *running = false;
        }
        emit_event(out, &v);
        let _ = (rpc_id, session_id, text);
    }
}

/// The `turn_id` from a hub event's envelope, or "" when the event has none.
fn envelope_turn_id(event: &Value) -> String {
    event
        .get("turn_id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .into()
}

fn stop_grace() -> Duration {
    std::env::var("DELEGATE_SESSION_GRACE_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(Duration::from_secs(10))
}

fn await_exit(
    link: &HubSession,
    out: &mut impl Write,
    running: &mut bool,
    grace: Duration,
) -> bool {
    let Some(deadline) = std::time::Instant::now().checked_add(grace) else {
        return false;
    };
    loop {
        let Some(remaining) = deadline.checked_duration_since(std::time::Instant::now()) else {
            return false;
        };
        match link.recv(remaining.min(Duration::from_secs(10))) {
            Ok(HubSessionLine::Line(line)) => {
                let Ok(v) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if v.get("kind").and_then(Value::as_str) == Some("fiber_exited") {
                    return true;
                }
                if v.get("kind").and_then(Value::as_str) == Some("turn_completed") {
                    *running = false;
                }
                emit_event(out, &v);
            }
            Ok(HubSessionLine::Ready(_)) => continue,
            Ok(HubSessionLine::Lost(error)) => {
                eprintln!("{error}");
                return false;
            }
            Err(_) if std::time::Instant::now() >= deadline => return false,
            Err(_) => continue,
        }
    }
}

fn emit_event(out: &mut impl Write, event: &Value) {
    let kind = event.get("kind").and_then(Value::as_str).unwrap_or("");
    let p = event.get("payload").cloned().unwrap_or(Value::Null);
    // Fiber's envelope carries `turn_id`; the payload does not.
    let turn_id = event.get("turn_id");
    let (method, params) = match kind {
        "turn_started" => ("turn/started", json!({"turnId":turn_id})),
        "turn_completed" => (
            "turn/completed",
            json!({"turnId":turn_id,"terminal":match p.get("outcome").and_then(Value::as_str).unwrap_or(""){"completed"=>"completed","interrupted"=>"cancelled",_=>"failed"},"error":p.get("error"),"questions":p.get("questions")}),
        ),
        "user_message" => (
            "item/completed",
            json!({"item":{"kind":"userMessage","turnId":turn_id,"text":p.get("text"),"commandId":p.get("command_id")}}),
        ),
        // One text part of the assistant's reply. A part the provider sent
        // with only opaque data has empty text and is no message.
        "text_completed" if p.get("text").and_then(Value::as_str) != Some("") => (
            "item/completed",
            json!({"item":{"kind":"agentMessage","turnId":turn_id,"text":p.get("text")}}),
        ),
        "tool_started" => (
            "item/started",
            json!({"item":{"kind":"toolCall","turnId":turn_id,"tool":p.get("tool"),"callId":p.get("call_id")}}),
        ),
        "tool_completed" => (
            "item/completed",
            json!({"item":{"kind":"toolCall","turnId":turn_id,"tool":p.get("tool"),"callId":p.get("call_id"),"status":p.get("status")}}),
        ),
        "token_usage" => ("session/tokenUsage", json!({"cumulative":p})),
        "fiber_exited" => ("session/closed", json!({"reason":"stopped"})),
        _ => return,
    };
    let _ = writeln!(
        out,
        "{}",
        json!({"jsonrpc":"2.0","method":method,"params":params})
    );
    let _ = out.flush();
}
fn emit_idle_exit(out: &mut impl Write) {
    let _ = writeln!(
        out,
        "{}",
        json!({"jsonrpc":"2.0","method":"session/exited","params":{"reason":"idle"}})
    );
    let _ = out.flush();
}

fn write_result(out: &mut impl Write, id: i64, result: Value) {
    let _ = writeln!(out, "{}", json!({"jsonrpc":"2.0","id":id,"result":result}));
    let _ = out.flush();
}
fn write_error(out: &mut impl Write, id: i64, code: i64, message: &str) {
    let _ = writeln!(
        out,
        "{}",
        json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
    );
    let _ = out.flush();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    fn link_with_line(value: Value) -> HubSession {
        let (commands, _command_rx) = mpsc::channel();
        let (line_tx, lines) = mpsc::channel();
        line_tx
            .send(HubSessionLine::Line(value.to_string()))
            .unwrap();
        HubSession::from_channels(commands, lines)
    }

    #[test]
    fn turn_steer_uses_prompt_when_bridge_knows_the_session_is_idle() {
        assert!(!should_steer("turn/steer", false));
        assert!(should_steer("turn/steer", true));
        assert!(!should_steer("turn/start", true));
    }

    #[test]
    fn busy_prompt_disposition_requests_one_steer_retry() {
        let link = link_with_line(
            json!({"kind":"command_rejected","payload":{"command_id":"c1","code":"busy"}}),
        );
        let mut output = Vec::new();
        let result =
            await_disposition(&link, &mut output, "c1", 1, &mut false, false, "s1", "text");
        assert_eq!(result.unwrap().0, "retry-steer");
    }

    #[test]
    fn rejected_steer_returns_an_error_without_retry() {
        let link = link_with_line(
            json!({"kind":"command_rejected","payload":{"command_id":"c1","code":"stale_request","message":"idle"}}),
        );
        let mut output = Vec::new();
        let result = await_disposition(&link, &mut output, "c1", 1, &mut false, true, "s1", "text");
        assert!(result.unwrap_err().1.contains("stale_request"));
    }

    #[test]
    fn late_steer_that_starts_the_next_turn_reports_started() {
        let link = link_with_line(
            json!({"kind":"turn_started","turn_id":"t2","payload":{"input":[{"command_id":"c1"}]}}),
        );
        let mut output = Vec::new();
        let result = await_disposition(&link, &mut output, "c1", 1, &mut false, true, "s1", "text");
        assert_eq!(result.unwrap(), ("started".into(), "t2".into()));
    }

    #[test]
    fn outcome_mapping_keeps_the_msp_terminal_vocabulary() {
        let mut out = Vec::new();
        emit_event(
            &mut out,
            &json!({"kind":"turn_completed","turn_id":"t","payload":{"outcome":"interrupted"}}),
        );
        let line = String::from_utf8(out).unwrap();
        assert!(line.contains("cancelled"));
    }

    #[test]
    fn text_parts_become_agent_messages_and_an_empty_part_is_none() {
        let mut out = Vec::new();
        emit_event(
            &mut out,
            &json!({"kind":"text_completed","turn_id":"t","payload":{"text":"STATUS: DONE"}}),
        );
        let line: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(line["method"], "item/completed");
        assert_eq!(line["params"]["item"]["kind"], "agentMessage");
        assert_eq!(line["params"]["item"]["turnId"], "t");
        assert_eq!(line["params"]["item"]["text"], "STATUS: DONE");
        let mut out = Vec::new();
        emit_event(
            &mut out,
            &json!({"kind":"text_completed","turn_id":"t","payload":{"text":""}}),
        );
        assert!(out.is_empty());
    }

    #[test]
    fn idle_exit_emits_a_log_only_session_exit() {
        let mut out = Vec::new();
        emit_idle_exit(&mut out);
        let line = String::from_utf8(out).unwrap();
        assert!(line.contains("session/exited"));
        assert!(line.contains("\"reason\":\"idle\""));
    }
}
