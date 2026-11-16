use crate::backends::fiber::hub::{self, HubSession, HubSessionLine};
use crate::session::msp;
use serde_json::{Value, json};
use std::collections::HashMap;
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
    let mut events = EventMap::default();
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
                                    events.emit(&mut stdout, &event);
                                }
                            } else {
                                events.emit(&mut stdout, &event);
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
                    &mut events,
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
                                &mut events,
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
                        events.emit(&mut stdout, &event);
                    }
                } else {
                    events.emit(&mut stdout, &event);
                }
            }
        }
        if !idle_exited {
            let close_id = msp::uuid7(now_ms());
            let raw = serde_json::json!({"id":close_id,"command":"close","session_id":session_id});
            let _ = link.send(raw);
            if !await_exit(link, &mut stdout, &mut events, &mut running, stop_grace()) {
                let now = msp::uuid7(now_ms());
                let _ = link.send(serde_json::json!({"id":now,"command":"close","session_id":session_id,"args":{"now":true}}));
                let _ = await_exit(link, &mut stdout, &mut events, &mut running, CLOSE_NOW_WAIT);
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
    events: &mut EventMap,
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
                events.emit(out, &v);
                *running = true;
                return Ok(("started".into(), envelope_turn_id(&v)));
            }
        }
        if matches!(kind, "steering_applied" | "steering_queue")
            && payload.get("command_id").and_then(Value::as_str) == Some(command_id)
        {
            // An applied steer is the user message the supervisor drops its
            // pending steer on; a queued one is not delivered yet.
            events.emit(out, &v);
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
        events.emit(out, &v);
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
    events: &mut EventMap,
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
                events.emit(out, &v);
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

/// Maps Fiber hub events (docs/events.md) to MSP notifications. It keeps the
/// little state the mapping needs: each open reply's text, each tool call's
/// name, which only `tool_call_requested` carries, and each model call's
/// tokens, which MSP reports as session totals.
#[derive(Default)]
struct EventMap {
    /// The text parts of each open reply, joined in order, by `action_id`.
    replies: HashMap<String, String>,
    tool_names: HashMap<String, String>,
    /// Prompt and output tokens per `generation_id`, the latest line's.
    usage: HashMap<String, (u64, u64)>,
}

impl EventMap {
    fn emit(&mut self, out: &mut impl Write, event: &Value) {
        for (method, params) in self.notifications(event) {
            let _ = writeln!(
                out,
                "{}",
                json!({"jsonrpc":"2.0","method":method,"params":params})
            );
        }
        let _ = out.flush();
    }

    fn notifications(&mut self, event: &Value) -> Vec<(&'static str, Value)> {
        let kind = event.get("kind").and_then(Value::as_str).unwrap_or("");
        let p = event.get("payload").cloned().unwrap_or(Value::Null);
        // Fiber's envelope carries `turn_id` and `action_id`; the payload does not.
        let turn_id = event.get("turn_id");
        let action_id = event.get("action_id").and_then(Value::as_str).unwrap_or("");
        match kind {
            // The turn's input names the messages that started it.
            "turn_started" => {
                let mut notes = vec![("turn/started", json!({"turnId":turn_id}))];
                for item in p
                    .get("input")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    if item.get("type").and_then(Value::as_str) == Some("message") {
                        notes.push(user_message(turn_id, item));
                    }
                }
                notes
            }
            "turn_completed" => {
                // A reply its turn ended without completing never became
                // durable (docs/events.md, "text_completed").
                self.replies.clear();
                vec![(
                    "turn/completed",
                    json!({"turnId":turn_id,"terminal":match p.get("outcome").and_then(Value::as_str).unwrap_or(""){"completed"=>"completed","interrupted"=>"cancelled",_=>"failed"},"error":msp_error(p.get("error")),"questions":p.get("questions")}),
                )]
            }
            "steering_applied" => vec![user_message(turn_id, &p)],
            // A reply is its `assistant_message_started`, its text parts and
            // its `assistant_message_completed`, all under its `action_id`.
            // It is one message: its parts joined in order, as `fiber_exited`
            // joins the final one. A failed model call is retried as a new
            // action, so its text is no message; nor is a reply with none.
            "assistant_message_started" => {
                self.replies.insert(action_id.into(), String::new());
                Vec::new()
            }
            "text_completed" => {
                let part = p.get("text").and_then(Value::as_str).unwrap_or("");
                self.replies
                    .entry(action_id.into())
                    .or_default()
                    .push_str(part);
                Vec::new()
            }
            "assistant_message_completed" => {
                let text = self.replies.remove(action_id).unwrap_or_default();
                if p.get("outcome").and_then(Value::as_str) != Some("completed") || text.is_empty()
                {
                    return Vec::new();
                }
                vec![(
                    "item/completed",
                    json!({"item":{"kind":"agentMessage","turnId":turn_id,"text":text}}),
                )]
            }
            // A tool call is its own action: its lines share its `action_id`,
            // and only `tool_call_requested` names the tool.
            "tool_call_requested" => {
                let name = p.get("name").and_then(Value::as_str).unwrap_or("");
                self.tool_names.insert(action_id.into(), name.into());
                Vec::new()
            }
            "tool_call_started" => vec![(
                "item/started",
                json!({"item":{"kind":"toolCall","turnId":turn_id,"tool":self.tool_name(action_id),"callId":action_id}}),
            )],
            "tool_call_completed" => {
                let tool = self.tool_names.remove(action_id).unwrap_or_default();
                vec![(
                    "item/completed",
                    json!({"item":{"kind":"toolCall","turnId":turn_id,"tool":tool,"callId":action_id,"status":p.get("status")}}),
                )]
            }
            "usage_recorded" => {
                let Some(generation_id) = p.get("generation_id").and_then(Value::as_str) else {
                    return Vec::new();
                };
                let tokens = p.get("tokens").unwrap_or(&Value::Null);
                let count = |key: &str| tokens.get(key).and_then(Value::as_u64).unwrap_or(0);
                let cache_write: u64 = tokens
                    .get("cache_write")
                    .and_then(Value::as_object)
                    .map(|classes| classes.values().filter_map(Value::as_u64).sum())
                    .unwrap_or(0);
                let prompt = count("input")
                    .saturating_add(count("cache_read"))
                    .saturating_add(cache_write);
                self.usage
                    .insert(generation_id.into(), (prompt, count("output")));
                let (prompt, output) = self.usage.values().fold((0u64, 0u64), |sum, call| {
                    (sum.0.saturating_add(call.0), sum.1.saturating_add(call.1))
                });
                vec![(
                    "session/tokenUsage",
                    json!({"cumulative":{"promptTokens":prompt,"outputTokens":output,"totalTokens":prompt.saturating_add(output)}}),
                )]
            }
            "fiber_exited" => vec![("session/closed", json!({"reason":"stopped"}))],
            _ => Vec::new(),
        }
    }

    fn tool_name(&self, action_id: &str) -> String {
        self.tool_names.get(action_id).cloned().unwrap_or_default()
    }
}

