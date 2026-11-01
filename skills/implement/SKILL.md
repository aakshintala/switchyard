---
name: implement
description: "Take one ticket from start to merge: preflight, plan, Verifier, lane, gate, review, CI, merge. Use when asked to implement, land or work a ticket end to end, in session or as a sub-orchestrator."
---

You are the orchestrator for one ticket. The **main orchestrator** is the session the owner started; a **sub-orchestrator** was started by another orchestrator's brief.

When you were started with a brief or notes file, that file is your contract for where you enter and what is already done. Where it speaks to a step below, it wins and the steps are only the default path. It never drops the gate, review or CI for commits you make. Where it conflicts with the Rules or the project's workflow doc, those win. Name in your report each step where you followed the file over the default.

## Rules

- **Never wait on a human.** A sub-orchestrator posts a decision it can't make to the tracker, with its options and a recommendation: a comment on the ticket it blocks, or a ticket with the `needs-info` role's label when it blocks none. It may also open follow-up tickets. It searches the tracker for an existing issue before opening one, reports each decision to its parent (the link, what it blocks, what it keeps building), lists every issue it opened or commented on in its report, and keeps building what the decision doesn't block. It never writes a handoff. The main orchestrator keeps the conversation with the owner (what to ask, when, and in what order). It asks the owner once, at the start, whether they'll be around for rulings, and switches on "going away" or "back": when they're present, ask in chat; when they're away, comment on the ticket the decision blocks (or open a new ticket when it blocks none) and keep building the rest.
- **Park** a ticket when an open decision touches its core outcome: post the question on the ticket, apply the label `docs/agents/triage-labels.md` maps to the `needs-info` role, and stop work on it. Under an orchestrator parent, post the question and report it to the parent instead: the parent routes it and sets any label, and only the main orchestrator applies the `needs-info` label itself. When a parked ticket resumes, post a comment with its state, the governing ruling's link and the next action: the resume brief points at that comment as the single source. When the decision touches only part of the ticket, ship each part that meets its own criteria as `Part of #<n>` and park only what depends on the answer.
- **Hold** the merge, and only the merge, on an open decision that doesn't touch the core outcome (a name, a registry row, a message's wording): build and review everything with the recommended default in place, and merge once it's ruled.
- **Judge by evidence.** Read the diff and the gate output, never a worker's report. Report success only with fresh output of the gate in the same message. The local gate is the fast loop, never the PR's CI state: a claim about CI (ready, green, or red only on a named flake) cites the GitHub run on the exact pushed head by its run id, with every non-success job and, quoted, its failing test, else its failing step or runner error (a cancelled job: what cancelled it). It names each required check with its conclusion, a skipped one as skipped. A repo may run some required jobs only on a ready PR, and `gh-ci wait` on a draft judges only the checks that ran: a draft pass is provisional, never the PR green, so mark the PR ready before claiming green. A CI claim without a run id is incomplete; check it against `gh-ci failures --pr <pr> --repo <owner/name>` before acting on it.
- **The gate** is the lane's gate command plus three pre-push checks: the worktree's HEAD descends from the remote branch's tip, every changed file is in the plan's Files or only gains lines (`tkt-gate` checks this), and `git log origin/main..<branch> --stat` shows only this ticket's commits.
- **Fix by churn.** Make a trivial change (a one-line deletion, a rename, a PR-body or label fix) inline, then run the gate yourself and state its output. Send a change that may start a run-and-fix loop (new behaviour, a fix whose cause isn't confirmed (see Confirmed bug), an edit across several files) to a gated job.
- **The category follows the cause.** A project may gate `bug` fixes on a test that goes red first. When the confirmed cause turns out to be in test code, or the ticket adds behaviour no doc promised and fixes no hang, crash or lost data, relabel it (`test-only` or `enhancement`, per `docs/agents/triage-labels.md`) with a comment giving the cause, before the PR opens. When CI already ran on the old label, rerun the whole run after relabelling (`gh run rerun <run id>`, never `--failed`: it reuses the cached label read), or push.
- **A flake with an open cause is diagnostic-first.** The lane's done criterion is a recorded cause, or the rerun count the ticket sets with none found; a fix follows as a second ticket. `ci-triage`'s Flake rule owns the filing.
- **One worktree per job**, named for its branch, deleted on merge.

## Commands

When the brief names a state file, run each phase through its `tkt-*` command: steps 1–2 `tkt-start`, step 3 `tkt-plan`, steps 4–6 `tkt-build`, each fix round `tkt-fix`, steps 7–8 `tkt-ship`. When the ticket's spec is another issue, pass its number with `tkt-start --spec-issue <N>`. `tkt-build` passes that number to `review-pr`. Run each call alone as `cmd > out 2>&1`, with nothing after it in that Bash call, then read `out` separately. Decide from the verdict word on the first `TKT tkt-<tool> <WORD>` line, not the harness exit code. Go on only for the words below; a lane `CONCERNS` continues per step 4, and so does a fix round's `CONCERNS` (`tkt-fix` sends the concerns file to the verify as `--context`); every other word is a stop.

| Tool | Go on | Other verdicts that stop |
| --- | --- | --- |
| `tkt-start` | `CURRENT`; `PREFLIGHT` only with `core=0` | `STALE`, `MERGED-STOP`, `BUSY`, `PRECONDITION`, `DRIFT`, `STEP-FAIL` |
| `tkt-state` | exit 0 | exit 2 |
| `tkt-plan` | `PLAN-OK`, `POSTED`, `SET`, `REPLAN` | `LINES`, `ROUND-LIMIT`, `PLAN-CHECK`, `STALE`, `POST-FAIL`, `ASK`, `BLOCKED`, `WALL-CAP`, `JOB-ERROR`, `GATE-FAIL`, `NO-COMMITS`, `UNKNOWN` |
| `tkt-job` | `DONE`, `CONCERNS` | `ASK`, `BLOCKED`, `WALL-CAP`, `JOB-ERROR`, `GATE-FAIL`, `NO-COMMITS`, `UNKNOWN` |
| `tkt-build` | `APPROVE` | `CHANGES`, `STALE`, `DRIFT`, `PRECONDITION`, `ROUND-LIMIT`, `REVIEW-INCOMPLETE`, `VERDICT-REFUSED`, `<step>-ERROR` |
| `tkt-gate` | `PASS` | `TIP`, `FENCE`, `FAIL` |
| `tkt-fix` | `FIX-OK`; `PUSHED` then `tkt-ship --unverified-fixes` | `FIX-INCOMPLETE`, `VERIFY-FAIL`, `PUSH-FAIL`, `CI-WAIT`, `RECOVER`, `DRIFT`, `ROUND-LIMIT`, `UNKNOWN`, gate stops |
| `tkt-ship` | `MERGED` | `PENDING`, `CONFLICT`, `PATCH-CHANGED`, `BODY`, `GATE-FAIL`, `MERGE-FAIL`, `CI-FAIL`, `PRECONDITION`, `BUSY`, `DRIFT`, `UNKNOWN` |

Read a stop once, then route it by the step that owns it. State and the journal are the ticket's record: read them on resume. A repo without state runs the steps below by hand.

## Fast paths

Planning is spent where the ticket leaves something to decide. Two kinds of ticket skip the plan; every other ticket takes the full path. Both skip the plan's Files sweep too, so before the first gate grep tests, benches and snapshots for each assertion on a value the change alters, and update the hits.

### Confirmed bug

Take it when the root cause is **confirmed**: a red test, a `diagnosing-bugs` result, or the ticket or a posted plan names the faulty code, giving both the failing assertion or symptom and the code path that produces it, with `file:line`. The fix stays in the faulty module, the call sites a signature change forces, and its test. A cause that is still a hypothesis or an open diagnosis, however small the diff, takes the full path. The cause decides, not the size. A move, a rename or a mechanical removal is no bug fix: it takes the Determined path.

Run step 1, skip steps 2–3, then build in a worktree cut from `origin/main`. Record the plan with `tkt-plan <state> set <plan> --no-verifier`. The fence is that module, those call sites and the test, and it stands in for the plan's Files in the gate. Use an existing confirming test, or add one that goes red before the fix. When the workflow doc gates `bug` fixes on a commit that fails first, that test is the branch's first commit, alone, and the fix follows in its own commit. Make the fix inline when **Fix by churn** allows, otherwise as a gated job: write the plan file as the Determined path does, with the cause and the failing assertion under Tasks and the fence under Files, and fill `../planning/briefs/lane.md` from it; the lane pushes, opens the draft PR with the ticket's `Resolves` line and reports its URL and head SHA. Inline, do those three yourself. Then run steps 5–9 as written. Leave the fast path for step 2 when the fix spreads past the fence or the test won't go red.

### Determined ticket

Take it when the ticket is **determined**: it adds no new type, event, config key or doc decision, and its files are named in the ticket or found by one grep. A move, a rename or a mechanical removal is determined; a refactor that chooses new boundaries is not.

Run steps 1–2. When the preflight finds no `core` item, or step 2 skipped it as current, skip step 3: write a plan file of five parts: Rung per `planning`'s rule (`standard` by default; `strong` or `frontier` where `planning` says so); Files (the preflight's file list, or the ticket's when step 2 skipped it); Tasks (the ticket's acceptance criteria, each with the test or command that shows it met, then each `non-blocking` drift item the preflight reported as a ruling line); Red commit, as `planning`'s template defines it; and `## Gate`, the workflow doc's gate as one command line, which `plan-gate` reads for the job-end gate. Fill `../planning/briefs/lane.md` yourself, with the keys `planning` step 5 lists: `PLAN` is that file's absolute path, and `GATE` is the same gate. Before step 4, reread each ruling posted on the ticket against the plan file: a ruling that changed the repro target, a file or a task changes the plan first. Then run steps 4–9 as written. When a build fails twice on the same finding, write the plan (step 3) and continue from there.

