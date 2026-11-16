use crate::backends::fiber::hub::{self, HubSession, HubSessionLine};
use crate::session::msp;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}

/// How long the bridge waits for Fiber to exit after `close` with `now`.
pub(crate) const CLOSE_NOW_WAIT: Duration = Duration::from_secs(1);

/// How long the bridge waits for Fiber to settle a `prompt` or `steer`. The
/// supervisor kills a host that leaves a request unanswered for
/// `RPC_TIMEOUT`, so the bridge answers with an error well inside it.
const DISPOSITION_WAIT: Duration =
    Duration::from_millis(crate::session::supervisor::RPC_TIMEOUT / 2);

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
    let (input_tx, input_rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if input_tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut bridge = Bridge::new(io::BufWriter::new(io::stdout().lock()), model, cwd, socket);
    loop {
        if let Some(code) = bridge.drain_hub() {
            return code;
        }
        bridge.expire(Instant::now());
        let line = match input_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(line) => line,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        };
        if let Some(code) = bridge.on_request(&line) {
            return code;
        }
    }
    bridge.shutdown();
    0
}

fn should_steer(method: &str, running: bool) -> bool {
    method == "turn/steer" && running
}

/// A `prompt` or `steer` sent to Fiber whose request the bridge has not
/// answered yet. The main loop keeps reading the supervisor while it waits.
struct Pending {
    rpc_id: i64,
    command_id: String,
    text: String,
    steer: bool,
    deadline: Instant,
}

enum Disposition {
    Started(String),
    Steered(String),
    RetrySteer,
    Rejected(String),
}

/// What a hub line settles for the pending command, if anything.
fn disposition(event: &Value, command_id: &str, steer: bool) -> Option<Disposition> {
    let kind = event.get("kind").and_then(Value::as_str).unwrap_or("");
    let payload = event.get("payload").unwrap_or(&Value::Null);
    let names_command =
        |item: &Value| item.get("command_id").and_then(Value::as_str) == Some(command_id);
    match kind {
        "turn_started"
            if payload
                .get("input")
                .and_then(Value::as_array)
                .is_some_and(|input| input.iter().any(names_command)) =>
        {
            Some(Disposition::Started(envelope_turn_id(event)))
        }
        // An applied steer is the user message the supervisor drops its
        // pending steer on; a queued one is not delivered yet.
        "steering_applied" | "steering_queue" if names_command(payload) => {
            Some(Disposition::Steered(envelope_turn_id(event)))
        }
        "command_rejected" if names_command(payload) => {
            let code = payload
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("rejected");
            if !steer && code == "busy" {
                return Some(Disposition::RetrySteer);
            }
            Some(Disposition::Rejected(format!(
                "hub rejected {code}: {}",
                payload.get("message").and_then(Value::as_str).unwrap_or("")
            )))
        }
        _ => None,
    }
}

/// The bridge between the supervisor's MSP requests and one hub session.
struct Bridge<W: Write> {
    out: W,
    model: String,
    cwd: String,
    socket: PathBuf,
    link: Option<HubSession>,
    session_id: String,
    running: bool,
    idle_exited: bool,
    events: EventMap,
    pending: Option<Pending>,
    disposition_wait: Duration,
}

impl<W: Write> Bridge<W> {
    fn new(out: W, model: String, cwd: String, socket: PathBuf) -> Self {
        Self {
            out,
            model,
            cwd,
            socket,
            link: None,
            session_id: String::new(),
            running: false,
            idle_exited: false,
            events: EventMap::default(),
            pending: None,
            disposition_wait: DISPOSITION_WAIT,
        }
    }

    /// Handles every hub line already waiting. `Some` is the bridge's exit
    /// code: the hub session is lost, or Fiber no longer knows the session.
    fn drain_hub(&mut self) -> Option<i32> {
        while let Some(message) = self.link.as_ref().and_then(HubSession::try_recv) {
            match message {
                HubSessionLine::Line(line) => {
                    if let Ok(event) = serde_json::from_str::<Value>(&line)
                        && let Some(code) = self.on_hub_event(&event)
                    {
                        return Some(code);
                    }
                }
                HubSessionLine::Lost(error) => {
                    if let Some(pending) = self.pending.take() {
                        write_error(&mut self.out, pending.rpc_id, -32000, &error);
                    }
                    eprintln!("{error}");
                    return Some(1);
                }
                HubSessionLine::Ready(_) => {}
            }
        }
        None
    }

