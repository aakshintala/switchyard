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
