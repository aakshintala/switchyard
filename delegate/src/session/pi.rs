use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::path::Path;

pub const TRIGGER: &str = "Your instructions are in your system prompt. Begin.";
pub const LEVELS: [&str; 7] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

#[derive(Debug, PartialEq, Eq)]
pub struct Model {
    pub provider: String,
    pub id: String,
    pub level: Option<String>,
}

pub fn parse_model(model: &str) -> Result<Model, String> {
    if model.is_empty() {
        return Err("model must not be empty".to_string());
    }
    if model.starts_with('-') {
        return Err("model must not start with '-'".to_string());
    }
    if model.bytes().any(|b| b == 0) {
        return Err("model must not contain NUL".to_string());
    }
    if model.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("model must not contain whitespace or control".to_string());
    }
    let Some(slash) = model.find('/') else {
        return Err("model must use the provider/id form".to_string());
    };
    let provider = &model[..slash];
    let rest = &model[slash + 1..];
    if provider.is_empty() || rest.is_empty() {
        return Err("model provider and id must be non-empty".to_string());
    }
    if provider.contains(':') {
        return Err("model provider must not contain ':'".to_string());
    }
    if let Some((head, tail)) = rest.rsplit_once(':') {
        if tail.is_empty() {
            return Err("model level must not be empty".to_string());
        }
        if LEVELS.contains(&tail) {
            if head.is_empty() {
                return Err("model provider and id must be non-empty".to_string());
            }
            return Ok(Model {
                provider: provider.to_string(),
                id: head.to_string(),
                level: Some(tail.to_string()),
            });
        }
    }
    Ok(Model {
        provider: provider.to_string(),
        id: rest.to_string(),
        level: None,
    })
}