    fn on_hub_event(&mut self, event: &Value) -> Option<i32> {
        if let Some(pending) = self.pending.as_ref()
            && let Some(settled) = disposition(event, &pending.command_id, pending.steer)
        {
            return self.settle(event, settled);
        }
        match event.get("kind").and_then(Value::as_str).unwrap_or("") {
            "turn_started" => {
                self.running = true;
                self.idle_exited = false;
                self.events.emit(&mut self.out, event);
            }
            "turn_completed" => {
                self.running = false;
                self.events.emit(&mut self.out, event);
            }
            "fiber_exited" => {
                self.idle_exited = !self.running;
                if self.idle_exited {
                    emit_idle_exit(&mut self.out);
                } else {
                    self.events.emit(&mut self.out, event);
                }
            }
            _ => self.events.emit(&mut self.out, event),
        }
        None
    }

    fn settle(&mut self, event: &Value, settled: Disposition) -> Option<i32> {
        let (disposition, turn_id) = match settled {
            Disposition::Started(turn_id) => {
                self.events.emit(&mut self.out, event);
                self.running = true;
                self.idle_exited = false;
                ("started", turn_id)
            }
            Disposition::Steered(turn_id) => {
                self.events.emit(&mut self.out, event);
                ("steered", turn_id)
            }
            Disposition::RetrySteer => {
                // Fiber took a turn between the bridge's look and its
                // prompt: send the same text again as a steer, once.
                let pending = self.pending.as_mut()?;
                pending.steer = true;
                let raw = hub::steer_command(&pending.command_id, &self.session_id, &pending.text);
                let command = serde_json::from_str::<Value>(&raw).unwrap_or(Value::Null);
                let sent = self
                    .link
                    .as_ref()
                    .is_some_and(|link| link.send(command).is_ok());
                if !sent && let Some(pending) = self.pending.take() {
                    write_error(&mut self.out, pending.rpc_id, -32000, "hub writer stopped");
                }
                return None;
            }
            Disposition::Rejected(message) => {
                let pending = self.pending.take()?;
                write_error(&mut self.out, pending.rpc_id, -32000, &message);
                return message.contains("session_not_found").then_some(1);
            }
        };
        let pending = self.pending.take()?;
        write_result(
            &mut self.out,
            pending.rpc_id,
            json!({"turnId":turn_id,"disposition":disposition}),
        );
        None
    }

    /// Answers a pending command Fiber has not settled by its deadline with
    /// an error. The session stays up: Fiber may still be busy, and a later
    /// line for the command is handled as any other.
    fn expire(&mut self, now: Instant) {
        if !self
            .pending
            .as_ref()
            .is_some_and(|pending| now >= pending.deadline)
        {
            return;
        }
        if let Some(pending) = self.pending.take() {
            let command = if pending.steer { "steer" } else { "prompt" };
            let message = format!(
                "Fiber did not answer the {command} within {} ms",
                self.disposition_wait.as_millis()
            );
            write_error(&mut self.out, pending.rpc_id, -32000, &message);
        }
    }

