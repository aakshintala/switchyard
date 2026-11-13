pub const TEST_MODEL_RULING: &str = "https://github.com/example/repo/issues/1#issuecomment-1";

pub fn args_with_model_ruling<'a>(args: &[&'a str]) -> Vec<&'a str> {
    let mut out = args.to_vec();
    let starts_job = args
        .first()
        .is_some_and(|command| matches!(*command, "run" | "resume" | "start"));
    let has_model = args.windows(2).any(|pair| pair[0] == "--model");
    let has_ruling = args.contains(&"--model-ruling");
    if starts_job && has_model && !has_ruling {
        out.extend(["--model-ruling", TEST_MODEL_RULING]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn existing_backend_runs_receive_a_ruling_and_non_job_commands_do_not() {
        assert_eq!(
            args_with_model_ruling(&["run", "--model", "composer-2.5"]),
            [
                "run",
                "--model",
                "composer-2.5",
                "--model-ruling",
                TEST_MODEL_RULING
            ]
        );
        assert_eq!(
            args_with_model_ruling(&["resume", "id", "--model", "claude-sonnet-5-5"]),
            [
                "resume",
                "id",
                "--model",
                "claude-sonnet-5-5",
                "--model-ruling",
                TEST_MODEL_RULING
            ]
        );
        let explicit = [
            "run",
            "--model",
            "composer-2.5",
            "--model-ruling",
            "https://github.com/example/repo/pull/1#issuecomment-2",
        ];
        assert_eq!(args_with_model_ruling(&explicit), explicit);
        assert_eq!(args_with_model_ruling(&["resume", "id"]), ["resume", "id"]);
        assert_eq!(
            args_with_model_ruling(&["start", "--model", "muse/muse-spark-1.3-contributor"]),
            [
                "start",
                "--model",
                "muse/muse-spark-1.3-contributor",
                "--model-ruling",
                TEST_MODEL_RULING
            ]
        );
        assert_eq!(args_with_model_ruling(&["status", "id"]), ["status", "id"]);
    }
}
