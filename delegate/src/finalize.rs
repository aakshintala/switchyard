use crate::backends::types::BackendResult;
use crate::output::to_run_output;
use crate::pricing::compute_cost;
use crate::types::{ChangeSet, FinalizeCtx, GateResult, PriceMap, RunOutput, RunStatus};
use crate::util::Abort;
use crate::util::tail;

fn compute_change_set(ctx: &FinalizeCtx) -> Option<ChangeSet> {
    if let Some(g) = &ctx.git_delta {
        g(&ctx.cwd, ctx.head_before.as_deref())
    } else {
        crate::git::git_delta(&ctx.cwd, ctx.head_before.as_deref())
    }
}

pub fn base_output(
    res: &BackendResult,
    model: &str,
    backend: &str,
    price_map: &PriceMap,
    job_id: Option<&str>,
) -> RunOutput {
    let (cost_usd, cost_estimated) = match res.cost_usd {
        Some(cost) => (Some(cost), false),
        None => (compute_cost(res.usage.as_ref(), price_map, model), true),
    };
    let mut out = to_run_output(res, model, backend, cost_usd, cost_estimated);
    if let Some(id) = job_id {
        out.job_id = Some(id.to_string());
    }
    out
}

fn run_gate_ctx(ctx: &FinalizeCtx, cwd: &str) -> GateResult {
    if let Some(rg) = &ctx.run_gate {
        rg(&ctx.gate, cwd, ctx.signal.as_ref())
    } else {
        let opts = crate::gate::GateOpts {
            timeout_ms: ctx.gate_timeout_ms,
            signal: ctx.signal.as_ref(),
        };
        if let Some(job_id) = ctx.job_id.as_deref() {
            crate::gate::run_gate_for_job(&ctx.gate, cwd, job_id, opts)
        } else {
            crate::gate::run_gate(&ctx.gate, cwd, opts)
        }
    }
}

pub fn finalize_run(res: &BackendResult, ctx: &FinalizeCtx) -> RunOutput {
    let mut out = base_output(
        res,
        &ctx.model,
        &ctx.backend,
        &ctx.price_map,
        ctx.job_id.as_deref(),
    );
    if (!res.clean_exit || out.status == RunStatus::Error) && !res.stderr.is_empty() {
        out.stderr_tail = Some(tail(&res.stderr, 2048));
    }
    let mut concerns: Vec<String> = Vec::new();
    if !ctx.gate.is_empty() {
        let gate_result = run_gate_ctx(ctx, &ctx.cwd);
        if !gate_result.passed && out.status == RunStatus::Done {
            out.status = RunStatus::DoneWithConcerns;
        }
        out.gate_result = Some(gate_result);
    }
    if let Some(cs) = compute_change_set(ctx) {
        if !cs.new_commits.is_empty() && !cs.uncommitted_files.is_empty() {
            concerns.push(
                "Commits landed but the working tree is still dirty: HEAD may not reflect a \
complete, buildable change. Review the uncommitted files."
                    .into(),
            );
            if out.status == RunStatus::Done {
                out.status = RunStatus::DoneWithConcerns;
            }
        }
        out.change_set = Some(cs);
    }
    // A non-empty denial list downgrades DONE. ERROR stays ERROR; the objects are already
    // on the record from `to_run_output`.
    if !res.permission_denials.is_empty() && out.status != RunStatus::Error {
        concerns.push(format!(
            "permission denied: {}",
            denial_names(&res.permission_denials)
        ));
        out.status = RunStatus::DoneWithConcerns;
    }
    if !concerns.is_empty() {
        out.concerns = Some(concerns);
    }
    out
}

fn denial_names(denials: &[serde_json::Value]) -> String {
    denials
        .iter()
        .map(|d| {
            d.get("tool_name")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .unwrap_or("unknown")
        })
        .collect::<Vec<_>>()
        .join(", ")
}

pub fn finalize_stall(res: &BackendResult, ctx: &FinalizeCtx) -> RunOutput {
    let mut out = base_output(
        res,
        &ctx.model,
        &ctx.backend,
        &ctx.price_map,
        ctx.job_id.as_deref(),
    );
    if !res.stderr.is_empty() {
        out.stderr_tail = Some(tail(&res.stderr, 2048));
    }
    if let Some(cs) = compute_change_set(ctx) {
        out.change_set = Some(cs);
    }
    out
}

