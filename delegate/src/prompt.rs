pub fn status_block() -> String {
    include_str!("status_instruction.txt")
        .trim_end_matches(['\r', '\n'])
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_block_instructs_needs_context() {
        let b = status_block();
        assert!(b.contains("STATUS: NEEDS_CONTEXT"));
        assert!(b.contains("STATUS: DONE"));
        assert!(b.to_lowercase().contains("question"));
    }

    #[test]
    fn status_block_asks_for_long_shell_timeouts() {
        assert!(status_block().contains("600 seconds"));
    }

    #[test]
    fn record_sh_reads_status_instruction_file() {
        const RECORD_SH: &str = include_str!("../scripts/record.sh");
        assert!(
            RECORD_SH.contains(r#"cat "$here/../src/status_instruction.txt""#),
            "scripts/record.sh must read src/status_instruction.txt"
        );
    }
}
