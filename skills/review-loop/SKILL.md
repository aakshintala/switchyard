---
name: review-loop
description: "Review, repair and verify a PR until it can merge: reviews from a different model family, fix rounds with scoped verifies, and a two-round stop. Use when a PR needs review before merge, whether it came from implement, the flywheel's PR-stack mode, or triage."
---

The loop for one PR. Reviews run on models from a different family than the one that wrote most of the PR, at the same rung or higher; pick them per the `delegate` skill. When a pick lands on that family, swap it and say so on the PR.

**Identity.** A verdict covers the `git patch-id --stable` of the PR's diff: a rebase that keeps the patch keeps its verdict, and any other change needs a new one. CI covers the head SHA: a green run on an older SHA never satisfies merge.

**Counter.** Each PR has one counter. A fix round is one fix dispatch plus its scoped verify, and adds one. With a state file it is the key `round`, which `tkt-fix` keeps.

### 1. Review

```
~/.agents/bin/review-pr run <pr> --repo <owner/name> --cwd <clone> --head <pushed sha> [--issue <n>]... [--spec <n>] --model <correctness> [--overbuild-model <over-engineering>] [--axes <list>] [--workflow-doc <path>]
```

`--head` is the full SHA of the PR head you expect reviewed, usually the commit you just pushed (`git rev-parse HEAD`): `review-pr` waits for GitHub to report it and reviews exactly that commit, so a push never gets reviewed at its old head. Pass `--issue` once per ticket the PR resolves, and once per issue holding a ruling that changes the PR's scope; link that ruling in the PR body too. A PR with no ticket leaves out `--issue` and `--spec` and is reviewed against its own description. `run` launches one job per axis: Standards and Spec (`code-review`, one axis each) and Overbuild (`overbuild-review`), waits for all, collects them, and exits with collect's code; `--axes standards[,spec][,overbuild]` runs a subset (default all three; `--overbuild-model` is needed only with `overbuild`), and the project's workflow doc says when a smaller set is enough; if the wait fails it exits non-zero and prints the `collect:` line to resume with. The split form, `start` then `collect`, is for a caller that must do other work while the reviews run: `start` returns at once with one `<role> <job-id>` line per job, you wait with `delegate watch` on those ids, then run collect with the ids as printed.

A bare `review-pr run`/`start` on a PR that already carries a `review-pr` comment for an earlier head at a different patch-id exits 2 before starting any job and prints the scoped verify command with `--since` set to the last reviewed head. A rerun with the same patch-id is not refused, nor is a retry of the same head. When the comment fetch fails, the start exits 1 with `could not read PR comments`; rerun once the API is reachable. `--full-rereview <reason>` (a single line, never with `--verify`) overrides the refusal for the full pair step 3 allows after round 1; the reason is printed and stored in the posted comment header.

```
~/.agents/bin/review-pr collect <job-id>...
```

Pass every job id that `start` printed, in one call: a full `collect` removes the run's worktrees, and a run you never collect in full leaks them into the clone. It posts the reviews on the PR with the patch-id, and prints only the verdicts (one `VERDICT <axis>` line per axis that ran), findings, CI state, and any job that didn't finish. An `UNFINISHED` line means that review didn't run: start it again only after this full collect, once on the same model; a second `UNFINISHED` falls back to a model from a family other than the author's, at medium effort whatever the rung above (pick per `delegate`). No axis is skipped, and a missing verdict is never approval. A `BAD-VERDICT` line names a reviewer line outside the shared vocabulary: treat it as no verdict and start again.

Done when every axis that ran has a verdict line for the current patch-id.

### 2. Route

Every verdict `APPROVE` and no open P1 or P2: the loop is done. Otherwise send every open finding in one fix round. With a state file, run `tkt-fix <state> --verify` when the round answers a real bug (below) and `tkt-fix <state> --no-verify` otherwise: it fills the brief, runs the gated fix job, waits for CI, pushes, adds one to `round`, and with `--verify` runs step 3. `--findings <file>` names the findings; without it the command reads the state's `findings`. The real-bug rule below stays your judgment: it picks the flag. Without state, fill `briefs/fix.md` with `~/.agents/bin/fill-brief --out <absolute path>` (`WORKFLOW_DOC` as the project's workflow doc path, findings as `FINDINGS=@<file>`, `EXTRA` as in `planning`'s lane brief; the file lists every finding since the reviewed head, earlier rounds' included, since the verify in step 3 reads it against that whole range; a CI-reported failure the round answers, such as a surviving mutant or a failing test, is a finding too, written with its CI evidence, or the verify flags its repair as out of scope) and dispatch it in the PR's worktree as a gated job, using the printed line verbatim as its prompt, never a hand-written path. A fix report of `ready, not pushed` leaves the push to you: run the brief's `gh-ci wait` without `--timeout`, push when it exits 0 or 1, and carry any failed jobs it names into the next round. When every open finding is trivial by `implement`'s fix-by-churn rule, fix them inline and run the gate yourself instead; the round still counts, and step 3 still verifies it.

