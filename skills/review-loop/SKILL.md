---
name: review-loop
description: "Review, repair and verify a PR until it can merge: two reviews from a different model family, fix rounds with scoped verifies, and a two-round stop. Use when a PR needs review before merge, whether it came from implement, the flywheel's PR-stack mode, or triage."
---

The loop for one PR. Reviews run on models from a different family than the PR's implementer, at the same rung or higher; pick them per the `delegate` skill.

**Identity.** A verdict covers the `git patch-id --stable` of the PR's diff: a rebase that keeps the patch keeps its verdict, and any other change needs a new one. CI covers the head SHA: a green run on an older SHA never satisfies merge.

**Counter.** Each PR has one counter. A fix round is one fix dispatch plus its scoped verify, and adds one.

### 1. Review

```
~/.agents/bin/review-pr run <pr> --repo <owner/name> --cwd <clone> --head <pushed sha> [--issue <n>]... [--spec <n>] --model <correctness> --overbuild-model <over-engineering> [--workflow-doc <path>]
```

`--head` is the full SHA of the PR head you expect reviewed, usually the commit you just pushed (`git rev-parse HEAD`): `review-pr` waits for GitHub to report it and reviews exactly that commit, so a push never gets reviewed at its old head. Pass `--issue` once per ticket the PR resolves. A PR with no ticket leaves out `--issue` and `--spec` and is reviewed against its own description. `run` launches the correctness review (`code-review`) and the over-engineering review (`overbuild-review`), waits for both, collects them, and exits with collect's code; if the wait fails it exits non-zero and prints the `collect:` line to resume with. The split form, `start` then `collect`, is for a caller that must do other work while the reviews run: `start` returns at once with one `<role> <job-id>` line per job, you wait with `delegate watch` on those ids, then run collect with the ids as printed.

```
~/.agents/bin/review-pr collect <job-id>...
```

Pass every job id that `start` printed, in one call: a full `collect` removes the run's worktrees, and a run you never collect in full leaks them into the clone. It posts both reviews on the PR with the patch-id, and prints only the verdicts, findings, CI state, and any job that didn't finish. An `UNFINISHED` line means that review didn't run: start again only after this full collect, and read nothing in its absence as approval. A `BAD-VERDICT` line names a reviewer line outside the shared vocabulary: treat it as no verdict and start again.

Done when both reviews have verdict lines for the current patch-id.

### 2. Route

Every verdict `APPROVE` and no open P1 or P2: the loop is done. Otherwise send every open finding in one fix round: fill `briefs/fix.md` with `~/.agents/bin/fill-brief --out <absolute path>` (`WORKFLOW_DOC` as the project's workflow doc path, findings as `FINDINGS=@<file>`; the file lists every finding since the reviewed head, earlier rounds' included, since the verify in step 3 reads it against that whole range; a CI-reported failure the round answers, such as a surviving mutant or a failing test, is a finding too, written with its CI evidence, or the verify flags its repair as out of scope) and dispatch it in the PR's worktree as a gated job, using the printed line verbatim as its prompt, never a hand-written path. When every open finding is trivial by `implement`'s fix-by-churn rule, fix them inline and run the gate yourself instead; the round still counts, and step 3 still verifies it.

Done when the fix round covers every open finding: dispatched as a gated job, or fixed inline with the gate's output stated.

### 3. Verify

Judge the repair by its diff (`git range-diff origin/main <reviewed head> <new head>`; after a rebase, a plain diff counts the base's own merges) and gate output, never the fix worker's report. A finding the worker refuted has no fix in the diff: copy its `refuted: <evidence>` line under that finding in the findings file, so the verify checks the evidence against the code. Then run the scoped verify, which starts it, waits and collects it, as in step 1:

```
~/.agents/bin/review-pr run <pr> --repo <owner/name> --cwd <clone> --head <pushed sha> --model <correctness> --verify <findings file> --since <reviewed head>
```

`FIX-OK`: the loop is done. `FIX-INCOMPLETE`: back to step 2 with the open findings, while the counter is below 2.

Done when the verify has printed `FIX-OK` or `FIX-INCOMPLETE` for the current patch-id.

### 4. Stop at two

After round 2, no round 3 runs.

- Only P3 findings open: answer each on the PR with evidence, or with a `debt:` comment naming its ceiling and upgrade trigger. The loop is done. A P3 that a marker could close only by weakening a rule a doc, spec or ticket states counts as an open P2.
- Any P1 or P2 open: the lane stops. Load `attack-the-premise`, post the assumption the fixes share, and rule one of:
  - **re-plan**: back to `implement` step 2, with the PR's branch as the base; the counter resets;
  - **take back**: implement it yourself; it gets a full review (step 1, a different family from you), and the counter resets;
  - **park**: when the premise touches the ticket's core outcome (see `implement`).

  A second round-2 stop on the same ticket parks it, whatever the earlier ruling.

When you answer findings yourself, follow "Answering the findings" in `code-review`. A commit `ci-triage` makes re-enters at step 3 on the same counter, with the CI failure it answers written into the findings file.