pub fn host_argv(model: &str, session_id: &str, session_dir: &Path, brief: &Path) -> Vec<String> {
    [
        "--mode",
        "rpc",
        "--model",
        model,
        "--session-id",
        session_id,
        "--session-dir",
        &session_dir.to_string_lossy(),
        "--append-system-prompt",
        &brief.to_string_lossy(),
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

pub fn refusal(id: &Value) -> String {
    serde_json::to_string(&serde_json::json!({
        "type": "extension_ui_response",
        "id": id.clone(),
        "cancelled": true,
    }))
    .expect("serializing pi refusal cannot fail")
}

struct Pending {
    method: String,
    command_id: String,
    turn_id: Option<String>,
}

#[derive(Default)]
pub struct Wire {
    next_turn: u64,
    current: Option<String>,
    unconfirmed: bool,
    started_emitted: bool,
    pending: HashMap<String, Pending>,
    fifo: VecDeque<String>,
    prompt_cumulative: u64,
    output_cumulative: u64,
    total_cumulative: u64,
    last_assistant_error: Option<String>,
    auto_retry_error: Option<String>,
    buffered_settle: Option<(String, Option<crate::session::msp::TurnError>)>,
}

impl Wire {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn queued_steers(&self) -> usize {
        self.fifo.len()
    }

    pub fn encode(&mut self, id: i64, method: &str, params: &Value) -> Result<String, String> {
        let wire_id = id.to_string();
        match method {
            "turn/start" => {
                let text = params
                    .get("input")
                    .and_then(Value::as_array)
                    .and_then(|input| input.first())
                    .and_then(|item| item.get("text"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| "turn/start params need input[0].text".to_string())?;
                let command_id = params
                    .get("commandId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                self.next_turn += 1;
                let turn_id = format!("pi-turn-{}", self.next_turn);
                self.current = Some(turn_id.clone());
                self.unconfirmed = true;
                self.started_emitted = false;
                self.last_assistant_error = None;
                self.auto_retry_error = None;
                self.buffered_settle = None;
                self.pending.insert(
                    wire_id.clone(),
                    Pending {
                        method: method.to_string(),
                        command_id,
                        turn_id: Some(turn_id),
                    },
                );
                serde_json::to_string(&serde_json::json!({
                    "id": wire_id,
                    "type": "prompt",
                    "message": text,
                }))
                .map_err(|error| error.to_string())
            }
            "turn/steer" => {
                let text = params
                    .get("input")
                    .and_then(Value::as_array)
                    .and_then(|input| input.first())
                    .and_then(|item| item.get("text"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| "turn/steer params need input[0].text".to_string())?;
                let command_id = params
                    .get("commandId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                self.pending.insert(
                    wire_id.clone(),
                    Pending {
                        method: method.to_string(),
                        command_id,
                        turn_id: None,
                    },
                );
                serde_json::to_string(&serde_json::json!({
                    "id": wire_id,
                    "type": "prompt",
                    "message": text,
                    "streamingBehavior": "steer",
                }))
                .map_err(|error| error.to_string())
            }
            "turn/interrupt" => {
                self.pending.insert(
                    wire_id.clone(),
                    Pending {
                        method: method.to_string(),
                        command_id: String::new(),
                        turn_id: None,
                    },
                );
                serde_json::to_string(&serde_json::json!({
                    "id": wire_id,
                    "type": "abort",
                }))
                .map_err(|error| error.to_string())
            }
            "queue/clear" => {
                self.pending.insert(
                    wire_id.clone(),
                    Pending {
                        method: method.to_string(),
                        command_id: String::new(),
                        turn_id: None,
                    },
                );
                serde_json::to_string(&serde_json::json!({
                    "id": wire_id,
                    "type": "clear_queue",
                }))
                .map_err(|error| error.to_string())
            }
            "model/set" => {
                let provider = params
                    .get("provider")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "model/set params need provider".to_string())?;
                let mut model_id = params
                    .get("modelId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "model/set params need modelId".to_string())?;
                if let Some((head, tail)) = model_id.rsplit_once(':')
                    && LEVELS.contains(&tail)
                {
                    model_id = head;
                }
                self.pending.insert(
                    wire_id.clone(),
                    Pending {
                        method: method.to_string(),
                        command_id: String::new(),
                        turn_id: None,
                    },
                );
                serde_json::to_string(&serde_json::json!({
                    "id": wire_id,
                    "type": "set_model",
                    "provider": provider,
                    "modelId": model_id,
                }))
                .map_err(|error| error.to_string())
            }
            "thinking/set" => {
                let level = params
                    .get("level")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "thinking/set params need level".to_string())?;
                self.pending.insert(
                    wire_id.clone(),
                    Pending {
                        method: method.to_string(),
                        command_id: String::new(),
                        turn_id: None,
                    },
                );
                serde_json::to_string(&serde_json::json!({
                    "id": wire_id,
                    "type": "set_thinking_level",
                    "level": level,
                }))
                .map_err(|error| error.to_string())
            }
            _ => Err(format!("unknown pi method {method}")),
        }
    }

    pub fn parse(&mut self, line: &str) -> Vec<crate::session::msp::Incoming> {
        let Ok(Value::Object(object)) = serde_json::from_str::<Value>(line) else {
            return vec![crate::session::msp::Incoming::Unparsed(line.to_string())];
        };
        let Some(kind) = object.get("type").and_then(Value::as_str) else {
            return vec![crate::session::msp::Incoming::Unparsed(line.to_string())];
        };
        if kind == "response" {
            return self.parse_response(line, &object);
        }
        self.parse_event(line, &object, kind)
    }

    fn parse_response(
        &mut self,
        line: &str,
        object: &serde_json::Map<String, Value>,
    ) -> Vec<crate::session::msp::Incoming> {
        let id_value = object.get("id");
        let id_key = match id_value {
            Some(Value::String(id)) => {
                if id.parse::<i64>().is_err() {
                    return vec![crate::session::msp::Incoming::Unparsed(line.to_string())];
                }
                id.clone()
            }
            Some(Value::Number(id)) => {
                if id.as_i64().is_none() {
                    return vec![crate::session::msp::Incoming::Unparsed(line.to_string())];
                }
                id.to_string()
            }
            _ => return vec![crate::session::msp::Incoming::Unparsed(line.to_string())],
        };
        let Some(pending) = self.pending.remove(&id_key) else {
            let result: Result<Value, crate::session::msp::RpcError> = Ok(Value::Null);
            return vec![crate::session::msp::Incoming::Response {
                id: id_key.parse::<i64>().unwrap_or(0),
                result,
            }];
        };
        let id_num = id_key.parse::<i64>().unwrap_or(0);
        let success = object
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !success {
            let message = object
                .get("error")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| {
                    object
                        .get("error")
                        .map(|error| error.to_string())
                        .unwrap_or_default()
                });
            if pending.method == "turn/start" {
                self.current = None;
                self.unconfirmed = false;
                self.started_emitted = false;
                self.buffered_settle = None;
            }
            return vec![crate::session::msp::Incoming::Response {
                id: id_num,
                result: Err(crate::session::msp::RpcError {
                    code: 0,
                    kind: None,
                    message,
                }),
            }];
        }
        let data = object.get("data").cloned().unwrap_or(Value::Null);
        match pending.method.as_str() {
            "turn/start" => {
                let disposition = data
                    .get("disposition")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                match disposition {
                    "started" => {
                        let turn_id = pending.turn_id.clone().unwrap_or_default();
                        self.unconfirmed = false;
                        if !pending.command_id.is_empty() {
                            self.fifo.push_back(pending.command_id.clone());
                        }
                        let response = crate::session::msp::Incoming::Response {
                            id: id_num,
                            result: Ok(serde_json::json!({
                                "turnId": turn_id.clone(),
                                "disposition": "started",
                            })),
                        };
                        if let Some((terminal, error)) = self.buffered_settle.take() {
                            self.current = None;
                            self.unconfirmed = false;
                            self.started_emitted = false;
                            self.last_assistant_error = None;
                            self.auto_retry_error = None;
                            return vec![
                                response,
                                crate::session::msp::Incoming::Event(
                                    crate::session::msp::HostEvent::TurnCompleted {
                                        turn_id,
                                        terminal,
                                        error,
                                    },
                                ),
                            ];
                        }
                        vec![response]
                    }
                    "queued" => {
                        if !pending.command_id.is_empty() {
                            self.fifo.push_back(pending.command_id.clone());
                        }
                        self.current = None;
                        self.unconfirmed = false;
                        self.started_emitted = false;
                        self.buffered_settle = None;
                        vec![crate::session::msp::Incoming::Response {
                            id: id_num,
                            result: Err(crate::session::msp::RpcError {
                                code: -32000,
                                kind: Some("queued".to_string()),
                                message: "pi did not start a run: prompt was queued".to_string(),
                            }),
                        }]
                    }
                    "handled" => {
                        if !pending.command_id.is_empty() {
                            self.fifo.push_back(pending.command_id.clone());
                        }
                        self.current = None;
                        self.unconfirmed = false;
                        self.started_emitted = false;
                        vec![crate::session::msp::Incoming::Response {
                            id: id_num,
                            result: Err(crate::session::msp::RpcError {
                                code: -32000,
                                kind: Some("handled".to_string()),
                                message:
                                    "pi did not start a run: prompt was handled by an extension"
                                        .to_string(),
                            }),
                        }]
                    }
                    _ => {
                        self.current = None;
                        self.unconfirmed = false;
                        self.started_emitted = false;
                        self.buffered_settle = None;
                        vec![crate::session::msp::Incoming::Response {
                            id: id_num,
                            result: Err(crate::session::msp::RpcError {
                                code: 0,
                                kind: None,
                                message: "pi did not start a run".to_string(),
                            }),
                        }]
                    }
                }
            }
            "turn/steer" => {
                let disposition = data
                    .get("disposition")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                match disposition {
                    "started" | "queued" | "handled" => {
                        if !pending.command_id.is_empty() {
                            self.fifo.push_back(pending.command_id.clone());
                        }
                        if disposition == "started" && self.current.is_none() {
                            self.next_turn += 1;
                            let turn_id = format!("pi-turn-{}", self.next_turn);
                            self.current = Some(turn_id.clone());
                            self.unconfirmed = false;
                            self.started_emitted = true;
                            self.last_assistant_error = None;
                            self.auto_retry_error = None;
                            let mut out = vec![crate::session::msp::Incoming::Event(
                                crate::session::msp::HostEvent::TurnStarted {
                                    turn_id: turn_id.clone(),
                                },
                            )];
                            out.push(crate::session::msp::Incoming::Response {
                                id: id_num,
                                result: Ok(serde_json::json!({
                                    "turnId": turn_id,
                                    "disposition": "steered",
                                })),
                            });
                            return out;
                        }
                        vec![crate::session::msp::Incoming::Response {
                            id: id_num,
                            result: Ok(serde_json::json!({
                                "disposition": "steered",
                            })),
                        }]
                    }
                    _ => vec![crate::session::msp::Incoming::Response {
                        id: id_num,
                        result: Err(crate::session::msp::RpcError {
                            code: 0,
                            kind: None,
                            message: "pi did not accept the steer".to_string(),
                        }),
                    }],
                }
            }
            "queue/clear" => {
                let count = data
                    .get("steering")
                    .and_then(Value::as_array)
                    .map(|steering| steering.len())
                    .unwrap_or(0);
                let keep = self.fifo.len().saturating_sub(count);
                self.fifo.truncate(keep);
                vec![crate::session::msp::Incoming::Response {
                    id: id_num,
                    result: Ok(data),
                }]
            }
            "model/set" | "thinking/set" | "turn/interrupt" => {
                vec![crate::session::msp::Incoming::Response {
                    id: id_num,
                    result: Ok(data),
                }]
            }
            _ => vec![crate::session::msp::Incoming::Response {
                id: id_num,
                result: Ok(data),
            }],
        }
    }

    fn parse_event(
        &mut self,
        line: &str,
        object: &serde_json::Map<String, Value>,
        kind: &str,
    ) -> Vec<crate::session::msp::Incoming> {
        match kind {
            "agent_start" => {
                if let Some(turn_id) = self.current.clone() {
                    if self.unconfirmed {
                        self.started_emitted = true;
                        return vec![crate::session::msp::Incoming::Event(
                            crate::session::msp::HostEvent::TurnStarted { turn_id },
                        )];
                    }
                    if !self.started_emitted {
                        self.started_emitted = true;
                        return vec![crate::session::msp::Incoming::Event(
                            crate::session::msp::HostEvent::TurnStarted { turn_id },
                        )];
                    }
                    return vec![crate::session::msp::Incoming::Event(
                        crate::session::msp::HostEvent::Ignored,
                    )];
                }
                self.next_turn += 1;
                let turn_id = format!("pi-turn-{}", self.next_turn);
                self.current = Some(turn_id.clone());
                self.unconfirmed = false;
                self.started_emitted = true;
                self.last_assistant_error = None;
                self.auto_retry_error = None;
                self.buffered_settle = None;
                vec![crate::session::msp::Incoming::Event(
                    crate::session::msp::HostEvent::TurnStarted { turn_id },
                )]
            }
            "agent_settled" => {
                let aborted = object
                    .get("aborted")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let (terminal, error) = if aborted {
                    ("cancelled".to_string(), None)
                } else if let Some(message) = self
                    .auto_retry_error
                    .clone()
                    .or_else(|| self.last_assistant_error.clone())
                {
                    (
                        "failed".to_string(),
                        Some(crate::session::msp::TurnError {
                            kind: "modelError".to_string(),
                            message,
                        }),
                    )
                } else {
                    ("completed".to_string(), None)
                };
                if let Some(turn_id) = self.current.clone() {
                    if self.unconfirmed {
                        self.buffered_settle = Some((terminal, error));
                        return vec![crate::session::msp::Incoming::Event(
                            crate::session::msp::HostEvent::Ignored,
                        )];
                    }
                    self.current = None;
                    self.unconfirmed = false;
                    self.started_emitted = false;
                    self.last_assistant_error = None;
                    self.auto_retry_error = None;
                    let buffered = self.buffered_settle.take();
                    debug_assert!(buffered.is_none());
                    return vec![crate::session::msp::Incoming::Event(
                        crate::session::msp::HostEvent::TurnCompleted {
                            turn_id,
                            terminal,
                            error,
                        },
                    )];
                }
                vec![crate::session::msp::Incoming::Event(
                    crate::session::msp::HostEvent::Ignored,
                )]
            }
            "message_end" => self.parse_message_end(object),
            "message_start"
            | "message_update"
            | "turn_start"
            | "turn_end"
            | "agent_end"
            | "queue_update"
            | "tool_execution_update"
            | "compaction_start"
            | "compaction_end"
            | "auto_retry_start"
            | "extension_error"
            | "session_info_changed"
            | "thinking_level_changed"
            | "tool_execution_start"
            | "tool_execution_end"
            | "auto_retry_end"
            | "extension_ui_request" => self.parse_other(line, object, kind),
            _ => vec![crate::session::msp::Incoming::Event(
                crate::session::msp::HostEvent::Ignored,
            )],
        }
    }

    fn parse_other(
        &mut self,
        line: &str,
        object: &serde_json::Map<String, Value>,
        kind: &str,
    ) -> Vec<crate::session::msp::Incoming> {
        let _ = line;
        match kind {
            "tool_execution_start" => {
                let turn_id = self.current.clone().unwrap_or_default();
                let tool = object
                    .get("toolName")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let call_id = object
                    .get("toolCallId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                vec![crate::session::msp::Incoming::Event(
                    crate::session::msp::HostEvent::ToolStarted {
                        turn_id,
                        tool,
                        call_id,
                    },
                )]
            }
            "tool_execution_end" => {
                let turn_id = self.current.clone().unwrap_or_default();
                let tool = object
                    .get("toolName")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let call_id = object
                    .get("toolCallId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let is_error = object
                    .get("isError")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                vec![crate::session::msp::Incoming::Event(
                    crate::session::msp::HostEvent::ToolCompleted {
                        turn_id,
                        tool,
                        call_id,
                        status: if is_error {
                            "failed".to_string()
                        } else {
                            "completed".to_string()
                        },
                    },
                )]
            }
            "auto_retry_end" => {
                let success = object
                    .get("success")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                if !success {
                    let message = object
                        .get("finalError")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    self.auto_retry_error = Some(message);
                }
                vec![crate::session::msp::Incoming::Event(
                    crate::session::msp::HostEvent::Ignored,
                )]
            }
            "extension_ui_request" => {
                let method = object
                    .get("method")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                match method {
                    "select" | "confirm" | "input" | "editor" => {
                        let id = object.get("id").cloned().unwrap_or(Value::Null);
                        vec![crate::session::msp::Incoming::HostRequest {
                            id,
                            method: method.to_string(),
                        }]
                    }
                    _ => vec![crate::session::msp::Incoming::Event(
                        crate::session::msp::HostEvent::Ignored,
                    )],
                }
            }
            _ => vec![crate::session::msp::Incoming::Event(
                crate::session::msp::HostEvent::Ignored,
            )],
        }
    }

    fn parse_message_end(
        &mut self,
        object: &serde_json::Map<String, Value>,
    ) -> Vec<crate::session::msp::Incoming> {
        let message = object.get("message");
        let role = message
            .and_then(|message| message.get("role"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        let turn_id = self.current.clone().unwrap_or_default();
        match role {
            "user" => {
                let text = message
                    .and_then(|message| message.get("content"))
                    .and_then(Value::as_array)
                    .map(|content| {
                        content
                            .iter()
                            .filter_map(|block| {
                                if block.get("type").and_then(Value::as_str) == Some("text") {
                                    block.get("text").and_then(Value::as_str)
                                } else {
                                    None
                                }
                            })
                            .collect::<Vec<_>>()
                            .join("")
                    })
                    .unwrap_or_default();
                let command_id = self.fifo.pop_front();
                vec![crate::session::msp::Incoming::Event(
                    crate::session::msp::HostEvent::UserMessage {
                        turn_id,
                        text,
                        command_id,
                    },
                )]
            }
            "assistant" => {
                let content = message
                    .and_then(|message| message.get("content"))
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let text = content
                    .iter()
                    .filter_map(|block| {
                        if block.get("type").and_then(Value::as_str) == Some("text") {
                            block.get("text").and_then(Value::as_str)
                        } else {
                            None
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("");
                let stop_reason = message
                    .and_then(|message| message.get("stopReason"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                self.last_assistant_error = if stop_reason == "error" {
                    Some(
                        message
                            .and_then(|message| message.get("errorMessage"))
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                    )
                } else {
                    None
                };
                let usage = message.and_then(|message| message.get("usage"));
                let input = usage
                    .and_then(|usage| usage.get("input"))
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let cache_read = usage
                    .and_then(|usage| usage.get("cacheRead"))
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let cache_write = usage
                    .and_then(|usage| usage.get("cacheWrite"))
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let output = usage
                    .and_then(|usage| usage.get("output"))
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let total = usage
                    .and_then(|usage| usage.get("totalTokens"))
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let prompt = input.saturating_add(cache_read).saturating_add(cache_write);
                self.prompt_cumulative = self.prompt_cumulative.saturating_add(prompt);
                self.output_cumulative = self.output_cumulative.saturating_add(output);
                self.total_cumulative = self.total_cumulative.saturating_add(total);
                vec![
                    crate::session::msp::Incoming::Event(
                        crate::session::msp::HostEvent::AgentMessage {
                            turn_id: turn_id.clone(),
                            text,
                        },
                    ),
                    crate::session::msp::Incoming::Event(
                        crate::session::msp::HostEvent::TokenUsage {
                            prompt: self.prompt_cumulative,
                            output: self.output_cumulative,
                            total: self.total_cumulative,
                        },
                    ),
                ]
            }
            _ => vec![crate::session::msp::Incoming::Event(
                crate::session::msp::HostEvent::Ignored,
            )],
        }
    }
}

#[cfg(test)]
mod tests {
    const PROMPT_BASIC: &str =
        include_str!("../../tests/fixtures/contract/pi-rpc/prompt-basic.jsonl");
    const PROMPT_TOOLS: &str =
        include_str!("../../tests/fixtures/contract/pi-rpc/prompt-tools.jsonl");
    const STEER_ABORT: &str =
        include_str!("../../tests/fixtures/contract/pi-rpc/steer-abort.jsonl");
    const AFTER_ABORT: &str =
        include_str!("../../tests/fixtures/contract/pi-rpc/after-abort.jsonl");
    const SET_MODEL_BAD: &str =
        include_str!("../../tests/fixtures/contract/pi-rpc/set-model-bad.jsonl");

    fn check_response_id(value: &serde_json::Value) {
        match value {
            serde_json::Value::Object(object) => {
                for (key, inner) in object {
                    if key == "responseId" {
                        assert_eq!(
                            inner.as_str().unwrap_or_default(),
                            "resp_redacted",
                            "responseId must be resp_redacted"
                        );
                    } else {
                        check_response_id(inner);
                    }
                }
            }
            serde_json::Value::Array(items) => {
                for item in items {
                    check_response_id(item);
                }
            }
            _ => {}
        }
    }

    #[test]
    fn model_grammar_accepts_and_rejects() {
        let ok = super::parse_model("openai/gpt-6-luna").unwrap();
        assert_eq!(ok.provider, "openai");
        assert_eq!(ok.id, "gpt-6-luna");
        assert_eq!(ok.level, None);
        let leveled = super::parse_model("openai/gpt-6-luna:xhigh").unwrap();
        assert_eq!(leveled.provider, "openai");
        assert_eq!(leveled.id, "gpt-6-luna");
        assert_eq!(leveled.level.as_deref(), Some("xhigh"));
        let spark = super::parse_model("opencode-go/muse-spark-1.3-contributor").unwrap();
        assert_eq!(spark.provider, "opencode-go");
        assert_eq!(spark.id, "muse-spark-1.3-contributor");
        assert_eq!(spark.level, None);
        let nested = super::parse_model("openrouter/anthropic/claude-x").unwrap();
        assert_eq!(nested.provider, "openrouter");
        assert_eq!(nested.id, "anthropic/claude-x");
        assert_eq!(nested.level, None);
        for level in super::LEVELS {
            let model = super::parse_model(&format!("a/b:{level}")).unwrap();
            assert_eq!(model.id, "b");
            assert_eq!(model.level.as_deref(), Some(level));
            assert!(
                super::parse_model(&format!("a/:{level}")).is_err(),
                "must reject an empty id at level {level}"
            );
        }
        let free = super::parse_model("a/b:free").unwrap();
        assert_eq!(free.id, "b:free");
        assert_eq!(free.level, None);
        let ultra = super::parse_model("a/b:ultra").unwrap();
        assert_eq!(ultra.id, "b:ultra");
        assert_eq!(ultra.level, None);
        for bad in [
            "",
            "nomodel",
            "/x",
            "x/",
            "a b/c",
            "a/b c",
            "-x/y",
            "a/b:",
            "a/b:\u{0}",
            "a\0/b",
        ] {
            assert!(super::parse_model(bad).is_err(), "must reject {bad:?}");
        }
    }

    #[test]
    fn model_argv_matches_contract() {
        let argv = super::host_argv(
            "openai/gpt-6-luna:xhigh",
            "sid",
            std::path::Path::new("/tmp/dir"),
            std::path::Path::new("/tmp/brief"),
        );
        assert_eq!(
            argv,
            [
                "--mode",
                "rpc",
                "--model",
                "openai/gpt-6-luna:xhigh",
                "--session-id",
                "sid",
                "--session-dir",
                "/tmp/dir",
                "--append-system-prompt",
                "/tmp/brief",
            ]
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>()
        );
        assert!(!argv.iter().any(|arg| arg == "--no-session"));
        assert!(!argv.iter().any(|arg| arg == "--tools"));
        assert!(!argv.iter().any(|arg| arg == "--approve"));
        assert!(!argv.iter().any(|arg| arg.starts_with("--no-")));
    }

    #[test]
    fn request_encoding_matches_wire() {
        use serde_json::json;
        let mut wire = super::Wire::new();
        let start = wire
            .encode(
                2,
                "turn/start",
                &json!({"input":[{"type":"text","text":"hello"}],"commandId":"c1"}),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&start).unwrap(),
            json!({"id":"2","type":"prompt","message":"hello"})
        );
        assert!(!start.contains("streamingBehavior"));
        let mut wire = super::Wire::new();
        let steer = wire
            .encode(
                3,
                "turn/steer",
                &json!({"input":[{"type":"text","text":"more"}],"commandId":"c2"}),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&steer).unwrap(),
            json!({"id":"3","type":"prompt","message":"more","streamingBehavior":"steer"})
        );
        let mut wire = super::Wire::new();
        let clear = wire.encode(4, "queue/clear", &json!({})).unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&clear).unwrap(),
            json!({"id":"4","type":"clear_queue"})
        );
        let mut wire = super::Wire::new();
        let abort = wire.encode(5, "turn/interrupt", &json!({})).unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&abort).unwrap(),
            json!({"id":"5","type":"abort"})
        );
        let mut wire = super::Wire::new();
        let model = wire
            .encode(
                1,
                "model/set",
                &json!({"provider":"openai","modelId":"gpt-6-luna:xhigh"}),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&model).unwrap(),
            json!({"id":"1","type":"set_model","provider":"openai","modelId":"gpt-6-luna"})
        );
        let mut wire = super::Wire::new();
        let thinking = wire
            .encode(6, "thinking/set", &json!({"level":"xhigh"}))
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&thinking).unwrap(),
            json!({"id":"6","type":"set_thinking_level","level":"xhigh"})
        );
        let mut wire = super::Wire::new();
        assert!(wire.encode(7, "nope/unknown", &json!({})).is_err());
        let mut wire = super::Wire::new();
        let tricky = wire
            .encode(
                8,
                "turn/start",
                &json!({"input":[{"type":"text","text":"a\"b\nc\u{1f600}"}],"commandId":"c3"}),
            )
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&tricky).unwrap();
        assert_eq!(parsed["message"], json!("a\"b\nc\u{1f600}"));
    }

    #[test]
    fn response_translation_matches_wire() {
        use crate::session::msp::{Disposition, Incoming, ack_disposition};
        use serde_json::json;
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                1,
                "turn/start",
                &json!({"input":[{"type":"text","text":"hello"}],"commandId":"c1"}),
            )
            .unwrap();
        let out = wire.parse(
            r#"{"id":"1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
        );
        assert_eq!(out.len(), 1);
        match &out[0] {
            Incoming::Response { id, result } => {
                assert_eq!(*id, 1);
                let value = result.as_ref().unwrap();
                assert_eq!(value["turnId"], json!("pi-turn-1"));
                assert_eq!(ack_disposition(value), Disposition::Started);
            }
            other => panic!("expected Response, got {other:?}"),
        }
        let _ = wire
            .encode(
                2,
                "turn/start",
                &json!({"input":[{"type":"text","text":"hi"}],"commandId":"c2"}),
            )
            .unwrap();
        let out = wire.parse(
            r#"{"id":"2","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
        );
        match &out[0] {
            Incoming::Response { result, .. } => {
                assert_eq!(result.as_ref().unwrap()["turnId"], json!("pi-turn-2"));
            }
            other => panic!("expected Response, got {other:?}"),
        }
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                3,
                "turn/steer",
                &json!({"input":[{"type":"text","text":"more"}],"commandId":"s1"}),
            )
            .unwrap();
        let out = wire.parse(
            r#"{"id":"3","type":"response","command":"prompt","success":true,"data":{"disposition":"queued"}}"#,
        );
        assert_eq!(out.len(), 1);
        match &out[0] {
            Incoming::Response { result, .. } => {
                assert_eq!(result.as_ref().unwrap()["disposition"], json!("steered"));
            }
            other => panic!("expected Response, got {other:?}"),
        }
        assert_eq!(wire.queued_steers(), 1);
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                4,
                "turn/steer",
                &json!({"input":[{"type":"text","text":"more"}],"commandId":"s2"}),
            )
            .unwrap();
        let out = wire.parse(
            r#"{"id":"4","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
        );
        assert_eq!(out.len(), 2);
        match &out[0] {
            Incoming::Event(crate::session::msp::HostEvent::TurnStarted { turn_id }) => {
                assert_eq!(turn_id, "pi-turn-1");
            }
            other => panic!("first must be TurnStarted, got {other:?}"),
        }
        match &out[1] {
            Incoming::Response { result, .. } => {
                assert_eq!(result.as_ref().unwrap()["disposition"], json!("steered"));
            }
            other => panic!("second must be Response, got {other:?}"),
        }
        let after = wire.parse(r#"{"type":"agent_start"}"#);
        assert!(after.iter().all(|incoming| !matches!(
            incoming,
            Incoming::Event(crate::session::msp::HostEvent::TurnStarted { .. })
        )));
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                5,
                "turn/start",
                &json!({"input":[{"type":"text","text":"hi"}],"commandId":"c5"}),
            )
            .unwrap();
        let out = wire.parse(
            r#"{"id":"5","type":"response","command":"prompt","success":true,"data":{"disposition":"handled"}}"#,
        );
        match &out[0] {
            Incoming::Response {
                result: Err(error), ..
            } => {
                assert_eq!(error.kind.as_deref(), Some("handled"));
            }
            other => panic!("expected handled Err, got {other:?}"),
        }
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                6,
                "turn/start",
                &json!({"input":[{"type":"text","text":"hi"}],"commandId":"c6"}),
            )
            .unwrap();
        let out = wire.parse(
            r#"{"id":"6","type":"response","command":"prompt","success":false,"error":"boom"}"#,
        );
        match &out[0] {
            Incoming::Response {
                result: Err(error), ..
            } => {
                assert_eq!(error.message, "boom");
            }
            other => panic!("expected Err boom, got {other:?}"),
        }
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                7,
                "turn/start",
                &json!({"input":[{"type":"text","text":"hi"}],"commandId":"c7"}),
            )
            .unwrap();
        let out = wire.parse(
            r#"{"id":"7","type":"response","command":"prompt","success":true,"data":{"disposition":"queued"}}"#,
        );
        assert!(matches!(&out[0], Incoming::Response { result: Err(_), .. }));
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                10,
                "model/set",
                &json!({"provider":"opencode-go","modelId":"no-such-model-for-rpc-probe"}),
            )
            .unwrap();
        let mut bad: serde_json::Value =
            serde_json::from_str(SET_MODEL_BAD.lines().nth(1).unwrap()[2..].trim()).unwrap();
        bad["id"] = json!("10");
        let out = wire.parse(&bad.to_string());
        match &out[0] {
            Incoming::Response {
                result: Err(error), ..
            } => {
                assert_eq!(
                    error.message,
                    "Model not found: opencode-go/no-such-model-for-rpc-probe"
                );
            }
            other => panic!("expected model Err, got {other:?}"),
        }
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                11,
                "model/set",
                &json!({"provider":"openai","modelId":"gpt-6-luna"}),
            )
            .unwrap();
        let out = wire.parse(
            r#"{"id":"11","type":"response","command":"set_model","success":true,"data":{}}"#,
        );
        assert!(matches!(&out[0], Incoming::Response { result: Ok(_), .. }));
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(12, "thinking/set", &json!({"level":"xhigh"}))
            .unwrap();
        let out = wire.parse(
            r#"{"id":"12","type":"response","command":"set_thinking_level","success":true}"#,
        );
        assert!(matches!(&out[0], Incoming::Response { result: Ok(_), .. }));
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(13, "thinking/set", &json!({"level":"xhigh"}))
            .unwrap();
        let out = wire.parse(
            r#"{"id":"13","type":"response","command":"set_thinking_level","success":false,"error":"x"}"#,
        );
        match &out[0] {
            Incoming::Response {
                result: Err(error), ..
            } => assert_eq!(error.message, "x"),
            other => panic!("expected Err x, got {other:?}"),
        }
        let mut wire = super::Wire::new();
        let _ = wire
            .encode(
                20,
                "turn/steer",
                &json!({"input":[{"type":"text","text":"more"}],"commandId":"s20"}),
            )
            .unwrap();
        let _ = wire.parse(
            r#"{"id":"20","type":"response","command":"prompt","success":true,"data":{"disposition":"queued"}}"#,
        );
        assert_eq!(wire.queued_steers(), 1);
        let _ = wire.encode(21, "queue/clear", &json!({})).unwrap();
        let out = wire.parse(
            r#"{"id":"21","type":"response","command":"clear_queue","success":true,"data":{"steering":["more"],"followUp":[]}}"#,
        );
        assert!(matches!(&out[0], Incoming::Response { result: Ok(_), .. }));
        assert_eq!(wire.queued_steers(), 0);
        let mut wire = super::Wire::new();
        assert!(matches!(
            wire.parse(
                r#"{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#
            )[0],
            Incoming::Unparsed(_)
        ));
        assert!(matches!(
            wire.parse(
                r#"{"id":"abc","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#
            )[0],
            Incoming::Unparsed(_)
        ));
        let out = wire.parse(
            r#"{"id":"999","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
        );
        assert!(matches!(&out[0], Incoming::Response { .. }));
        assert_eq!(wire.queued_steers(), 0);
    }

    struct ReplayFrame {
        kind: String,
        status: crate::session::state::Status,
        logs: Vec<serde_json::Value>,
    }

    struct ReplayResult {
        incomings: Vec<crate::session::msp::Incoming>,
        frames: Vec<ReplayFrame>,
    }

    fn replay(
        text: &str,
        wire: &mut super::Wire,
        state: &mut crate::session::state::State,
    ) -> ReplayResult {
        use crate::session::msp::Incoming;
        use crate::session::state as st;
        let mut result = ReplayResult {
            incomings: Vec::new(),
            frames: Vec::new(),
        };
        let mut next_id: i64 = 1;
        let mut recorded_to_wire: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        let mut command_seq: u64 = 0;
        let mut now: u64 = 1000;
        for line in text.lines() {
            now += 10;
            if let Some(frame) = line.strip_prefix("> ") {
                let req: serde_json::Value = serde_json::from_str(frame).unwrap();
                let kind = req.get("type").and_then(|v| v.as_str()).unwrap_or_default();
                let recorded = req.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let wire_id = next_id;
                next_id += 1;
                recorded_to_wire.insert(recorded.to_string(), wire_id.to_string());
                match kind {
                    "prompt" => {
                        let text_msg = req
                            .get("message")
                            .and_then(|v| v.as_str())
                            .unwrap_or_default();
                        let is_steer =
                            req.get("streamingBehavior").and_then(|v| v.as_str()) == Some("steer");
                        command_seq += 1;
                        let cmd_id = format!("cmd-{command_seq}");
                        if is_steer {
                            st::note_steer(state, &cmd_id);
                            let params = serde_json::json!({
                                "input": [{"type": "text", "text": text_msg}],
                                "commandId": cmd_id,
                            });
                            let _ = wire.encode(wire_id, "turn/steer", &params).unwrap();
                        } else {
                            assert!(st::begin_turn(state, now));
                            let params = serde_json::json!({
                                "input": [{"type": "text", "text": text_msg}],
                                "commandId": cmd_id,
                            });
                            let _ = wire.encode(wire_id, "turn/start", &params).unwrap();
                        }
                    }
                    "clear_queue" => {
                        let _ = wire
                            .encode(wire_id, "queue/clear", &serde_json::json!({}))
                            .unwrap();
                    }
                    "abort" => {
                        let _ = wire
                            .encode(wire_id, "turn/interrupt", &serde_json::json!({}))
                            .unwrap();
                    }
                    _ => panic!("unexpected stdin type {kind}"),
                }
                result.frames.push(ReplayFrame {
                    kind: kind.to_string(),
                    status: state.status.clone(),
                    logs: Vec::new(),
                });
                continue;
            }
            let Some(frame) = line.strip_prefix("< ") else {
                continue;
            };
            let mut val: serde_json::Value = serde_json::from_str(frame).unwrap();
            let kind = val
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            if kind == "response"
                && let Some(id) = val.get("id").and_then(|v| v.as_str())
                && let Some(mapped) = recorded_to_wire.remove(id)
            {
                val["id"] = serde_json::Value::String(mapped);
            }
            let incomings = wire.parse(&val.to_string());
            let mut logs = Vec::new();
            for incoming in &incomings {
                match incoming {
                    Incoming::Response { result, .. } => {
                        if let Ok(value) = result {
                            let is_start = value.get("turnId").is_some()
                                && value.get("disposition").and_then(|v| v.as_str())
                                    == Some("started");
                            if is_start {
                                let turn_id = value["turnId"].as_str().unwrap_or_default();
                                let disposition = crate::session::msp::ack_disposition(value);
                                let _ = st::apply_ack(state, turn_id, disposition, now);
                            }
                        } else {
                            st::abort_turn(state, now);
                        }
                    }
                    Incoming::Event(event) => logs.extend(st::apply_event(state, event, now)),
                    _ => {}
                }
            }
            result.frames.push(ReplayFrame {
                kind: kind.to_string(),
                status: state.status.clone(),
                logs,
            });
            result.incomings.extend(incomings);
        }
        result
    }

    fn non_ignored(incomings: &[crate::session::msp::Incoming]) -> Vec<String> {
        use crate::session::msp::{HostEvent, Incoming};
        let mut kinds = Vec::new();
        for incoming in incomings {
            match incoming {
                Incoming::Response { .. } => kinds.push("Response".to_string()),
                Incoming::Event(event) => match event {
                    HostEvent::TurnStarted { .. } => kinds.push("TurnStarted".to_string()),
                    HostEvent::TurnCompleted { .. } => kinds.push("TurnCompleted".to_string()),
                    HostEvent::UserMessage { .. } => kinds.push("UserMessage".to_string()),
                    HostEvent::AgentMessage { .. } => kinds.push("AgentMessage".to_string()),
                    HostEvent::TokenUsage { .. } => kinds.push("TokenUsage".to_string()),
                    HostEvent::ToolStarted { .. } => kinds.push("ToolStarted".to_string()),
                    HostEvent::ToolCompleted { .. } => kinds.push("ToolCompleted".to_string()),
                    HostEvent::Ignored => {}
                    _ => kinds.push("Other".to_string()),
                },
                _ => kinds.push("Other".to_string()),
            }
        }
        kinds
    }

    #[test]
    fn replay_prompt_basic_matches_contract() {
        use crate::session::state as st;
        let mut wire = super::Wire::new();
        let mut state = st::new_state("s-basic", "m", "/work", "/inbox", 1000);
        let replayed = replay(PROMPT_BASIC, &mut wire, &mut state);
        let incomings = replayed.incomings;
        let kinds = non_ignored(&incomings);
        assert_eq!(
            kinds,
            vec![
                "Response",
                "TurnStarted",
                "UserMessage",
                "AgentMessage",
                "TokenUsage",
                "TurnCompleted"
            ]
        );
        // Last event is the agent_settled line and none produced earlier.
        let last = incomings
            .iter()
            .rfind(|i| {
                !matches!(
                    i,
                    crate::session::msp::Incoming::Event(crate::session::msp::HostEvent::Ignored)
                )
            })
            .unwrap();
        assert!(matches!(
            last,
            crate::session::msp::Incoming::Event(
                crate::session::msp::HostEvent::TurnCompleted { terminal, .. }
            ) if terminal == "completed"
        ));
        assert_eq!(state.status, crate::session::state::Status::Idle);
        assert_eq!(state.turn_count, 1);
        assert_eq!(state.usage.prompt_tokens, 1909);
        assert_eq!(state.usage.output_tokens, 17);
        assert_eq!(state.usage.total_tokens, 1926);
        // Agent text is READY.
        let agent_text = incomings
            .iter()
            .filter_map(|i| match i {
                crate::session::msp::Incoming::Event(
                    crate::session::msp::HostEvent::AgentMessage { text, .. },
                ) => Some(text.clone()),
                _ => None,
            })
            .next_back()
            .unwrap();
        assert_eq!(agent_text, "READY");
        // TurnCompleted is pi-turn-1 completed.
        match last {
            crate::session::msp::Incoming::Event(
                crate::session::msp::HostEvent::TurnCompleted {
                    turn_id, terminal, ..
                },
            ) => {
                assert_eq!(turn_id, "pi-turn-1");
                assert_eq!(terminal, "completed");
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn replay_prompt_tools_matches_contract() {
        use crate::session::msp::{HostEvent, Incoming};
        use crate::session::state as st;

        let mut wire = super::Wire::new();
        let mut state = st::new_state("s-tools", "m", "/work", "/inbox", 1000);
        let replayed = replay(PROMPT_TOOLS, &mut wire, &mut state);
        let mut tool_started = Vec::new();
        let mut tool_completed = Vec::new();
        for incoming in &replayed.incomings {
            if let Incoming::Event(event) = incoming {
                match event {
                    HostEvent::ToolStarted { tool, .. } => tool_started.push(tool.clone()),
                    HostEvent::ToolCompleted { tool, status, .. } => {
                        tool_completed.push((tool.clone(), status.clone()));
                    }
                    _ => {}
                }
            }
        }
        let first_turn_end = replayed
            .frames
            .iter()
            .find(|frame| frame.kind == "turn_end");
        assert!(first_turn_end.is_some_and(|frame| frame.status == st::Status::Running));
        assert_eq!(state.status, st::Status::Idle);
        assert_eq!(state.turn_count, 1);
        assert_eq!(tool_started, vec!["write".to_string(), "bash".to_string()]);
        assert_eq!(
            tool_completed,
            vec![
                ("write".to_string(), "completed".to_string()),
                ("bash".to_string(), "completed".to_string())
            ]
        );
        assert_eq!(state.usage.prompt_tokens, 4724);
        assert_eq!(state.usage.output_tokens, 845);
        assert_eq!(state.usage.total_tokens, 5569);
    }
    #[test]
    fn replay_steer_abort_then_after_abort() {
        use crate::session::msp::{HostEvent, Incoming};
        use crate::session::state as st;

        let mut wire = super::Wire::new();
        let mut state = st::new_state("s-abort", "m", "/work", "/inbox", 1000);
        let fixtures = format!("{STEER_ABORT}\n{AFTER_ABORT}");
        let replayed = replay(&fixtures, &mut wire, &mut state);
        let mut completions = Vec::new();
        let mut tool_status = None;
        for incoming in &replayed.incomings {
            if let Incoming::Event(event) = incoming {
                match event {
                    HostEvent::TurnCompleted {
                        turn_id,
                        terminal,
                        error,
                    } => {
                        completions.push((turn_id.clone(), terminal.clone(), error.clone()));
                    }
                    HostEvent::ToolCompleted { status, tool, .. } if tool == "bash" => {
                        tool_status = Some(status.clone());
                    }
                    _ => {}
                }
            }
        }

        assert_eq!(wire.queued_steers(), 0);
        assert_eq!(tool_status.as_deref(), Some("failed"));
        assert_eq!(completions.len(), 2);
        assert_eq!(completions[0].0, "pi-turn-1");
        assert_eq!(completions[0].1, "cancelled");
        assert!(completions[0].2.is_none());
        assert_eq!(completions[1].0, "pi-turn-2");
        assert_eq!(completions[1].1, "completed");
        assert!(completions[1].2.is_none());
        assert!(
            replayed
                .frames
                .iter()
                .flat_map(|frame| &frame.logs)
                .any(|line| {
                    line.get("kind").and_then(|value| value.as_str()) == Some("steer.unconsumed")
                        && line
                            .get("commandIds")
                            .and_then(|ids| ids.as_array())
                            .is_some_and(|ids| ids.iter().any(|id| id.as_str() == Some("cmd-2")))
                })
        );
        assert_eq!(state.status, st::Status::Idle);
        assert_eq!(state.turn_count, 2);
        assert_eq!(
            state.last_turn.as_ref().map(|turn| turn.terminal.as_str()),
            Some("completed")
        );
        assert_eq!(state.usage.prompt_tokens, 6015);
        assert_eq!(state.usage.output_tokens, 175);
        assert_eq!(state.usage.total_tokens, 6190);
    }
    #[test]
    fn races_and_echoes_behave() {
        use crate::session::msp::{HostEvent, Incoming};
        use crate::session::state as st;
        // (a) Steer queued while active, echo carries steer id, no unconsumed.
        {
            let mut wire = super::Wire::new();
            let mut state = st::new_state("s-a", "m", "/work", "/inbox", 1000);
            let mut now = 1000;
            now += 10;
            assert!(st::begin_turn(&mut state, now));
            let _ = wire
                .encode(
                    1,
                    "turn/start",
                    &serde_json::json!({"input":[{"type":"text","text":"hello"}],"commandId":"start-a"}),
                )
                .unwrap();
            let out = wire.parse(
                r#"{"id":"1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
            );
            for incoming in &out {
                if let Incoming::Response {
                    result: Ok(value), ..
                } = incoming
                {
                    let turn_id = value["turnId"].as_str().unwrap();
                    let disp = crate::session::msp::ack_disposition(value);
                    let _ = st::apply_ack(&mut state, turn_id, disp, now);
                }
            }
            now += 10;
            let out = wire.parse(r#"{"type":"agent_start"}"#);
            for incoming in out {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, &event, now);
                }
            }
            now += 10;
            let out = wire.parse(
                r#"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#,
            );
            for incoming in out {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, &event, now);
                }
            }
            assert_eq!(wire.queued_steers(), 0);
            now += 10;
            st::note_steer(&mut state, "steer-a");
            let _ = wire
                .encode(
                    2,
                    "turn/steer",
                    &serde_json::json!({"input":[{"type":"text","text":"more"}],"commandId":"steer-a"}),
                )
                .unwrap();
            let out = wire.parse(
                r#"{"id":"2","type":"response","command":"prompt","success":true,"data":{"disposition":"queued"}}"#,
            );
            assert_eq!(wire.queued_steers(), 1);
            let _ = out;
            now += 10;
            let out = wire.parse(
                r#"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"more"}]}}"#,
            );
            assert_eq!(out.len(), 1);
            match &out[0] {
                Incoming::Event(HostEvent::UserMessage { command_id, .. }) => {
                    assert_eq!(command_id.as_deref(), Some("steer-a"));
                }
                other => panic!("expected UserMessage, got {other:?}"),
            }
            for incoming in out {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, &event, now);
                }
            }
            assert_eq!(wire.queued_steers(), 0);
            assert!(state.pending_steers.is_empty());
            now += 10;
            let out = wire.parse(r#"{"type":"agent_settled","aborted":false}"#);
            let mut lines = Vec::new();
            for incoming in out {
                if let Incoming::Event(event) = incoming {
                    lines.extend(st::apply_event(&mut state, &event, now));
                }
            }
            assert!(
                !lines
                    .iter()
                    .any(|line| line.get("kind").and_then(|v| v.as_str())
                        == Some("steer.unconsumed"))
            );
        }
        // (b) FIFO alignment: start + steer = 2, echoes pop front.
        {
            let mut wire = super::Wire::new();
            let _ = wire
                .encode(
                    1,
                    "turn/start",
                    &serde_json::json!({"input":[{"type":"text","text":"hi"}],"commandId":"start-b"}),
                )
                .unwrap();
            let _ = wire.parse(
                r#"{"id":"1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
            );
            let _ = wire
                .encode(
                    2,
                    "turn/steer",
                    &serde_json::json!({"input":[{"type":"text","text":"more"}],"commandId":"steer-b"}),
                )
                .unwrap();
            let _ = wire.parse(
                r#"{"id":"2","type":"response","command":"prompt","success":true,"data":{"disposition":"queued"}}"#,
            );
            assert_eq!(wire.queued_steers(), 2);
            let out = wire.parse(
                r#"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#,
            );
            match &out[0] {
                Incoming::Event(HostEvent::UserMessage { command_id, .. }) => {
                    assert_eq!(command_id.as_deref(), Some("start-b"));
                }
                other => panic!("first echo must pop start, got {other:?}"),
            }
            assert_eq!(wire.queued_steers(), 1);
            let out = wire.parse(
                r#"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"more"}]}}"#,
            );
            match &out[0] {
                Incoming::Event(HostEvent::UserMessage { command_id, .. }) => {
                    assert_eq!(command_id.as_deref(), Some("steer-b"));
                }
                other => panic!("second echo must pop steer, got {other:?}"),
            }
            assert_eq!(wire.queued_steers(), 0);
        }
        // (c) Idle race: steer started starts next turn.
        {
            let mut wire = super::Wire::new();
            let mut state = st::new_state("s-c", "m", "/work", "/inbox", 1000);
            let mut now = 1000;
            st::note_steer(&mut state, "steer-c");
            let _ = wire
                .encode(
                    1,
                    "turn/steer",
                    &serde_json::json!({"input":[{"type":"text","text":"more"}],"commandId":"steer-c"}),
                )
                .unwrap();
            let out = wire.parse(
                r#"{"id":"1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
            );
            assert_eq!(out.len(), 2);
            now += 10;
            for incoming in &out {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, event, now);
                }
            }
            assert_eq!(state.status, crate::session::state::Status::Running);
            assert_eq!(state.active_turn_id.as_deref(), Some("pi-turn-1"));
            assert_eq!(state.turn_count, 1);
            now += 10;
            let after = wire.parse(r#"{"type":"agent_start"}"#);
            assert!(
                after
                    .iter()
                    .all(|i| !matches!(i, Incoming::Event(HostEvent::TurnStarted { .. })))
            );
            now += 10;
            let out = wire.parse(
                r#"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"more"}]}}"#,
            );
            for incoming in out {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, &event, now);
                }
            }
            assert!(state.pending_steers.is_empty());
            assert_eq!(state.active_turn_id.as_deref(), Some("pi-turn-1"));
        }
        // (d) Host-initiated run.
        {
            let mut wire = super::Wire::new();
            let out = wire.parse(r#"{"type":"agent_start"}"#);
            assert_eq!(out.len(), 1);
            match &out[0] {
                Incoming::Event(HostEvent::TurnStarted { turn_id }) => {
                    assert_eq!(turn_id, "pi-turn-1");
                }
                other => panic!("expected TurnStarted, got {other:?}"),
            }
        }
        // (e) Settle with no current yields no TurnCompleted.
        {
            let mut wire = super::Wire::new();
            let out = wire.parse(r#"{"type":"agent_settled","aborted":false}"#);
            assert!(
                out.iter()
                    .all(|i| !matches!(i, Incoming::Event(HostEvent::TurnCompleted { .. })))
            );
        }
        // (f) Second agent_start yields no second TurnStarted.
        {
            let mut wire = super::Wire::new();
            let first = wire.parse(r#"{"type":"agent_start"}"#);
            assert!(
                first
                    .iter()
                    .any(|i| matches!(i, Incoming::Event(HostEvent::TurnStarted { .. })))
            );
            let second = wire.parse(r#"{"type":"agent_start"}"#);
            assert!(
                second
                    .iter()
                    .all(|i| !matches!(i, Incoming::Event(HostEvent::TurnStarted { .. })))
            );
        }
        // (g) Settle before started response buffers TurnCompleted.
        {
            let mut wire = super::Wire::new();
            let mut state = st::new_state("s-g", "m", "/work", "/inbox", 1000);
            let mut now = 1000;
            now += 10;
            assert!(st::begin_turn(&mut state, now));
            let _ = wire
                .encode(
                    1,
                    "turn/start",
                    &serde_json::json!({"input":[{"type":"text","text":"hi"}],"commandId":"cmd-g"}),
                )
                .unwrap();
            now += 10;
            let out = wire.parse(r#"{"type":"agent_start"}"#);
            for incoming in out {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, &event, now);
                }
            }
            now += 10;
            let out = wire.parse(r#"{"type":"agent_settled","aborted":false}"#);
            // Buffered, so no TurnCompleted yet.
            assert!(
                out.iter()
                    .all(|i| !matches!(i, Incoming::Event(HostEvent::TurnCompleted { .. })))
            );
            for incoming in out {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, &event, now);
                }
            }
            // State is still running with no active turn (ack not yet applied).
            assert_eq!(state.status, crate::session::state::Status::Running);
            now += 10;
            let out = wire.parse(
                r#"{"id":"1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
            );
            assert_eq!(out.len(), 2);
            match &out[0] {
                Incoming::Response { .. } => {}
                other => panic!("first must be Response, got {other:?}"),
            }
            match &out[1] {
                Incoming::Event(HostEvent::TurnCompleted { .. }) => {}
                other => panic!("second must be TurnCompleted, got {other:?}"),
            }
            for incoming in out {
                match incoming {
                    Incoming::Response {
                        result: Ok(value), ..
                    } => {
                        let turn_id = value["turnId"].as_str().unwrap();
                        let disp = crate::session::msp::ack_disposition(&value);
                        let _ = st::apply_ack(&mut state, turn_id, disp, now);
                    }
                    Incoming::Event(event) => {
                        let _ = st::apply_event(&mut state, &event, now);
                    }
                    _ => {}
                }
            }
            assert_eq!(state.status, crate::session::state::Status::Idle);
            assert_eq!(state.turn_count, 1);
            assert_eq!(
                state.last_turn.as_ref().map(|t| t.terminal.as_str()),
                Some("completed")
            );
        }
    }

    #[test]
    fn recovered_retry_completes_turn() {
        use crate::session::msp::{HostEvent, Incoming};

        let mut wire = super::Wire::new();
        assert!(matches!(
            wire.parse(r#"{"type":"agent_start"}"#).as_slice(),
            [Incoming::Event(HostEvent::TurnStarted { .. })]
        ));
        let _ = wire.parse(
            r#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"529 overloaded"}}"#,
        );
        let _ = wire.parse(r#"{"type":"auto_retry_start"}"#);
        let _ = wire.parse(
            r#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"recovered"}],"stopReason":"stop"}}"#,
        );
        let _ = wire.parse(r#"{"type":"auto_retry_end","success":true}"#);

        let settled = wire.parse(r#"{"type":"agent_settled","aborted":false}"#);
        assert!(matches!(
            settled.as_slice(),
            [Incoming::Event(HostEvent::TurnCompleted {
                terminal, error: None, ..
            })] if terminal == "completed"
        ));
    }

    #[test]
    fn failures_and_ui_subprotocol() {
        use crate::session::msp::{HostEvent, Incoming};
        use crate::session::state as st;
        // Assistant error -> failed with modelError.
        {
            let mut wire = super::Wire::new();
            let mut state = st::new_state("s-f1", "m", "/work", "/inbox", 1000);
            let mut now = 1000;
            now += 10;
            assert!(st::begin_turn(&mut state, now));
            let _ = wire
                .encode(
                    1,
                    "turn/start",
                    &serde_json::json!({"input":[{"type":"text","text":"hi"}],"commandId":"c1"}),
                )
                .unwrap();
            let _ = wire.parse(
                r#"{"id":"1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#,
            );
            for incoming in wire.parse(r#"{"type":"agent_start"}"#) {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, &event, now);
                }
            }
            now += 10;
            let out = wire.parse(
                r#"{"type":"message_end","message":{"role":"assistant","content":[],"usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"stopReason":"error","errorMessage":"529 overloaded"}}"#,
            );
            for incoming in out {
                if let Incoming::Event(event) = incoming {
                    let _ = st::apply_event(&mut state, &event, now);
                }
            }
            let out = wire.parse(r#"{"type":"agent_settled","aborted":false}"#);
            let mut terminal = String::new();
            let mut error: Option<crate::session::msp::TurnError> = None;
            for incoming in out {
                if let Incoming::Event(HostEvent::TurnCompleted {
                    terminal: t,
                    error: e,
                    ..
                }) = incoming
                {
                    terminal = t;
                    error = e;
                }
            }
            assert_eq!(terminal, "failed");
            let error = error.unwrap();
            assert_eq!(error.kind, "modelError");
            assert_eq!(error.message, "529 overloaded");
        }
        // auto_retry_end failure -> failed.
        {
            let mut wire = super::Wire::new();
            let out = wire.parse(r#"{"type":"agent_start"}"#);
            assert!(
                out.iter()
                    .any(|i| matches!(i, Incoming::Event(HostEvent::TurnStarted { .. })))
            );
            let _ = wire.parse(r#"{"type":"auto_retry_end","success":false,"finalError":"x"}"#);
            let out = wire.parse(r#"{"type":"agent_settled","aborted":false}"#);
            match &out[0] {
                Incoming::Event(HostEvent::TurnCompleted {
                    terminal, error, ..
                }) => {
                    assert_eq!(terminal, "failed");
                    let error = error.as_ref().unwrap();
                    assert_eq!(error.kind, "modelError");
                    assert_eq!(error.message, "x");
                }
                other => panic!("expected failed TurnCompleted, got {other:?}"),
            }
        }
        // extension_ui_request dialogs and refusal.
        {
            let mut wire = super::Wire::new();
            for method in ["select", "confirm", "input", "editor"] {
                let line = serde_json::json!({
                    "type": "extension_ui_request",
                    "id": "uuid-1",
                    "method": method,
                })
                .to_string();
                let out = wire.parse(&line);
                assert_eq!(out.len(), 1);
                match &out[0] {
                    Incoming::HostRequest { id, method: m } => {
                        assert_eq!(id.as_str().unwrap(), "uuid-1");
                        assert_eq!(m, method);
                    }
                    other => panic!("expected HostRequest for {method}, got {other:?}"),
                }
            }
            let refusal = super::refusal(&serde_json::json!("uuid-1"));
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&refusal).unwrap(),
                serde_json::json!({"type":"extension_ui_response","id":"uuid-1","cancelled":true})
            );
            for method in [
                "notify",
                "setStatus",
                "setWidget",
                "setTitle",
                "set_editor_text",
            ] {
                let line = serde_json::json!({
                    "type": "extension_ui_request",
                    "id": "uuid-2",
                    "method": method,
                })
                .to_string();
                let out = wire.parse(&line);
                assert!(matches!(&out[0], Incoming::Event(HostEvent::Ignored)));
            }
        }
        // Unparsed shapes.
        {
            let mut wire = super::Wire::new();
            assert!(matches!(wire.parse("not json")[0], Incoming::Unparsed(_)));
            assert!(matches!(wire.parse("[]")[0], Incoming::Unparsed(_)));
            assert!(matches!(
                wire.parse(
                    r#"{"type":"response","command":"parse","success":false,"error":"Failed to parse command: x"}"#
                )[0],
                Incoming::Unparsed(_)
            ));
        }
        // Ignored high-volume frames and missing-field robustness.
        {
            let mut wire = super::Wire::new();
            for line in [
                r#"{"type":"bogus_thing"}"#,
                r#"{"type":"message_update"}"#,
                r#"{"type":"message_start"}"#,
                r#"{"type":"turn_start"}"#,
                r#"{"type":"queue_update"}"#,
                r#"{"type":"compaction_start"}"#,
                r#"{"type":"compaction_end"}"#,
                r#"{"type":"agent_start"}"#,
                r#"{"type":"agent_settled"}"#,
                r#"{"type":"message_end"}"#,
                r#"{"type":"message_end","message":{}}"#,
                r#"{"type":"message_end","message":{"role":"assistant"}}"#,
                r#"{"type":"message_end","message":{"role":"assistant","content":[]}}"#,
                r#"{"type":"tool_execution_start"}"#,
                r#"{"type":"tool_execution_end"}"#,
                r#"{"type":"auto_retry_end"}"#,
                r#"{"type":"auto_retry_end","success":false}"#,
                r#"{"type":"extension_ui_request"}"#,
                r#"{"type":"extension_ui_request","method":"notify"}"#,
                r#"{"type":"extension_error"}"#,
                r#"{"type":"turn_end"}"#,
                r#"{"type":"agent_end"}"#,
            ] {
                let out = wire.parse(line);
                assert!(!out.is_empty());
            }
            // Unknown type gives Ignored.
            let out = wire.parse(r#"{"type":"frobnicate"}"#);
            assert!(matches!(&out[0], Incoming::Event(HostEvent::Ignored)));
        }
        // Saturating usage: MAX + 1 does not panic.
        {
            let mut wire = super::Wire::new();
            let line = serde_json::json!({
                "type": "message_end",
                "message": {
                    "role": "assistant",
                    "content": [],
                    "usage": {
                        "input": u64::MAX,
                        "output": 0,
                        "cacheRead": 1,
                        "cacheWrite": 0,
                        "totalTokens": 0
                    },
                    "stopReason": "stop"
                }
            })
            .to_string();
            let out = wire.parse(&line);
            assert_eq!(out.len(), 2);
        }
        // Cumulative saturation: two MAX messages leave all at MAX.
        {
            let mut wire = super::Wire::new();
            for _ in 0..2 {
                let line = serde_json::json!({
                    "type": "message_end",
                    "message": {
                        "role": "assistant",
                        "content": [],
                        "usage": {
                            "input": u64::MAX,
                            "output": u64::MAX,
                            "cacheRead": u64::MAX,
                            "cacheWrite": u64::MAX,
                            "totalTokens": u64::MAX
                        },
                        "stopReason": "stop"
                    }
                })
                .to_string();
                let out = wire.parse(&line);
                for incoming in out {
                    if let Incoming::Event(HostEvent::TokenUsage {
                        prompt,
                        output,
                        total,
                    }) = incoming
                    {
                        assert_eq!(prompt, u64::MAX);
                        assert_eq!(output, u64::MAX);
                        assert_eq!(total, u64::MAX);
                    }
                }
            }
        }
        // clear_queue underflow: 3 listed, 1 held -> empty, no panic.
        {
            let mut wire = super::Wire::new();
            let _ = wire
                .encode(
                    1,
                    "turn/steer",
                    &serde_json::json!({"input":[{"type":"text","text":"a"}],"commandId":"s1"}),
                )
                .unwrap();
            let _ = wire.parse(
                r#"{"id":"1","type":"response","command":"prompt","success":true,"data":{"disposition":"queued"}}"#,
            );
            assert_eq!(wire.queued_steers(), 1);
            let _ = wire
                .encode(2, "queue/clear", &serde_json::json!({}))
                .unwrap();
            let out = wire.parse(
                r#"{"id":"2","type":"response","command":"clear_queue","success":true,"data":{"steering":["a","b","c"],"followUp":[]}}"#,
            );
            assert!(matches!(&out[0], Incoming::Response { result: Ok(_), .. }));
            assert_eq!(wire.queued_steers(), 0);
        }
    }

    #[test]
    fn fixtures_are_redacted_and_shaped() {
        let fixtures = [
            ("prompt-basic", PROMPT_BASIC, 18),
            ("prompt-tools", PROMPT_TOOLS, 58),
            ("steer-abort", STEER_ABORT, 34),
            ("after-abort", AFTER_ABORT, 16),
            ("set-model-bad", SET_MODEL_BAD, 2),
        ];
        for (name, text, expected_lines) in fixtures {
            let lines: Vec<&str> = text.lines().collect();
            assert_eq!(lines.len(), expected_lines, "{name} line count");
            assert!(
                lines[0].starts_with("> "),
                "{name} first line must be a stdin line"
            );
            for line in &lines {
                assert!(
                    line.starts_with("> ") || line.starts_with("< "),
                    "{name} every line starts with '> ' or '< ': {line}"
                );
                let frame = &line[2..];
                let parsed: serde_json::Value =
                    serde_json::from_str(frame).expect("{name} frame must parse as JSON");
                assert!(parsed.is_object(), "{name} frame must be a JSON object");
                check_response_id(&parsed);
            }
            for forbidden in [
                "/Users/",
                "aakshintala",
                "sessions-spike",
                "/opt/homebrew",
                "encrypted_content",
                "|fc_",
            ] {
                assert!(
                    !text.contains(forbidden),
                    "{name} must not contain {forbidden}"
                );
            }
        }
    }
}