When the fast path skips the plan's Verifier, run `tkt-plan <state> set <plan> --no-verifier`; it records the verdict as skipped, which `tkt-plan post` and `tkt-build` accept. `tkt-plan <state> post --no-verifier` and `tkt-build <state> --no-verifier` record the same skip when no verdict is stored, and never overwrite a stored one.

### 1. Check setup

Read `docs/agents/` and the workflow doc it names; the workflow doc wins where it speaks. With no `docs/agents/`, stop and report "repo not set up".

A main orchestrator outside a flywheel then confirms with the owner the model pool for each rung (per the `delegate` skill) and a review pool: a correctness and an over-engineering reviewer, each from a family other than the implementers', at the same rung or higher. A sub-orchestrator takes these from its brief.

A task with no ticket gets one opened first, so every brief has an issue number.

Done when you know the tracker, labels, workflow doc and models, and the task has a ticket.

### 2. Preflight

Skip the preflight when a new ticket is **current**: the preflight exists to catch a stale ticket, and a current one cannot be stale. A ticket is current when all three hold, checked from an up-to-date clone:

- It names every file it touches and leaves no decision or diagnosis open.
- Every named file exists at `origin/main` (`git cat-file -e origin/main:<file>`).
- The ticket body names its filing commit, and `git log <filing commit>..origin/main -- <named files> <docs it cites>` prints nothing (two dots: what landed after the filing commit, never the commit itself). When the body was edited after that commit's date (`git show -s --format=%cI <commit>` against `gh api graphql -f query='{repository(owner:"<o>",name:"<r>"){issue(number:<n>){lastEditedAt}}}'`; null means never edited), add `--since=<lastEditedAt>`.

