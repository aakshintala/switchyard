use serde_json::{Value, json};

pub const PROVIDER: &str = "meta";

#[derive(Debug, PartialEq)]
pub enum Incoming {
    Response {
        id: i64,
        result: Result<Value, RpcError>,
    },
    Event(HostEvent),
    HostRequest {
        id: Value,
        method: String,
    },
    Unparsed(String),
}

#[derive(Debug, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub kind: Option<String>,
    pub message: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposition {
    Started,
    Queued,
    Steered,
    Other,
}

#[derive(Clone, Debug, PartialEq)]
pub enum HostEvent {
    SessionStarted {
        session_id: String,
    },
    StatusChanged {
        status: String,
    },
    TurnStarted {
        turn_id: String,
    },
    TurnCompleted {
        turn_id: String,
        terminal: String,
        error: Option<TurnError>,
    },
    UserMessage {
        turn_id: String,
        text: String,
        command_id: Option<String>,
    },
    AgentMessage {
        turn_id: String,
        text: String,
    },
    ToolStarted {
        turn_id: String,
        tool: String,
        call_id: String,
    },
    ToolCompleted {
        turn_id: String,
        tool: String,
        call_id: String,
        status: String,
    },
    TokenUsage {
        prompt: u64,
        output: u64,
        total: u64,
    },
    Allowance(Value),
    SessionClosed {
        reason: String,
    },
    Ignored,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TurnError {
    pub kind: String,
    pub message: String,
}

pub fn parse_line(line: &str) -> Incoming {
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(line) else {
        return Incoming::Unparsed(line.to_string());
    };
    let id = object.get("id");
    if let (Some(id), Some(method)) = (id, object.get("method").and_then(Value::as_str)) {
        return Incoming::HostRequest {
            id: id.clone(),
            method: method.to_string(),
        };
    }
    if let Some(id) = id.and_then(Value::as_i64)
        && (object.contains_key("result") || object.contains_key("error"))
    {
        let result = if let Some(error) = object.get("error") {
            let data = error.get("data");
            Err(RpcError {
                code: error
                    .get("code")
                    .and_then(Value::as_i64)
                    .unwrap_or_default(),
                kind: data
                    .and_then(|value| value.get("kind"))
                    .and_then(Value::as_str)
                    .map(str::to_string),
                message: error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
            })
        } else {
            Ok(object.get("result").cloned().unwrap_or(Value::Null))
        };
        return Incoming::Response { id, result };
    }
    if let Some(method) = object.get("method").and_then(Value::as_str) {
        return Incoming::Event(parse_event(
            method,
            object.get("params").unwrap_or(&Value::Null),
        ));
    }
    Incoming::Unparsed(line.to_string())
}

fn parse_event(method: &str, params: &Value) -> HostEvent {
    let text = |key: &str| params.get(key).and_then(Value::as_str).map(str::to_string);
    match method {
        "session/started" => params
            .get("session")
            .and_then(|session| session.get("sessionId"))
            .and_then(Value::as_str)
            .map(|session_id| HostEvent::SessionStarted {
                session_id: session_id.to_string(),
            })
            .unwrap_or(HostEvent::Ignored),
        "session/statusChanged" => text("status")
            .map(|status| HostEvent::StatusChanged { status })
            .unwrap_or(HostEvent::Ignored),
        "turn/started" => text("turnId")
            .map(|turn_id| HostEvent::TurnStarted { turn_id })
            .unwrap_or(HostEvent::Ignored),
        "turn/completed" => {
            let Some(turn_id) = text("turnId") else {
                return HostEvent::Ignored;
            };
            let Some(terminal) = text("terminal") else {
                return HostEvent::Ignored;
            };
            let error = params.get("error").and_then(|value| {
                Some(TurnError {
                    kind: value.get("kind")?.as_str()?.to_string(),
                    message: value.get("message")?.as_str()?.to_string(),
                })
            });
            HostEvent::TurnCompleted {
                turn_id,
                terminal,
                error,
            }
        }
        "item/started" | "item/completed" => {
            let Some(item) = params.get("item") else {
                return HostEvent::Ignored;
            };
            let kind = item.get("kind").and_then(Value::as_str).unwrap_or_default();
            let turn_id = item
                .get("turnId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            match (method, kind) {
                ("item/completed", "userMessage") => HostEvent::UserMessage {
                    turn_id,
                    text: item
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    command_id: item
                        .get("commandId")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                },
                ("item/completed", "agentMessage") => HostEvent::AgentMessage {
                    turn_id,
                    text: item
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                },
                ("item/started", "toolCall") => HostEvent::ToolStarted {
                    turn_id,
                    tool: item
                        .get("tool")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    call_id: item
                        .get("callId")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                },
                ("item/completed", "toolCall") => HostEvent::ToolCompleted {
                    turn_id,
                    tool: item
                        .get("tool")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    call_id: item
                        .get("callId")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    status: item
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                },
                _ => HostEvent::Ignored,
            }
        }
        "session/tokenUsage" => {
            let cumulative = params.get("cumulative").unwrap_or(&Value::Null);
            HostEvent::TokenUsage {
                prompt: cumulative
                    .get("promptTokens")
                    .and_then(Value::as_u64)
                    .unwrap_or_default(),
                output: cumulative
                    .get("outputTokens")
                    .and_then(Value::as_u64)
                    .unwrap_or_default(),
                total: cumulative
                    .get("totalTokens")
                    .and_then(Value::as_u64)
                    .unwrap_or_default(),
            }
        }
        "usage/changed" => HostEvent::Allowance(params.clone()),
        "session/closed" => text("reason")
            .map(|reason| HostEvent::SessionClosed { reason })
            .unwrap_or(HostEvent::Ignored),
        _ => HostEvent::Ignored,
    }
}

pub fn ack_disposition(result: &Value) -> Disposition {
    match result.get("disposition").and_then(Value::as_str) {
        Some("started") => Disposition::Started,
        Some("queued") => Disposition::Queued,
        Some("steered") => Disposition::Steered,
        _ => Disposition::Other,
    }
}

pub fn log_line(event: &HostEvent) -> Option<Value> {
    Some(match event {
        HostEvent::SessionStarted { session_id } => {
            json!({"kind":"session.started","sessionId":session_id})
        }
        HostEvent::StatusChanged { status } => json!({"kind":"status","status":status}),
        HostEvent::TurnStarted { turn_id } => json!({"kind":"turn.started","turnId":turn_id}),
        HostEvent::TurnCompleted {
            turn_id,
            terminal,
            error,
        } => {
            json!({"kind":"turn.completed","turnId":turn_id,"terminal":terminal,"error":error.as_ref().map(|error| json!({"kind":error.kind,"message":error.message}))})
        }
        HostEvent::UserMessage {
            turn_id,
            text,
            command_id,
        } => json!({"kind":"user","turnId":turn_id,"text":text,"commandId":command_id}),
        HostEvent::AgentMessage { turn_id, text } => {
            json!({"kind":"message","turnId":turn_id,"text":text})
        }
        HostEvent::ToolStarted {
            turn_id,
            tool,
            call_id,
        } => json!({"kind":"tool.started","turnId":turn_id,"tool":tool,"callId":call_id}),
        HostEvent::ToolCompleted {
            turn_id,
            tool,
            call_id,
            status,
        } => {
            json!({"kind":"tool.completed","turnId":turn_id,"tool":tool,"callId":call_id,"status":status})
        }
        HostEvent::TokenUsage {
            prompt,
            output,
            total,
        } => {
            json!({"kind":"usage","promptTokens":prompt,"outputTokens":output,"totalTokens":total})
        }
        HostEvent::Allowance(value) => json!({"kind":"allowance","allowance":value}),
        HostEvent::SessionClosed { reason } => json!({"kind":"session.closed","reason":reason}),
        HostEvent::Ignored => return None,
    })
}

pub fn request(id: i64, method: &str, params: Value) -> String {
    serde_json::to_string(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
        .expect("serializing JSON-RPC request cannot fail")
}

pub fn notification(method: &str) -> String {
    serde_json::to_string(&json!({"jsonrpc":"2.0","method":method}))
        .expect("serializing JSON-RPC notification cannot fail")
}

pub fn refusal(id: &Value) -> String {
    serde_json::to_string(&json!({
        "jsonrpc":"2.0",
        "id":id,
        "error":{"code":-32601,"message":"delegate does not handle host requests"}
    }))
    .expect("serializing JSON-RPC refusal cannot fail")
}

pub fn session_start_params(cwd: &str, model_id: &str, now_ms: u64) -> Value {
    json!({
        "commandId":uuid7(now_ms),
        "workspaceRoot":cwd,
        "providerId":PROVIDER,
        "modelId":model_id,
        "approvalMode":"allowAll"
    })
}

pub fn turn_start_params(session_id: &str, text: &str, now_ms: u64) -> Value {
    json!({
        "commandId":uuid7(now_ms),
        "sessionId":session_id,
        "input":[{"type":"text","text":text}]
    })
}

pub fn turn_steer_params(session_id: &str, turn_id: &str, text: &str, now_ms: u64) -> Value {
    json!({
        "commandId":uuid7(now_ms),
        "sessionId":session_id,
        "expectedTurnId":turn_id,
        "input":[{"type":"text","text":text}]
    })
}

pub fn turn_interrupt_params(session_id: &str, turn_id: Option<&str>, now_ms: u64) -> Value {
    let mut params = json!({"commandId":uuid7(now_ms),"sessionId":session_id});
    if let Some(turn_id) = turn_id {
        params["turnId"] = json!(turn_id);
    }
    params
}

pub fn uuid7(now_ms: u64) -> String {
    let mut bytes = [0u8; 16];
    for (index, byte) in crate::util::random_uuid()
        .bytes()
        .filter(|byte| *byte != b'-')
        .collect::<Vec<_>>()
        .chunks_exact(2)
        .enumerate()
    {
        bytes[index] =
            u8::from_str_radix(std::str::from_utf8(byte).expect("hex UUID"), 16).expect("hex UUID");
    }
    let timestamp = now_ms & 0x0000_ffff_ffff_ffff;
    for (index, byte) in bytes[..6].iter_mut().enumerate() {
        *byte = (timestamp >> ((5 - index) * 8)) as u8;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}

pub fn host_argv(model_id: &str) -> Vec<String> {
    [
        "serve",
        "--provider",
        PROVIDER,
        "--model",
        model_id,
        "--disable-sandbox",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

pub fn resolve_muse_bin() -> String {
    let env_bin = std::env::var("MUSE_BIN").ok();
    let home = crate::util::homedir();
    resolve_muse_bin_from(
        env_bin.as_deref(),
        || {
            let output = std::process::Command::new("which")
                .arg("muse")
                .output()
                .ok()?;
            if !output.status.success() {
                return None;
            }
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            (!path.is_empty()).then_some(path)
        },
        &home,
    )
}

fn resolve_muse_bin_from(
    env_bin: Option<&str>,
    which_muse: impl FnOnce() -> Option<String>,
    home: &std::path::Path,
) -> String {
    if let Some(bin) = env_bin.filter(|bin| !bin.is_empty()) {
        return bin.to_string();
    }
    if let Some(path) = which_muse().filter(|path| !path.is_empty()) {
        return path;
    }
    home.join(".local/bin/muse").to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::sync::Mutex;

    const CLIENT: &str = include_str!("../../tests/fixtures/contract/muse-serve/client.jsonl");
    const BAD_MODEL: &str =
        include_str!("../../tests/fixtures/contract/muse-serve/bad-model.jsonl");
    const ABORT_RACE: &str =
        include_str!("../../tests/fixtures/contract/muse-serve/client-abort-race.jsonl");
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn frames(transcript: &str) -> Vec<(usize, Incoming)> {
        transcript
            .lines()
            .enumerate()
            .filter_map(|(index, line)| {
                line.strip_prefix("< ")
                    .map(|line| (index + 1, parse_line(line)))
            })
            .collect()
    }

    fn frame_event(line: &str) -> HostEvent {
        match parse_line(line) {
            Incoming::Event(event) => event,
            other => panic!("expected event, got {other:?}"),
        }
    }

    #[test]
    fn parse_line_classifies_rpc_shapes_and_unparsed_text() {
        assert!(matches!(
            parse_line(r#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#),
            Incoming::Response {
                id: 7,
                result: Ok(_),
                ..
            }
        ));
        match parse_line(
            r#"{"jsonrpc":"2.0","id":8,"error":{"code":-32020,"message":"gone","data":{"kind":"sessionNotFound"}}}"#,
        ) {
            Incoming::Response {
                id: 8,
                result: Err(error),
            } => {
                assert_eq!(error.code, -32020);
                assert_eq!(error.kind.as_deref(), Some("sessionNotFound"));
                assert_eq!(error.message, "gone");
            }
            other => panic!("expected error response, got {other:?}"),
        }
        assert!(matches!(
            parse_line(r#"{"jsonrpc":"2.0","method":"initialized"}"#),
            Incoming::Event(HostEvent::Ignored)
        ));
        assert!(matches!(
            parse_line(r#"{"jsonrpc":"2.0","id":1,"method":"approval/request","params":{}}"#),
            Incoming::HostRequest { id: Value::Number(_), method } if method == "approval/request"
        ));
        assert!(matches!(parse_line("not json"), Incoming::Unparsed(_)));
        assert!(matches!(parse_line("[]"), Incoming::Unparsed(_)));
        assert!(matches!(parse_line("null"), Incoming::Unparsed(_)));
        assert!(matches!(parse_line("{}"), Incoming::Unparsed(_)));
    }

    #[test]
    fn fixtures_parse_and_normalize_terminal_events_and_ack_dispositions() {
        let all: Vec<_> = [CLIENT, BAD_MODEL, ABORT_RACE]
            .into_iter()
            .flat_map(frames)
            .collect();
        assert!(
            all.iter()
                .all(|(_, incoming)| !matches!(incoming, Incoming::Unparsed(_)))
        );

        let abort = frames(ABORT_RACE);
        let abort_terms: Vec<_> = abort
            .iter()
            .filter_map(|(_, incoming)| match incoming {
                Incoming::Event(HostEvent::TurnCompleted { terminal, .. }) => {
                    Some(terminal.as_str())
                }
                _ => None,
            })
            .collect();
        assert_eq!(
            abort_terms,
            [
                "completed",
                "completed",
                "cancelled",
                "completed",
                "completed"
            ]
        );
        let queued = abort.iter().find(|(line, _)| *line == 82).unwrap();
        match &queued.1 {
            Incoming::Response {
                result: Ok(result), ..
            } => {
                assert_eq!(ack_disposition(result), Disposition::Queued);
            }
            other => panic!("line 82 must be an ack, got {other:?}"),
        }
        for line in [9, 45, 64] {
            let (_, incoming) = abort.iter().find(|(n, _)| *n == line).unwrap();
            match incoming {
                Incoming::Response {
                    result: Ok(result), ..
                } => {
                    assert_eq!(ack_disposition(result), Disposition::Started);
                }
                other => panic!("line {line} must be an ack, got {other:?}"),
            }
        }

        let client_terms: Vec<_> = frames(CLIENT)
            .into_iter()
            .filter_map(|(_, incoming)| match incoming {
                Incoming::Event(HostEvent::TurnCompleted { terminal, .. }) => Some(terminal),
                _ => None,
            })
            .collect();
        assert_eq!(
            client_terms,
            [
                "completed",
                "completed",
                "completed",
                "cancelled",
                "completed"
            ]
            .map(str::to_string)
        );
        let bad_terms: Vec<_> = frames(BAD_MODEL)
            .into_iter()
            .filter_map(|(_, incoming)| match incoming {
                Incoming::Event(HostEvent::TurnCompleted {
                    terminal, error, ..
                }) => Some((terminal, error.map(|e| e.kind))),
                _ => None,
            })
            .collect();
        assert_eq!(
            bad_terms,
            [(String::from("failed"), Some(String::from("modelError")))]
        );
        assert_eq!(
            ack_disposition(&json!({"disposition":"future"})),
            Disposition::Other
        );
        assert_eq!(ack_disposition(&json!({})), Disposition::Other);
    }

    #[test]
    fn builders_match_the_msp_wire_contract() {
        let start = session_start_params("/work", "muse-spark-1.3-contributor", 1_792_714_029_000);
        assert_eq!(start["workspaceRoot"], "/work");
        assert_eq!(start["providerId"], "meta");
        assert_eq!(start["modelId"], "muse-spark-1.3-contributor");
        assert_eq!(start["approvalMode"], "allowAll");
        assert!(is_uuid7(start["commandId"].as_str().unwrap()));

        let turn = turn_start_params("session", "hello", 1000);
        assert_eq!(turn["sessionId"], "session");
        assert_eq!(turn["input"], json!([{"type":"text","text":"hello"}]));
        assert!(turn.get("ifBusy").is_none());
        assert!(is_uuid7(turn["commandId"].as_str().unwrap()));

        let steer = turn_steer_params("session", "turn", "next", 1001);
        assert_eq!(steer["sessionId"], "session");
        assert_eq!(steer["expectedTurnId"], "turn");
        assert_eq!(steer["input"], json!([{"type":"text","text":"next"}]));
        assert!(is_uuid7(steer["commandId"].as_str().unwrap()));

        let known = turn_interrupt_params("session", Some("turn"), 1002);
        assert_eq!(known["turnId"], "turn");
        let unknown = turn_interrupt_params("session", None, 1003);
        assert!(unknown.get("turnId").is_none());

        assert_eq!(
            serde_json::from_str::<Value>(&request(4, "turn/start", json!({"x":1}))).unwrap(),
            json!({"jsonrpc":"2.0","id":4,"method":"turn/start","params":{"x":1}})
        );
        assert_eq!(
            serde_json::from_str::<Value>(&notification("initialized")).unwrap(),
            json!({"jsonrpc":"2.0","method":"initialized"})
        );
        assert_eq!(
            serde_json::from_str::<Value>(&refusal(&json!("req"))).unwrap(),
            json!({"jsonrpc":"2.0","id":"req","error":{"code":-32601,"message":"delegate does not handle host requests"}})
        );
    }

    fn is_uuid7(value: &str) -> bool {
        let b = value.as_bytes();
        b.len() == 36
            && [8, 13, 18, 23].into_iter().all(|i| b[i] == b'-')
            && b.iter().enumerate().all(|(i, c)| {
                [8, 13, 18, 23].contains(&i) || c.is_ascii_digit() || (b'a'..=b'f').contains(c)
            })
            && b[14] == b'7'
            && matches!(b[19], b'8' | b'9' | b'a' | b'b')
    }

    #[test]
    fn uuid7_encodes_timestamp_version_and_variant() {
        let now_ms = 1_792_714_029_000;
        let id = uuid7(now_ms);
        assert!(is_uuid7(&id), "invalid UUIDv7: {id}");
        let first48 = u64::from_str_radix(&id[..8], 16).unwrap() << 16
            | u64::from_str_radix(&id[9..13], 16).unwrap();
        assert_eq!(first48, now_ms);
    }

    #[test]
    fn host_argv_is_sandbox_disabled_without_yolo() {
        let args = host_argv("muse-spark-1.3-contributor");
        assert_eq!(
            args,
            [
                "serve",
                "--provider",
                "meta",
                "--model",
                "muse-spark-1.3-contributor",
                "--disable-sandbox"
            ]
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>()
        );
        assert!(!args.iter().any(|arg| arg == "--yolo"));
    }

    #[test]
    fn resolve_muse_bin_uses_env_then_which_then_home_fallback() {
        let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        struct Restore(Option<std::ffi::OsString>);
        impl Drop for Restore {
            fn drop(&mut self) {
                unsafe {
                    if let Some(value) = self.0.take() {
                        std::env::set_var("MUSE_BIN", value);
                    } else {
                        std::env::remove_var("MUSE_BIN");
                    }
                }
            }
        }
        let restore = Restore(std::env::var_os("MUSE_BIN"));
        let root = std::env::temp_dir().join(format!("muse-bin-{}", crate::util::random_uuid()));
        unsafe { std::env::set_var("MUSE_BIN", "/fake/from-env") };
        assert_eq!(resolve_muse_bin(), "/fake/from-env");
        drop(restore);

        assert_eq!(
            resolve_muse_bin_from(Some("/fake/from-env"), || panic!("env must win"), &root),
            "/fake/from-env"
        );
        assert_eq!(
            resolve_muse_bin_from(None, || Some("/fake/from-which".into()), &root),
            "/fake/from-which"
        );
        assert_eq!(
            resolve_muse_bin_from(None, || Some(String::new()), &root),
            root.join(".local/bin/muse").to_string_lossy()
        );
        assert_eq!(
            resolve_muse_bin_from(None, || None, &root),
            root.join(".local/bin/muse").to_string_lossy()
        );
        assert_eq!(
            resolve_muse_bin_from(Some(""), || Some("/fake/from-which".into()), &root),
            "/fake/from-which"
        );
    }

    #[test]
    fn fixture_frames_map_to_expected_log_kinds_and_filter_noise() {
        let events: Vec<_> = frames(CLIENT)
            .into_iter()
            .filter_map(|(_, incoming)| match incoming {
                Incoming::Event(event) => Some(event),
                _ => None,
            })
            .collect();
        let kinds: Vec<_> = events
            .iter()
            .filter_map(log_line)
            .map(|line| line["kind"].as_str().unwrap().to_string())
            .collect();
        for expected in [
            "session.started",
            "status",
            "turn.started",
            "turn.completed",
            "user",
            "message",
            "tool.started",
            "tool.completed",
            "usage",
            "allowance",
            "session.closed",
        ] {
            assert!(
                kinds.iter().any(|kind| kind == expected),
                "missing {expected}"
            );
        }
        assert!(!kinds.contains(&"item.delta".into()));
        assert!(
            events
                .iter()
                .any(|event| matches!(event, HostEvent::Ignored))
        );
        assert!(
            events
                .iter()
                .filter_map(log_line)
                .all(|line| line.get("seq").is_none() && line.get("at").is_none())
        );

        let text = CLIENT.lines().nth(90).unwrap().strip_prefix("< ").unwrap();
        let Incoming::Event(HostEvent::UserMessage {
            command_id: Some(command_id),
            ..
        }) = parse_line(text)
        else {
            panic!("fixture line 91 should be the steer's userMessage");
        };
        let request = CLIENT.lines().nth(85).unwrap().strip_prefix("> ").unwrap();
        let request: Value = serde_json::from_str(request).unwrap();
        assert_eq!(command_id, request["params"]["commandId"].as_str().unwrap());

        for noisy in [
            json!({"jsonrpc":"2.0","method":"item/delta","params":{}}),
            json!({"jsonrpc":"2.0","method":"session/contextUsage","params":{}}),
            json!({"jsonrpc":"2.0","method":"turn/foregroundCompleted","params":{}}),
            json!({"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"reasoning"}}}),
            json!({"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"reminderChild"}}}),
        ] {
            let event = frame_event(&noisy.to_string());
            assert!(matches!(event, HostEvent::Ignored));
            assert!(log_line(&event).is_none());
        }
    }
}