pub fn default_finalize_ctx(cwd: &str, model: &str, backend: &str) -> FinalizeCtx {
    FinalizeCtx {
        cwd: cwd.into(),
        head_before: None,
        gate: String::new(),
        gate_timeout_ms: None,
        model: model.into(),
        backend: backend.into(),
        price_map: Default::default(),
        job_id: None,
        run_gate: None,
        signal: None::<Abort>,
        git_delta: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ChangeSet, GateResult, Price, RunStatus, Usage};

    fn base_ctx() -> FinalizeCtx {
        let mut ctx = default_finalize_ctx("/repo", "composer-2.5", "cursor");
        ctx.git_delta = Some(Box::new(|_, _| None));
        ctx
    }

    fn ok_result() -> BackendResult {
        BackendResult {
            text: "done\nSTATUS: DONE".into(),
            is_error: Some(false),
            clean_exit: true,
            stderr: String::new(),
            ..Default::default()
        }
    }

    fn dirty() -> ChangeSet {
        ChangeSet {
            head_before: Some("aaa".into()),
            head_after: Some("bbb".into()),
            new_commits: vec!["bbb".into()],
            files_changed: vec!["x".into()],
            diffstat: "x | 1 +".into(),
            uncommitted_files: vec!["y".into()],
            dirty_after: true,
        }
    }

    #[test]
    fn stderr_absent_on_clean_done() {
        let mut res = ok_result();
        res.stderr = "some noise".into();
        let out = finalize_run(&res, &base_ctx());
        assert_eq!(out.status, RunStatus::Done);
        assert!(out.stderr_tail.is_none());
    }

    #[test]
    fn stderr_present_on_non_clean() {
        let res = BackendResult {
            clean_exit: false,
            stderr: "boom".into(),
            ..Default::default()
        };
        let out = finalize_run(&res, &base_ctx());
        assert_eq!(out.status, RunStatus::Error);
        assert_eq!(out.stderr_tail.as_deref(), Some("boom"));
    }

    #[test]
    fn failing_gate_downgrades() {
        let mut ctx = base_ctx();
        ctx.gate = "make test".into();
        ctx.run_gate = Some(Box::new(|_, _, _| GateResult {
            command: "make test".into(),
            exit_code: 1,
            passed: false,
            output_tail: "FAIL".into(),
            output_path: None,
            error: None,
        }));
        let out = finalize_run(&ok_result(), &ctx);
        assert_eq!(out.status, RunStatus::DoneWithConcerns);
        assert_eq!(out.gate_result.as_ref().unwrap().exit_code, 1);
    }

    #[test]
    fn passing_gate_leaves_done() {
        let mut ctx = base_ctx();
        ctx.gate = "make test".into();
        ctx.run_gate = Some(Box::new(|_, _, _| GateResult {
            command: "make test".into(),
            exit_code: 0,
            passed: true,
            output_tail: String::new(),
            output_path: None,
            error: None,
        }));
        let out = finalize_run(&ok_result(), &ctx);
        assert_eq!(out.status, RunStatus::Done);
    }

    #[test]
    fn incomplete_commit_downgrades() {
        let d = dirty();
        let mut ctx = base_ctx();
        ctx.head_before = Some("aaa".into());
        ctx.git_delta = Some(Box::new(move |_, _| Some(d.clone())));
        let out = finalize_run(&ok_result(), &ctx);
        assert_eq!(out.status, RunStatus::DoneWithConcerns);
        assert_eq!(out.concerns.as_ref().map(|c| c.len()), Some(1));
    }

    #[test]
    fn gate_failure_on_error_stays_error() {
        let mut ctx = base_ctx();
        ctx.gate = "make test".into();
        ctx.run_gate = Some(Box::new(|_, _, _| GateResult {
            command: "make test".into(),
            exit_code: 1,
            passed: false,
            output_tail: "FAIL".into(),
            output_path: None,
            error: None,
        }));
        let res = BackendResult {
            clean_exit: false,
            stderr: "boom".into(),
            ..Default::default()
        };
        let out = finalize_run(&res, &ctx);
        assert_eq!(out.status, RunStatus::Error);
    }

    #[test]
    fn gate_failure_leaves_needs_context() {
        let mut ctx = base_ctx();
        ctx.gate = "make test".into();
        ctx.run_gate = Some(Box::new(|_, _, _| GateResult {
            command: "make test".into(),
            exit_code: 1,
            passed: false,
            output_tail: "FAIL".into(),
            output_path: None,
            error: None,
        }));
        let res = BackendResult {
            text: "q?\nSTATUS: NEEDS_CONTEXT".into(),
            is_error: Some(false),
            clean_exit: true,
            stderr: String::new(),
            ..Default::default()
        };
        let out = finalize_run(&res, &ctx);
        assert_eq!(out.status, RunStatus::NeedsContext);
    }

    #[test]
    fn clean_tree_no_concern() {
        let mut clean = dirty();
        clean.uncommitted_files.clear();
        clean.dirty_after = false;
        let mut ctx = base_ctx();
        ctx.head_before = Some("aaa".into());
        ctx.git_delta = Some(Box::new(move |_, _| Some(clean.clone())));
        let out = finalize_run(&ok_result(), &ctx);
        assert_eq!(out.status, RunStatus::Done);
        assert!(out.concerns.is_none());
    }

    #[test]
    fn job_id_propagates() {
        let mut ctx = base_ctx();
        ctx.job_id = Some("job-1".into());
        let out = finalize_run(&ok_result(), &ctx);
        assert_eq!(out.job_id.as_deref(), Some("job-1"));
    }

    fn stalled() -> BackendResult {
        BackendResult {
            clean_exit: false,
            stderr: String::new(),
            ..Default::default()
        }
    }

    #[test]
    fn reported_cost_is_not_estimated() {
        let mut res = ok_result();
        res.cost_usd = Some(1.25);
        res.usage = Some(Usage {
            input_tokens: 1_000_000.0,
            ..Default::default()
        });
        let mut ctx = base_ctx();
        ctx.price_map.insert(
            "composer-2.5".into(),
            Price {
                input: 0.5,
                output: 2.5,
                cache_read: 0.2,
                cache_write: 0.0,
            },
        );
        let out = finalize_run(&res, &ctx);
        assert_eq!(out.cost_usd, Some(1.25));
        assert!(!out.cost_estimated);
    }

    #[test]
    fn stall_computes_changeset() {
        let d = dirty();
        let mut ctx = base_ctx();
        ctx.head_before = Some("aaa".into());
        ctx.git_delta = Some(Box::new(move |_, _| Some(d.clone())));
        let out = finalize_stall(&stalled(), &ctx);
        assert_eq!(out.change_set.as_ref().unwrap().new_commits, ["bbb"]);
    }

    #[test]
    fn stall_never_runs_gate() {
        let ran = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let ran2 = std::sync::Arc::clone(&ran);
        let mut ctx = base_ctx();
        ctx.gate = "make test".into();
        ctx.run_gate = Some(Box::new(move |_, _, _| {
            ran2.store(true, std::sync::atomic::Ordering::SeqCst);
            GateResult {
                command: "make test".into(),
                exit_code: 0,
                passed: true,
                output_tail: String::new(),
                output_path: None,
                error: None,
            }
        }));
        let out = finalize_stall(&stalled(), &ctx);
        assert!(!ran.load(std::sync::atomic::Ordering::SeqCst));
        assert!(out.gate_result.is_none());
    }

    #[test]
    fn stall_no_incomplete_commit() {
        let d = dirty();
        let mut ctx = base_ctx();
        ctx.head_before = Some("aaa".into());
        ctx.git_delta = Some(Box::new(move |_, _| Some(d.clone())));
        let out = finalize_stall(&stalled(), &ctx);
        assert!(out.concerns.is_none());
    }

    #[test]
    fn stall_stderr() {
        let mut res = stalled();
        res.stderr = "boom".into();
        let out = finalize_stall(&res, &base_ctx());
        assert_eq!(out.stderr_tail.as_deref(), Some("boom"));
    }

    #[test]
    fn stall_job_id_propagates() {
        let mut ctx = base_ctx();
        ctx.job_id = Some("job-9".into());
        let out = finalize_stall(&stalled(), &ctx);
        assert_eq!(out.job_id.as_deref(), Some("job-9"));
    }

    #[test]
    fn clean_denial_downgrades_done() {
        let mut res = ok_result();
        res.permission_denials = vec![serde_json::json!({
            "tool_name": "shell",
            "action_id": "a_denied",
            "decided_by": "reviewer",
            "reason": "fetches a remote host",
            "command": "curl https://example.com",
        })];
        let out = finalize_run(&res, &base_ctx());
        assert_eq!(out.status, RunStatus::DoneWithConcerns);
        let concerns = out.concerns.expect("concerns");
        assert!(
            concerns
                .iter()
                .any(|c| c.contains("permission denied: shell")),
            "{concerns:?}"
        );
    }

    #[test]
    fn denial_on_error_stays_error() {
        let res = BackendResult {
            clean_exit: false,
            stderr: "boom".into(),
            permission_denials: vec![serde_json::json!({"tool_name": "shell"})],
            ..Default::default()
        };
        let out = finalize_run(&res, &base_ctx());
        assert_eq!(out.status, RunStatus::Error);
    }

    #[test]
    fn empty_final_message_is_a_concern_not_done() {
        // #318: an empty final message is DONE_WITH_CONCERNS, not DONE.
        let res = BackendResult {
            text: String::new(),
            is_error: Some(false),
            clean_exit: true,
            ..Default::default()
        };
        let out = finalize_run(&res, &base_ctx());
        assert_eq!(out.status, RunStatus::DoneWithConcerns);
        let concerns = out.concerns.expect("concerns");
        assert!(
            concerns.iter().any(|c| c.contains("empty final message")),
            "{concerns:?}"
        );
    }
}