A ticket whose files all sit under a prototype path the workflow doc names checks its named files alone, not the docs it cites. Any miss runs the full preflight below. After a skip, whoever writes the plan gets the ticket in place of the preflight's report.

Prepare the base first. A new ticket's base is `origin/main`. A re-plan's base is the PR's branch, brought up to date: merge `origin/main` into it in the PR's worktree and push, so the preflight and the Verifier never read a stale branch. Reset the lane counter with `tkt-plan <state> replan` before the re-plan lane. Run the preflight and the Verifier in a checkout of the base: an up-to-date clone on `origin/main`, or the PR's worktree.

Fill `../planning/briefs/preflight.md` (keys `ISSUE`, `SPEC` (the issue number of the design doc or ruled text the preflight checks the ticket against), `REPO`, `BASE`, `WORKFLOW_DOC` and `PACK`, as `planning`'s Pack says) with `~/.agents/bin/fill-brief --out <absolute path>` (e.g. `~/.cache/agents/<repo>-<issue>-preflight.md`) and run it as its own job, on a `strong` model from a different family than yours, before any plan exists, using the printed line verbatim as the prompt, never a hand-written path. You save the preflight's reply (its brief tells it to write no file) beside its brief as `<repo>-<issue>-preflight-out.md` and hand that path, never the brief's, to whoever writes the plan. A `core` item parks the ticket. `non-blocking` items and the file list go to the plan.

Done when the preflight has returned and no `core` item is open, or the ticket is current.

### 3. Plan

Follow `planning` steps 1–5. When a worker writes the plan, fill `../planning/briefs/planner.md` for it, with the keys `ISSUE`, `REPO`, `BASE`, `WORKFLOW_DOC`, `PREFLIGHT`, `PACK`, `PLAN` (the plan file's absolute path) and `EXTRA` (empty by default). It covers `planning` steps 1–2 and ends with the plan file; you run steps 3–5 yourself, since a worker's brief forbids delegating and the Verifier is a job of its own. The brief's `Blocked` rule tells the worker where to stop. You post a `Blocked` section as the question and park as Rules says: the whole ticket when the item touches its core outcome, otherwise only what depends on the answer.

Done when the lane brief is filled.

### 4. Lane

**Stale-plan check.** A plan goes stale when `origin/main` changes a file it names. Before each Verifier round and before dispatching a lane, run `git diff --stat <the plan's Base line>...origin/main -- <every path under Files>` (three dots: only what `main` changed since the base, never a re-plan's own commits). Empty output means the plan is current, even when the SHAs differ: go on. Otherwise revise the tasks that touch the changed files against the current base, update the Base line, and send the plan through `planning` step 3; dispatch once the Verifier passes. A plan with no Base line takes its newest plan comment's `updatedAt`: `git log --oneline origin/main --since=<updatedAt> -- <every path under Files>`. After a stale-base revision with the Verifier budget spent, save the revised plan to a new path and run `tkt-plan <state> set` on it, which resets the Verifier counters (`planning` step 3); a ruling-only revision takes no new round.

Before the first dispatch, `tkt-start` searches the merged PRs for one that already closes the ticket (`gh pr list --repo <owner/name> --state merged --search "\"#<n> in:body\""`; a `Resolves` hit stops the run unless the issue is open and has a comment newer than the newest `Resolves` merge, which prints `NOTE recurred after merged PR #<m>` and continues; a `Part of` hit prints a `NOTE merged Part-of PR #<m>` line with the PR's files and continues); a stop means the ticket is done, so stop and report it. On a recurrence NOTE, read the newer comment before planning: it says what the merged PR missed. For a new ticket, cut a worktree from `origin/main`; a re-plan's lane works in the PR's worktree. Dispatch the lane brief on a model at the plan's Rung (per the `delegate` skill). The lane brief was filled with `~/.agents/bin/fill-brief --out <absolute path>`; use the printed line verbatim as the lane's prompt, never a hand-written path. Take the job-end gate from the plan: `tkt-job --gate-from-plan` writes and runs the script. Without state, take it from `~/.agents/bin/plan-gate <plan file>`, which strips the plan's backticks and fence (a gate copied by hand keeps them, and bash runs backticks as command substitution), and write the script as `write_gate_script` in `~/.agents/bin/lib/gate-script.sh` does: the gate's steps chained with `&&` inside one block that redirects to its own per-run log, then `tail`, one `GATE PASS` or `GATE FAIL rc=<n>` line and `exit <n>`. Delegate reads the script's exit code, never the log line.

To watch a running lane, run `~/.agents/bin/lanestat <run-dir>`: a row reads `IN-TOOL <tool>` while a tool call runs, `SETTLED` when the run ended, and `STALL` after 5 minutes idle with no tool running; `~/.agents/bin/lanewatch <run-dir> [ssh-target]` prints one line per lane the first time it settles or stalls, for Monitor.

A plan split into parts runs each part through steps 4–8 in order. For part `n` (2 or more), run `tkt-start ... --part <n>` once the previous part's PR has merged. It archives the previous state as `<state>.part<n-1>`, starts fresh state and refuses while that PR is open. A `DRIFT` that names a merged `pr` is the signal to add `--part`. Pass `--body-ends`, `--model` and `--spec-issue` again after `--part`, since only `issue`, `repo`, `run`, `worktree` and `model.*` lines carry. Cut the next lane once the previous part has merged.

A lane `CONCERNS` verdict is exit 1 from `tkt-job`, but `tkt-build` consumes it, runs the gate and review itself, and passes the file in state key `concerns.lane` to every review start as `--context`. The orchestrator reads the concerns file before accepting the review verdict. A concern that questions a posted ruling, the fence or ticket scope routes as `ASK`.

Done when the lane reports a PR URL and head SHA, or a failure triage.

### 5. Gate

Confirm the remote tip equals the lane's reported SHA (`git log origin/<branch> -1`), read the diff, and run the gate yourself. A file outside the fence with a deleted line, a new file outside it, or a failing check goes back to the lane, or you take the work back.

When CI runs mutation testing on the diff, take its mutant list from the first draft run, by the workflow doc's commands, as soon as the job that lists the mutants finishes (minutes in; the mutant jobs run much longer), and map each mutant to a catching test or a function-level exemption with its reason before the first fix round; `tkt-build` runs the map beside the first review and merges its needs-test and removed lines into the findings file. Record an unviable mutant (one that doesn't compile) as `unviable`: it needs neither. A viable mutant with neither gets a test before the next push: push it while the first run continues, since the newer push cancels that run and leaves its verdicts unread. Repeat after each code push. Once the run finishes, take each mutant's verdict from `~/.agents/bin/mutant-verdicts <run> --repo <owner/name>`: one line per mutant holding the mutant, a tab, and one of `caught`, `missed`, `timeout`, `unviable`; the `missed` and `timeout` lines are the surviving mutants. `tkt-build` waits up to 2400 s for the head's shards once the review pair starts and adds every head survivor (missed/timeout inside the diff) from the shards to the round-1 findings; a shard still running at the bound is reported as `P3 mutant shards unread`, and review proceeds without it.

Done when the gate passes on the remote tip.

### 6. Review

Run `review-loop` on the PR. A bare `review-pr run`/`start` on a PR that already has a review comment for an earlier head at a different patch-id refuses (exit 2) with the scoped verify command; `--full-rereview <reason>` overrides it for a re-plan or take-back. `tkt-build` passes `--full-rereview "tkt-build round-0 full review"` on its review pair itself.

Done when `review-loop` is done.

### 7. CI

`ship-pr` (step 8) waits on CI; come here when it reports failing checks. Run `ci-triage` until the required checks are green on the current head SHA. Wait on the PR with `gh-ci wait <pr> --repo <owner/name>`, in the wait mode `ci-triage` gives; it follows a new head pushed mid-wait. Green comes from a fix, never a rerun, except `ci-triage`'s one job rerun for an infrastructure failure and `ship-pr`'s one rerun of a failure outside the diff: a flake gets `ci-triage`'s one fresh build and a `test-only` issue, and `gh-ci resample` only measures how often a failure happens.

Done when CI is green on the head a verdict covers.

### 8. Merge

Before either path runs, the PR body names `Implemented by: <model ids>` (the ids the jobs ran on, as `delegate` records them, never display names), and, where CI runs mutation testing only on a ready PR, every viable mutant in the draft run's list has a catching test or exemption on the pushed head (step 5): the ready mark starts the shards. After a failed merge or MERGED wait, check `gh pr view <pr> --json state` before rerunning: if it reads `MERGED`, finish the by-hand cleanup below instead.

With a state file, `tkt-ship <state>` runs `ship-pr` from the state keys (`reviewed`, `unverified`, `body_has`, `body_ends`, `merge_gate`, `head`), reruns it while CI is pending and digests a red CI run. Keep `head` and `reviewed` current with `tkt-state set` after every push. Pass the session's attribution line to `tkt-start` as `--body-ends` (Claude Code: `Co-authored with Claude Code.`), or set it late with `tkt-state <state> set body_ends TEXT` once the ticket has already started; a session whose instructions require no attribution line passes no `--body-ends`. Route its verdict:

- `MERGED`: done. `FLAKE-NOTE` on it means file the flake as `ci-triage`'s flake rule says.
- `PENDING`: CI is still running; rerun.
- `CI-FAIL`: step 7 with the digest. `GATE-FAIL`: back to the lane. `MERGE-FAIL`: check the PR state as above, then rerun.
- `CONFLICT`: `git rebase origin/main` in the worktree, resolve with `resolving-merge-conflicts`, push with `--force-with-lease`, set `head`, rerun.
- `PATCH-CHANGED`: push the head with `--force-with-lease` and set `head`. A fix round with no real bug takes no verify: set `unverified` to the findings file and rerun. Otherwise run `review-loop`'s scoped verify, set `reviewed` to the verify's head on `FIX-OK`, and rerun.
- `BODY`: add each printed `missing body line:` to the PR body and rerun.
- `DRIFT`: state, worktree and PR heads differ; reconcile them and rerun. `PRECONDITION`: stderr names the missing key or tool. `BUSY`: another `tkt-ship` holds the lock. `UNKNOWN`: read the log.

Without state, run `ship-pr` by hand. When the workflow doc's merge rule allows a squash merge and the merge terms cover this PR, run `~/.agents/bin/ship-pr <pr> --repo <owner/name> --reviewed <head the last verdict covers: the FIX-OK verify's head after a fix round, else the reviewed head; never a rebase of it> [--unverified-fixes <findings file>, when `review-loop` step 2 skipped the verify] --worktree <worktree> --gate '<gate command>'` (keep its default CI `--timeout`), in the wait mode `ci-triage` gives. Drop `--gate` when the workflow doc names CI on the exact head as the merge gate. It gates the head first (with `--gate`), then rebases (when `main`'s required checks are strict: if `origin/main` moved; otherwise only on a reported conflict; a rebase does not rerun the gate), marks a draft PR ready, waits on CI (required checks green on the exact head count, whenever they ran), runs `pr-closes`, squash-merges and cleans up, and prints `merged <sha>`. It removes the worktree it is given, unless the shell that ran it started inside that worktree: then it keeps the worktree and local branch and prints the command that removes them. Run it from outside the worktree to have it removed; `merged <sha>` confirms the merge. Add `--body-has '<prefix>'` once for each line the workflow doc requires in a PR body, once for the lane brief's `CLOSING` line (`Resolves #<n>` or `Part of #<n>`), and once for the attribution line your session's instructions require there (Claude Code: `Co-authored with Claude Code.`); `ship-pr` checks them first. Run it with every flag that applies, alone in its tool call with nothing around it (no pipe, redirect, `cd` or `&&`): allow rules match only that form. `ship-pr` keeps the branch current, so rebase by hand only on its exit 3, a failure from `main`'s side, or code the PR needs from a newer `main`. Route any other exit, then rerun it:

- 124: CI is still pending. Rerun as is.
- 1: read stderr. Failing checks go to step 7 (`ship-pr` already spent its one rerun when the failure was outside the diff), a failed gate goes back to the lane, and `origin/main moved during CI` means ship-pr already retried 3 times itself, so rerun it.
- 3: `ship-pr` aborted the rebase, or found the PR conflicting with `origin/main` after its push. Run `git rebase origin/main` again, resolve with `resolving-merge-conflicts`, push with `--force-with-lease`, then rerun it with the same `--reviewed`. Take the new head through `review-loop`'s verify only when it then exits 4.
- 4: the patch changed (a rebase changed the diff, or a commit was added after review), and the new head may be local only. Push it with `--force-with-lease` first. A fix round with no real bug (`review-loop` step 2) takes no verify: rerun with `--unverified-fixes <findings file>` and the same `--reviewed`, and stop here. Otherwise run `review-loop`'s scoped verify, never a full re-review: `~/.agents/bin/review-pr start <pr> --repo <owner/name> --cwd <clone> --head <new full sha> --model <correctness> --verify <findings file> --since <reviewed head>`, then collect it. With no open findings, the file says `no open findings`: `review-pr` refuses an empty one. Rerun with the new head as `--reviewed` once the verify prints `FIX-OK`.
- 0 with `file the flake` on stderr: file the rerun failure as `ci-triage`'s flake rule says.
- 5: handle the printed matches as the next paragraph says; when only commit-message matches remain, rerun with `--allow-commit-closes`. For printed `missing body line:` lines, add each to the PR body.
- 2: a precondition failed; stderr names it.

The rest of this step is the by-hand merge, for the cases `ship-pr` doesn't cover.

Run `~/.agents/bin/pr-closes <pr> --repo <owner/name>` first. Exit 1 lists each issue a closing keyword would close outside the PR's `Resolves` lines. Reword a title or body match and rerun. When only commit-message matches remain, merge with `gh pr merge --subject <title> --body <body>` so the squash commit carries the PR text alone.

Promote the draft PR to ready, then merge by the workflow doc's rule, plus any session terms the flywheel confirmed. Close the issues in the PR's `Resolves` lines, and no others: a `Part of` ticket stays open until its last part merges. Once `gh pr view <pr> --json state` reads `MERGED`, clean up by hand, since `gh pr merge --delete-branch` fails on a branch checked out in a worktree: delete the worktree, then the local branch (`git branch -D <branch>`), then the remote branch (`git push origin --delete <branch>`); a `remote ref does not exist` error means the repo already deleted it on merge, which counts as done.

Done when the PR is merged with `pr-closes` clean (OK, or only commit-message matches kept out of the squash), or escalated as the rules above say.

### 9. Report

The merge SHA, or the PR URL with its failure triage and the action someone must take (a triage on CI grounds names the run id on the PR's head, as **Judge by evidence** says); then **Friction**: up to 3 bullets. The main orchestrator then names the next phase: the next ticket on the frontier, or `retro` when the round is done.