/// A message from a `turn_started` input item or a `steering_applied` line:
/// its text parts, in order, and the `command_id` that sent it
/// (docs/events.md, "Where a message came from").
fn user_message(turn_id: Option<&Value>, message: &Value) -> (&'static str, Value) {
    let text: String = message
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect();
    (
        "item/completed",
        json!({"item":{"kind":"userMessage","turnId":turn_id,"text":text,"commandId":message.get("command_id")}}),
    )
}

/// Fiber's `error` object is `{code, message}` (docs/events.md, "error");
/// MSP's turn error is `{kind, message}`, so `code` becomes `kind`.
fn msp_error(error: Option<&Value>) -> Value {
    match error {
        Some(error) if error.is_object() => {
            json!({"kind":error.get("code"),"message":error.get("message")})
        }
        _ => Value::Null,
    }
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
        let result = await_disposition(
            &link,
            &mut output,
            &mut EventMap::default(),
            "c1",
            1,
            &mut false,
            false,
            "s1",
            "text",
        );
        assert_eq!(result.unwrap().0, "retry-steer");
    }

    #[test]
    fn rejected_steer_returns_an_error_without_retry() {
        let link = link_with_line(
            json!({"kind":"command_rejected","payload":{"command_id":"c1","code":"stale_request","message":"idle"}}),
        );
        let mut output = Vec::new();
        let result = await_disposition(
            &link,
            &mut output,
            &mut EventMap::default(),
            "c1",
            1,
            &mut false,
            true,
            "s1",
            "text",
        );
        assert!(result.unwrap_err().1.contains("stale_request"));
    }

    #[test]
    fn late_steer_that_starts_the_next_turn_reports_started() {
        let link = link_with_line(
            json!({"kind":"turn_started","turn_id":"t2","payload":{"input":[{"command_id":"c1"}]}}),
        );
        let mut output = Vec::new();
        let result = await_disposition(
            &link,
            &mut output,
            &mut EventMap::default(),
            "c1",
            1,
            &mut false,
            true,
            "s1",
            "text",
        );
        assert_eq!(result.unwrap(), ("started".into(), "t2".into()));
    }

    #[test]
    fn an_applied_steer_is_logged_as_its_user_message_before_the_reply() {
        let link = link_with_line(
            json!({"kind":"steering_applied","turn_id":"t1","seq":4,"payload":{"content":[{"type":"text","text":"also run clippy"}],"source":"driver","command_id":"c1"}}),
        );
        let mut output = Vec::new();
        let result = await_disposition(
            &link,
            &mut output,
            &mut EventMap::default(),
            "c1",
            1,
            &mut true,
            true,
            "s1",
            "also run clippy",
        );
        assert_eq!(result.unwrap(), ("steered".into(), "t1".into()));
        let line: Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(
            line["params"]["item"],
            json!({"kind":"userMessage","turnId":"t1","text":"also run clippy","commandId":"c1"})
        );
    }

    #[test]
    fn a_turn_started_by_a_steer_logs_the_steer_as_a_user_message() {
        let link = link_with_line(
            json!({"kind":"turn_started","turn_id":"t2","seq":9,"payload":{"input":[{"type":"message","command_id":"c1","content":[{"type":"text","text":"one more thing"}],"source":"driver"}]}}),
        );
        let mut output = Vec::new();
        let result = await_disposition(
            &link,
            &mut output,
            &mut EventMap::default(),
            "c1",
            1,
            &mut false,
            true,
            "s1",
            "one more thing",
        );
        assert_eq!(result.unwrap(), ("started".into(), "t2".into()));
        let lines: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(lines[0]["method"], "turn/started");
        assert_eq!(
            lines[1]["params"]["item"],
            json!({"kind":"userMessage","turnId":"t2","text":"one more thing","commandId":"c1"})
        );
    }

    #[test]
    fn outcome_mapping_keeps_the_msp_terminal_vocabulary() {
        let mut out = Vec::new();
        EventMap::default().emit(
            &mut out,
            &json!({"kind":"turn_completed","turn_id":"t","payload":{"outcome":"interrupted"}}),
        );
        let line = String::from_utf8(out).unwrap();
        assert!(line.contains("cancelled"));
    }

    #[test]
    fn a_reply_becomes_one_agent_message_and_an_empty_reply_is_none() {
        let line = |kind: &str, payload: Value| json!({"kind":kind,"turn_id":"t","action_id":"a","payload":payload});
        let mut events = EventMap::default();
        let mut out = Vec::new();
        for event in [
            line("assistant_message_started", json!({})),
            line("text_completed", json!({"text":"Done."})),
            line("text_completed", json!({"text":""})),
            line("text_completed", json!({"text":"\n\nSTATUS: DONE"})),
        ] {
            events.emit(&mut out, &event);
        }
        assert!(out.is_empty(), "no message before the reply completes");
        events.emit(
            &mut out,
            &line(
                "assistant_message_completed",
                json!({"outcome":"completed"}),
            ),
        );
        let message: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(message["method"], "item/completed");
        assert_eq!(message["params"]["item"]["kind"], "agentMessage");
        assert_eq!(message["params"]["item"]["turnId"], "t");
        assert_eq!(message["params"]["item"]["text"], "Done.\n\nSTATUS: DONE");
        let mut out = Vec::new();
        for event in [
            line("assistant_message_started", json!({})),
            line("text_completed", json!({"text":""})),
            line(
                "assistant_message_completed",
                json!({"outcome":"completed"}),
            ),
        ] {
            events.emit(&mut out, &event);
        }
        assert!(out.is_empty());
    }

    #[test]
    fn a_recorded_fiber_run_maps_to_msp_items_and_usage() {
        let mut events = EventMap::default();
        let mut out = Vec::new();
        let recorded = include_str!("../../tests/fixtures/recorded/fiber/echo.jsonl");
        for line in recorded.lines() {
            events.emit(&mut out, &serde_json::from_str(line).unwrap());
        }
        let notes: Vec<Value> = String::from_utf8(out)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let items = |method: &str, kind: &str| -> Vec<Value> {
            notes
                .iter()
                .filter(|note| note["method"] == method && note["params"]["item"]["kind"] == kind)
                .map(|note| note["params"]["item"].clone())
                .collect()
        };
        let started = items("item/started", "toolCall");
        let completed = items("item/completed", "toolCall");
        assert_eq!(started.len(), 1, "{started:?}");
        assert_eq!(started[0]["tool"], "shell");
        assert_eq!(completed[0]["tool"], "shell");
        assert_eq!(completed[0]["callId"], started[0]["callId"]);
        assert_eq!(completed[0]["status"], "completed");
        let texts: Vec<Value> = items("item/completed", "agentMessage")
            .into_iter()
            .map(|item| item["text"].clone())
            .collect();
        assert_eq!(texts, [json!("I'll run echo hi now."), json!("DONE")]);
        assert_eq!(items("item/completed", "userMessage").len(), 1);
        let usage = notes
            .iter()
            .rfind(|note| note["method"] == "session/tokenUsage")
            .unwrap();
        assert_eq!(
            usage["params"]["cumulative"],
            json!({"promptTokens":5542 + 170 + 5489,"outputTokens":88 + 18,"totalTokens":5542 + 170 + 5489 + 88 + 18})
        );
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