A **real bug** is a P1, or a behaviour defect a consumer of the change would see. When round one found no real bug, only missing tests, nits, style or docs, its fix round is the last. Step 3 is skipped. `ship-pr` takes the round-one head as `--reviewed`, with `--unverified-fixes <findings file>`, and CI, mutants included, still gates the new head.

A finding that waits on an owner ruling leaves the loop: post it as a decision per `implement`'s "Never wait on a human" rule, park the ticket when it touches the core outcome, and keep it out of the findings file and out of the round count. The other findings go on.

A **reversal** is a finding that asks to undo a change an earlier round made (a split merged back, a helper cut, a type swapped back) and names no behaviour defect. Answer it on the PR with the earlier round's reason, and keep it out of the findings file and out of the round count: fixing it only invites the reverse finding next round. A reversal that shows a real bug is an ordinary finding.

Done when the fix round covers every open finding: dispatched as a gated job, or fixed inline with the gate's output stated. A finding parked for a ruling is not open here.

### 3. Verify

Run this step when the fix round answers a real bug (step 2).

Judge the repair by its diff (`git range-diff origin/main <reviewed head> <new head>`; after a rebase, a plain diff counts the base's own merges) and the job's `gateResult`, never the fix worker's report: a report of a passing gate beside a red `gateResult` is red. A finding the worker refuted has no fix in the diff: copy its `refuted: <evidence>` line under that finding in the findings file, so the verify checks the evidence against the code. The scoped verify's rules are in code-review's Scoped verify; drop a finding it raises on code the repair did not touch, and file it as a follow-up if it is real. Then run the scoped verify; the command starts it, waits and collects it, as in step 1:

```
~/.agents/bin/review-pr run <pr> --repo <owner/name> --cwd <clone> --head <pushed sha> --model <correctness> --verify <findings file> --since <reviewed head>
```

`review-pr collect --findings-out <path>` produces the findings file; `briefs/findings.md` is the layout for one you write. Pass `--context <file>` for a plan, ruling or list the findings cite that lives outside the checkout.

`tkt-fix --verify` runs this step and prints its verdict:

- `FIX-OK reviewed=<sha>`: it set `reviewed`; the loop is done.
- `FIX-INCOMPLETE round=<n>`: the open findings are the next round's findings file (state `findings`); back to step 2. With `STOP-AT-TWO` on the line, go to step 4.
- `DRIFT`: state, PR and worktree heads differ; reconcile and rerun. `RECOVER job=<id>`: a fix job for this round already exists; rerun with `--resume <id> --prompt <file>`. `CI-WAIT`, `PUSH-FAIL`, `VERIFY-FAIL`: read the digest and the log it names.

The verify prints `review-pr: repair base <sha> (<since> replayed onto <base>)`: it replays the reviewed head onto the current base so the diff holds only the fix round, and needs no action. A line above it saying the head "does not replay cleanly" means the diff also holds the rebase's conflict resolution: judge that part as part of the repair.

`FIX-OK`: the loop is done. `FIX-INCOMPLETE`: back to step 2 with the open findings, while the counter is below 2.

A scoped verify stands for every axis: `FIX-OK` ends the loop and no full review pair follows, whichever axis raised the findings. A bare full pair on a PR that already has a review comment refuses (step 1). Run a full pair (step 1) only after a re-plan or take-back (step 4), or when the verify's new findings show the repair reached code outside the findings' bounds, passing `--full-rereview <reason>` for that full pair.

Done when the verify has printed `FIX-OK` or `FIX-INCOMPLETE` for the current patch-id.

### 4. Stop at two

After round 2, no round 3 runs.

- Only P3 findings open: answer each on the PR with evidence, or with a `debt:` comment naming its ceiling and upgrade trigger. The loop is done. A P3 that a marker could close only by weakening a rule a doc, spec or ticket states counts as an open P2.
- Any P1 or P2 open: the lane stops. Load `attack-the-premise`, post the assumption the fixes share, and rule one of:
  - **re-plan**: back to `implement` step 2, with the PR's branch as the base; reset the counter with `tkt-plan <state> replan`; its full review (step 1) passes `--full-rereview <reason>` since the PR already carries a review comment;
  - **take back**: implement it yourself; it gets a full review (step 1 with `--full-rereview <reason>`, a different family from you), and the counter resets;
  - **park**: when the premise touches the ticket's core outcome (see `implement`).

  A second round-2 stop on the same ticket parks it, whatever the earlier ruling.

When you answer findings yourself, follow "Answering the findings" in `code-review`. A commit `ci-triage` makes re-enters at step 3 on the same counter, with the CI failure it answers written into the findings file. A commit that only adds tests, such as one that kills a CI-reported mutant, skips step 3, and ships with `--unverified-fixes` and that failure in the findings file.
