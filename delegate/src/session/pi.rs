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
