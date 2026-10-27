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
