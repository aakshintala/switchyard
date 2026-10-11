---
name: implement
description: "Take one ticket from start to merge: preflight, plan, Verifier, lane, gate, review, CI, merge. Use when asked to implement, land or work a ticket end to end, in session or as a sub-orchestrator."
---

You are the orchestrator for one ticket. The **main orchestrator** is the session the owner started; a **sub-orchestrator** was started by another orchestrator's brief.

## Rules

- **Never wait on a human.** A sub-orchestrator posts a decision it can't make to the tracker, with its options and a recommendation: a comment on the ticket it blocks, or a `needs-info` ticket when it blocks none. It may also open follow-up tickets. It searches the tracker for an existing issue before opening one, reports each decision to its parent (the link, what it blocks, what it keeps building), lists every issue it opened or commented on in its report, and keeps building what the decision doesn't block. It never writes a handoff. The main orchestrator keeps the conversation with the owner (what to ask, when, and in what order). It asks the owner once, at the start, whether they'll be around for rulings, and switches on "going away" or "back": when they're present, ask in chat; when they're away, comment on the ticket the decision blocks (or open a new ticket when it blocks none) and keep building the rest.
- **Park** a ticket when an open decision touches its core outcome: post the question on the ticket, label it `needs-info` (per `docs/agents/triage-labels.md`), and stop work on it.
- **Hold** the merge, and only the merge, on an open decision that doesn't touch the core outcome (a name, a registry row, a message's wording): build and review everything with the recommended default in place, and merge once it's ruled.
- **Judge by evidence.** Read the diff and the gate output, never a worker's report. Report success only with fresh output of the gate in the same message.
- **The gate** is the lane's gate command plus three pre-push checks: the worktree's HEAD descends from the remote branch's tip, every changed file is in the plan's Files, and `git log origin/main..<branch> --stat` shows only this ticket's commits.
- **Fix by churn.** Make a trivial change (a one-line deletion, a rename, a PR-body or label fix) inline, then run the gate yourself and state its output. Send a change that may start a run-and-fix loop (new behaviour, a fix whose cause isn't confirmed, an edit across several files) to a gated job.
- **The category follows the cause.** A project may gate `bug` fixes on a test that goes red first. When the confirmed cause turns out to be in test code, or the ticket adds behaviour no doc promised and fixes no hang, crash or lost data, relabel it (`test-only` or `enhancement`, per `docs/agents/triage-labels.md`) with a comment giving the cause, before the PR opens.
- **One worktree per job**, named for its branch, deleted on merge.

## Fast paths

Planning is spent where the ticket leaves something to decide. Two kinds of ticket skip the plan; every other ticket takes the full path.

### Confirmed bug

Take it when the root cause is **confirmed**: a red test, or a `diagnosing-bugs` result, names the faulty code, and the fix stays in the faulty module, the call sites a signature change forces, and its test. A small diff whose cause is a guess takes the full path. The cause decides, not the size.

Run step 1, skip steps 2–3, then build in a worktree cut from `origin/main`. The fence is that module, those call sites and the test, and it stands in for the plan's Files in the gate. Use an existing confirming test, or add one that goes red before the fix. Make the fix inline when **Fix by churn** allows, otherwise as a gated job whose brief names the cause, the fence and the gate, and has the job push, open a draft PR with the ticket's `Resolves` line, and report its URL and head SHA. Inline, do those three yourself. Then run steps 5–9 as written. Leave the fast path for step 2 when the fix spreads past the fence or the test won't go red.

### Determined ticket

Take it when the ticket is **determined**: it adds no new type, event, config key or doc decision, and its files are named in the ticket or found by one grep. A move, a rename or a mechanical removal is determined; a refactor that chooses new boundaries is not.

Run steps 1–2. When the preflight finds no `core` item, or step 2 skipped it as current, skip step 3: fill `../planning/briefs/lane.md` yourself, with a `PLAN` of three parts: Rung `standard`; Files (the preflight's file list, or the ticket's when step 2 skipped it); and Tasks (the ticket's acceptance criteria, each with the test or command that shows it met). `GATE` is the workflow doc's gate. Then run steps 4–9 as written. When a build fails twice on the same finding, write the plan (step 3) and continue from there.

### 1. Check setup

Read `docs/agents/` and the workflow doc it names; the workflow doc wins where it speaks. With no `docs/agents/`, stop and report "repo not set up".

A main orchestrator outside a flywheel then confirms with the owner the model pool for each rung (per the `delegate` skill) and a review pool: a correctness and an over-engineering reviewer, each from a family other than the implementers', at the same rung or higher. A sub-orchestrator takes these from its brief.

A task with no ticket gets one opened first, so every brief has an issue number.

Done when you know the tracker, labels, workflow doc and models, and the task has a ticket.

### 2. Preflight

Skip the preflight when a new ticket is **current**: the preflight exists to catch a stale ticket, and a current one cannot be stale. A ticket is current when all three hold, checked from an up-to-date clone:

- It names every file it touches and leaves no decision open.
- Every named file exists at `origin/main` (`git cat-file -e origin/main:<file>`).
- The ticket body names its filing commit, and `git log origin/main --since=<since> -- <named files> <docs it cites>` prints nothing. `<since>` is the later of the filing commit's date (`git show -s --format=%cI <commit>`) and the body's last edit (`gh api graphql -f query='{repository(owner:"<o>",name:"<r>"){issue(number:<n>){lastEditedAt}}}'`; null means never edited).

A ticket whose files all sit under a prototype path the workflow doc names checks its named files alone, not the docs it cites. Any miss runs the full preflight below. After a skip, whoever writes the plan gets the ticket in place of the preflight's report.

Prepare the base first. A new ticket's base is `origin/main`. A re-plan's base is the PR's branch, brought up to date: merge `origin/main` into it in the PR's worktree and push, so the preflight and the Verifier never read a stale branch. Run the preflight and the Verifier in a checkout of the base: an up-to-date clone on `origin/main`, or the PR's worktree.

Fill `../planning/briefs/preflight.md` (keys `ISSUE`, `SPEC`, `REPO`, `BASE` and `WORKFLOW_DOC`) with `fill-brief --out <absolute path>` (e.g. `~/.cache/agents/<repo>-<issue>-preflight.md`) and run it as its own job, on a `strong` model from a different family than yours, before any plan exists, using the printed line verbatim as the prompt, never a hand-written path. Save the preflight's report beside its brief as `<repo>-<issue>-preflight-out.md` and hand that path, never the brief's, to whoever writes the plan. A `core` item parks the ticket. `non-blocking` items and the file list go to the plan.

Done when the preflight has returned and no `core` item is open, or the ticket is current.

### 3. Plan

Follow `planning` steps 1–5.

Done when the lane brief is filled.

### 4. Lane

For a new ticket, cut a worktree from `origin/main`; a re-plan's lane works in the PR's worktree. Dispatch the lane brief on a model at the plan's Rung (per the `delegate` skill). The lane brief was filled with `fill-brief --out <absolute path>`; use the printed line verbatim as the lane's prompt, never a hand-written path.

A plan split into parts runs each part through steps 4–8 in order, the next lane cut once the previous part has merged.

Done when the lane reports a PR URL and head SHA, or a failure triage.

### 5. Gate

Confirm the remote tip equals the lane's reported SHA (`git log origin/<branch> -1`), read the diff, and run the gate yourself. A file outside the fence or a failing check goes back to the lane, or you take the work back.

Done when the gate passes on the remote tip.

### 6. Review

Run `review-loop` on the PR.

Done when `review-loop` is done.

### 7. CI

`ship-pr` (step 8) waits on CI; come here when it reports failing checks. Run `ci-triage` until the required checks are green on the current head SHA. Wait on the PR with `gh-ci wait <pr> --repo <owner/name>`, in the wait mode `ci-triage` gives; it follows a new head pushed mid-wait. Green comes from a fix, never a rerun: a flake gets `ci-triage`'s one fresh build and a `test-only` issue, and `gh-ci resample` only measures how often a failure happens.

Done when CI is green on the head a verdict covers.

### 8. Merge

When the workflow doc's merge rule allows a squash merge and the merge terms cover this PR, run `~/.agents/bin/ship-pr <pr> --repo <owner/name> --reviewed <head the last verdict covers: the FIX-OK verify's head after a fix round, else the reviewed head; never a rebase of it> [--unverified-fixes <findings file>, when `review-loop` step 2 skipped the verify] --worktree <worktree> --gate '<gate command>'` (keep its default CI `--timeout`), in the wait mode `ci-triage` gives. It gates the head first, then rebases (when `main`'s required checks are strict: if `origin/main` moved; otherwise only on a reported conflict; a rebase does not rerun the gate), marks a draft PR ready, waits on CI (required checks green on the exact head count, whenever they ran), runs `pr-closes`, squash-merges and cleans up, and prints `merged <sha>`. Add `--body-has '<prefix>'` once for each line the workflow doc requires in a PR body; `ship-pr` checks them first. Route any other exit, then rerun it:

- 124: CI is still pending. Rerun as is.
- 1: read stderr. Failing checks go to step 7, a failed gate goes back to the lane, and `origin/main moved during CI` means ship-pr already retried 3 times itself, so rerun it. After a failed merge or MERGED wait, check `gh pr view <pr> --json state` before rerunning: if it reads `MERGED`, finish the by-hand cleanup below instead.
- 3: `ship-pr` aborted the rebase, or found the PR conflicting with `origin/main` after its push. Run `git rebase origin/main` again, resolve with `resolving-merge-conflicts`, push with `--force-with-lease`, then rerun it with the same `--reviewed`. Take the new head through `review-loop`'s verify only when it then exits 4.
- 4: the patch changed (a rebase changed the diff, or a commit was added after review), and the new head may be local only. Push it with `--force-with-lease` first. A fix round with no real bug (`review-loop` step 2) takes no verify: rerun with `--unverified-fixes <findings file>` and the same `--reviewed`, and stop here. Otherwise run `review-loop`'s scoped verify, never a full re-review: `~/.agents/bin/review-pr start <pr> --repo <owner/name> --cwd <clone> --head <new full sha> --model <correctness> --verify <findings file> --since <reviewed head>`, then collect it. With no open findings, the file says `no open findings`: `review-pr` refuses an empty one. Rerun with the new head as `--reviewed` once the verify prints `FIX-OK`.
- 5: handle the printed matches as the next paragraph says. For printed `missing body line:` lines, add each to the PR body.
- 2: a precondition failed; stderr names it.

The rest of this step is the by-hand merge, for the cases `ship-pr` doesn't cover.

Run `~/.agents/bin/pr-closes <pr> --repo <owner/name>` first. Exit 1 lists each issue a closing keyword would close outside the PR's `Resolves` lines. Reword a title or body match and rerun. When only commit-message matches remain, merge with `gh pr merge --subject <title> --body <body>` so the squash commit carries the PR text alone.

Promote the draft PR to ready, then merge by the workflow doc's rule, plus any session terms the flywheel confirmed. Close the issues in the PR's `Resolves` lines, and no others: a `Part of` ticket stays open until its last part merges. Once `gh pr view <pr> --json state` reads `MERGED`, clean up by hand, since `gh pr merge --delete-branch` fails on a branch checked out in a worktree: delete the worktree, then the local branch (`git branch -D <branch>`), then the remote branch (`git push origin --delete <branch>`); a `remote ref does not exist` error means the repo already deleted it on merge, which counts as done.

Done when the PR is merged with `pr-closes` clean (OK, or only commit-message matches kept out of the squash), or escalated as the rules above say.

### 9. Report

The merge SHA, or the PR URL with its failure triage and the action someone must take; then **Friction**: up to 3 bullets. The main orchestrator then names the next phase: the next ticket on the frontier, or `retro` when the round is done.