    /// Handles one supervisor line. `Some` is the bridge's exit code.
    fn on_request(&mut self, line: &str) -> Option<i32> {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            return None;
        };
        let id = value.get("id").and_then(Value::as_i64)?;
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
                    .unwrap_or(&self.cwd)
                    .to_string();
                let link = hub::spawn_session(self.model.clone(), cwd, self.socket.clone());
                match link.recv(Duration::from_secs(60)) {
                    Ok(HubSessionLine::Ready(id)) => {
                        self.session_id = id.clone();
                        self.link = Some(link);
                        Ok(json!({"session":{"sessionId":id}}))
                    }
                    Ok(HubSessionLine::Lost(error)) | Err(error) => Err((-32000, error)),
                    Ok(HubSessionLine::Line(_)) => {
                        Err((-32000, "unexpected hub startup line".into()))
                    }
                }
            }
            "turn/start" | "turn/steer" => {
                self.begin_command(id, method, &params);
                return None;
            }
            // Read even while a prompt or steer waits, so it goes out at once.
            "turn/interrupt" => {
                if let Some(link) = self.link.as_ref() {
                    let raw = hub::cancel_command(&msp::uuid7(now_ms()), &self.session_id);
                    let command = serde_json::from_str(&raw).unwrap_or(Value::Null);
                    let _ = link.send(command);
                }
                Ok(json!({"interrupted":true}))
            }
            "initialized" => return None,
            _ => Ok(Value::Null),
        };
        match result {
            Ok(value) => write_result(&mut self.out, id, value),
            Err((code, message)) => write_error(&mut self.out, id, code, &message),
        }
        None
    }

    /// Sends a `prompt`, or a `steer` while a turn runs, and leaves its
    /// request pending until Fiber settles it.
    fn begin_command(&mut self, id: i64, method: &str, params: &Value) {
        let Some(link) = self.link.as_ref() else {
            write_error(&mut self.out, id, -32000, "session is not started");
            return;
        };
        if self.pending.is_some() {
            write_error(
                &mut self.out,
                id,
                -32000,
                "an earlier prompt or steer is still waiting for Fiber",
            );
            return;
        }
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
            .unwrap_or("");
        let steer = should_steer(method, self.running);
        let raw = if steer {
            hub::steer_command(command_id, &self.session_id, text)
        } else {
            hub::prompt_command(command_id, &self.session_id, text)
        };
        let command = serde_json::from_str::<Value>(&raw).unwrap_or(Value::Null);
        if link.send(command).is_err() {
            write_error(&mut self.out, id, -32000, "hub writer stopped");
            return;
        }
        self.pending = Some(Pending {
            rpc_id: id,
            command_id: command_id.to_string(),
            text: text.to_string(),
            steer,
            deadline: Instant::now() + self.disposition_wait,
        });
    }

    /// Stdin has closed: read what the hub already sent, then close the
    /// session, and close it with `now` when Fiber does not exit in the grace.
    fn shutdown(&mut self) {
        while let Some(message) = self.link.as_ref().and_then(HubSession::try_recv) {
            if let HubSessionLine::Line(line) = message
                && let Ok(event) = serde_json::from_str::<Value>(&line)
            {
                let _ = self.on_hub_event(&event);
            }
        }
        let Some(link) = self.link.as_ref() else {
            return;
        };
        if self.idle_exited {
            return;
        }
        let close_id = msp::uuid7(now_ms());
        let _ = link.send(json!({"id":close_id,"command":"close","session_id":self.session_id}));
        if !await_exit(
            link,
            &mut self.out,
            &mut self.events,
            &mut self.running,
            stop_grace(),
        ) {
            let now = msp::uuid7(now_ms());
            let _ = link.send(json!({"id":now,"command":"close","session_id":self.session_id,"args":{"now":true}}));
            let _ = await_exit(
                link,
                &mut self.out,
                &mut self.events,
                &mut self.running,
                CLOSE_NOW_WAIT,
            );
        }
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

    /// A bridge on a started session whose hub is two channels: the commands
    /// it sends and the lines the test feeds it.
    fn test_bridge() -> (
        Bridge<Vec<u8>>,
        mpsc::Receiver<String>,
        mpsc::Sender<HubSessionLine>,
    ) {
        let (commands, command_rx) = mpsc::channel();
        let (line_tx, lines) = mpsc::channel();
        let mut bridge = Bridge::new(Vec::new(), "m".into(), "/w".into(), PathBuf::new());
        bridge.link = Some(HubSession::from_channels(commands, lines));
        bridge.session_id = "s1".into();
        (bridge, command_rx, line_tx)
    }

    fn request(
        bridge: &mut Bridge<Vec<u8>>,
        id: i64,
        method: &str,
        command_id: &str,
    ) -> Option<i32> {
        let line = json!({"jsonrpc":"2.0","id":id,"method":method,"params":{"commandId":command_id,"input":[{"type":"text","text":"text"}]}});
        bridge.on_request(&line.to_string())
    }

    fn feed(
        bridge: &mut Bridge<Vec<u8>>,
        lines: &mpsc::Sender<HubSessionLine>,
        event: Value,
    ) -> Option<i32> {
        lines.send(HubSessionLine::Line(event.to_string())).unwrap();
        bridge.drain_hub()
    }

    /// Every line the bridge has written since the last call.
    fn written(bridge: &mut Bridge<Vec<u8>>) -> Vec<Value> {
        let out = std::mem::take(&mut bridge.out);
        String::from_utf8(out)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    fn sent(commands: &mpsc::Receiver<String>) -> Value {
        serde_json::from_str(&commands.try_recv().expect("a hub command")).unwrap()
    }

    #[test]
    fn turn_steer_uses_prompt_when_bridge_knows_the_session_is_idle() {
        assert!(!should_steer("turn/steer", false));
        assert!(should_steer("turn/steer", true));
        assert!(!should_steer("turn/start", true));
    }

    #[test]
    fn busy_prompt_disposition_requests_one_steer_retry() {
        let (mut bridge, commands, lines) = test_bridge();
        assert_eq!(request(&mut bridge, 1, "turn/start", "c1"), None);
        assert_eq!(sent(&commands)["command"], "prompt");
        feed(
            &mut bridge,
            &lines,
            json!({"kind":"command_rejected","payload":{"command_id":"c1","code":"busy"}}),
        );
        let retry = sent(&commands);
        assert_eq!(retry["command"], "steer");
        assert_eq!(retry["id"], "c1");
        assert!(
            written(&mut bridge).is_empty(),
            "no answer before the steer settles"
        );
        assert!(bridge.pending.as_ref().is_some_and(|pending| pending.steer));
    }

    #[test]
    fn rejected_steer_returns_an_error_without_retry() {
        let (mut bridge, commands, lines) = test_bridge();
        bridge.running = true;
        request(&mut bridge, 1, "turn/steer", "c1");
        assert_eq!(sent(&commands)["command"], "steer");
        let exit = feed(
            &mut bridge,
            &lines,
            json!({"kind":"command_rejected","payload":{"command_id":"c1","code":"stale_request","message":"idle"}}),
        );
        assert_eq!(exit, None);
        let reply = written(&mut bridge);
        assert_eq!(reply[0]["id"], 1);
        assert!(
            reply[0]["error"]["message"]
                .as_str()
                .unwrap()
                .contains("stale_request")
        );
        assert!(commands.try_recv().is_err(), "no retry");
    }

    #[test]
    fn late_steer_that_starts_the_next_turn_reports_started() {
        let (mut bridge, _commands, lines) = test_bridge();
        bridge.running = true;
        request(&mut bridge, 1, "turn/steer", "c1");
        feed(
            &mut bridge,
            &lines,
            json!({"kind":"turn_started","turn_id":"t2","payload":{"input":[{"command_id":"c1"}]}}),
        );
        let reply = written(&mut bridge).pop().unwrap();
        assert_eq!(reply["id"], 1);
        assert_eq!(
            reply["result"],
            json!({"turnId":"t2","disposition":"started"})
        );
    }

    #[test]
    fn an_applied_steer_is_logged_as_its_user_message_before_the_reply() {
        let (mut bridge, _commands, lines) = test_bridge();
        bridge.running = true;
        request(&mut bridge, 1, "turn/steer", "c1");
        feed(
            &mut bridge,
            &lines,
            json!({"kind":"steering_applied","turn_id":"t1","seq":4,"payload":{"content":[{"type":"text","text":"also run clippy"}],"source":"driver","command_id":"c1"}}),
        );
        let lines = written(&mut bridge);
        assert_eq!(
            lines[0]["params"]["item"],
            json!({"kind":"userMessage","turnId":"t1","text":"also run clippy","commandId":"c1"})
        );
        assert_eq!(
            lines[1]["result"],
            json!({"turnId":"t1","disposition":"steered"})
        );
    }

    #[test]
    fn a_turn_started_by_a_steer_logs_the_steer_as_a_user_message() {
        let (mut bridge, _commands, lines) = test_bridge();
        request(&mut bridge, 1, "turn/steer", "c1");
        feed(
            &mut bridge,
            &lines,
            json!({"kind":"turn_started","turn_id":"t2","seq":9,"payload":{"input":[{"type":"message","command_id":"c1","content":[{"type":"text","text":"one more thing"}],"source":"driver"}]}}),
        );
        let lines = written(&mut bridge);
        assert_eq!(lines[0]["method"], "turn/started");
        assert_eq!(
            lines[1]["params"]["item"],
            json!({"kind":"userMessage","turnId":"t2","text":"one more thing","commandId":"c1"})
        );
        assert_eq!(
            lines[2]["result"],
            json!({"turnId":"t2","disposition":"started"})
        );
    }

    #[test]
    fn a_silent_fiber_past_the_disposition_wait_gets_an_error_and_the_session_stays_up() {
        let (mut bridge, commands, lines) = test_bridge();
        assert_eq!(request(&mut bridge, 1, "turn/start", "c1"), None);
        bridge.expire(Instant::now());
        assert!(written(&mut bridge).is_empty(), "no answer inside the wait");
        bridge.expire(Instant::now() + DISPOSITION_WAIT);
        let reply = written(&mut bridge);
        assert_eq!(reply.len(), 1);
        assert_eq!(reply[0]["id"], 1);
        assert!(
            reply[0]["error"]["message"]
                .as_str()
                .unwrap()
                .contains("did not answer the prompt")
        );
        assert!(bridge.pending.is_none());
        // Fiber starts the late prompt's turn after all: it is logged as any
        // other turn, and the next prompt is still served.
        feed(
            &mut bridge,
            &lines,
            json!({"kind":"turn_started","turn_id":"t1","payload":{"input":[{"command_id":"c1"}]}}),
        );
        assert_eq!(written(&mut bridge)[0]["method"], "turn/started");
        feed(
            &mut bridge,
            &lines,
            json!({"kind":"turn_completed","turn_id":"t1","payload":{"outcome":"completed"}}),
        );
        written(&mut bridge);
        assert_eq!(sent(&commands)["command"], "prompt");
        assert_eq!(request(&mut bridge, 2, "turn/start", "c2"), None);
        assert_eq!(sent(&commands)["id"], "c2");
        feed(
            &mut bridge,
            &lines,
            json!({"kind":"turn_started","turn_id":"t2","payload":{"input":[{"command_id":"c2"}]}}),
        );
        let reply = written(&mut bridge).pop().unwrap();
        assert_eq!(reply["id"], 2);
        assert_eq!(reply["result"]["disposition"], "started");
    }

    #[test]
    fn an_interrupt_during_a_pending_disposition_goes_out_at_once() {
        let (mut bridge, commands, lines) = test_bridge();
        bridge.running = true;
        request(&mut bridge, 1, "turn/steer", "c1");
        assert_eq!(sent(&commands)["command"], "steer");
        assert_eq!(request(&mut bridge, 2, "turn/interrupt", ""), None);
        let cancel = sent(&commands);
        assert_eq!(cancel["command"], "cancel");
        assert_eq!(cancel["session_id"], "s1");
        let reply = written(&mut bridge);
        assert_eq!(reply[0]["id"], 2);
        assert_eq!(reply[0]["result"], json!({"interrupted":true}));
        // The steer is still waiting, and is answered when Fiber settles it.
        feed(
            &mut bridge,
            &lines,
            json!({"kind":"steering_applied","turn_id":"t1","payload":{"content":[],"command_id":"c1"}}),
        );
        let reply = written(&mut bridge).pop().unwrap();
        assert_eq!(reply["id"], 1);
        assert_eq!(reply["result"]["disposition"], "steered");
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
