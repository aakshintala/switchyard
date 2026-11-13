---
name: autonomous-flywheel
description: "Flywheel: land a stack of tickets or PRs through parallel lanes, at any hour, with the owner away: frontier, fences, merge terms, round report. Fires when asked to run or continue a flywheel session, or to land a stack of PRs."
---

# Autonomous flywheel

Schedule many tickets through `implement` in parallel lanes, or many PRs through `review-loop` and `ci-triage`. Each ticket's own work is `implement`; this skill holds only the scheduling around it. The flywheel sets the session at start; it does not wait for the owner.

### 1. Confirm the session

First run `implement` step 1 (check setup). Then set the session:

- Repo, work source (a list of tickets, or a stack of PRs for PR-stack mode), base commit.
- Models: flywheel chooses the pool for each rung (per the `delegate` skill), a review pool (a correctness and an over-engineering reviewer, each from a family other than the implementers', at the same rung or higher), and the lane budget (2 works).
- Merge terms: the cases that need flywheel's call beyond the workflow doc's merge rule. Terms only add cases; the workflow doc's merge rule always holds. The terms also name the repo's CI contract owner (for Fiber, surveyor); with none named, the triage role decides in that role. Workflow changes that don't publish are flywheel's call. Adding or pinning third-party actions is the CI contract owner's call. These stay owner-held (owner, 2026-10-08):
  - ruleset or branch-protection changes;
  - `secrets.*`, `permissions:`, `pull_request_target`, and release or publish workflows;
  - making the required check pass where the repo's CI doc says it fails (for example a gating job missing from the required aggregate job's `needs`, whether removed or never added, a renamed required check, or `continue-on-error`). When the terms include CI-boundary changes, this needs the CI contract owner's approval instead (owner, 2026-11-01). A doc edit in the same pull request is never that approval.

  Items that remain owner-held release only on the owner's own words, quoted with where they were typed. The CI contract owner's approval likewise is its own message, quoted with where it was sent. A tracker comment's author field proves neither: every session posts with the owner's credentials, so an agent's comment shows the same login and `OWNER` association as the owner's.
- `gh auth status` shows the `workflow` scope; without it, PRs touching `.github/workflows/*` fail to merge.
- Flywheel owns the session start; no owner-availability check is needed for rulings.

Write these to the state file (step 4).

Done when flywheel has set the session terms.

### 2. Fill the lanes

- Take the **frontier**: open tickets whose blockers are all closed. A ticket enters a lane even when its fence (the plan's Files) overlaps a running lane's. The dispatch shows the overlap (`OVERLAP` lines and `overlap:` grant lines printed by `fence-grant`/`file-claim`) to the orchestrator and the lane. Only a running `sweep-` lane's fence keeps an overlapping ticket out. Before dispatch, read each ticket's acceptance for an **owner-only step** (a billed probe, credentials, a dashboard action): ask the owner for it now when present, otherwise park the ticket with the question on it.
- Start each ticket's sub-orchestrator with `briefs/ticket-orchestrator.md`, filled with `~/.agents/bin/fill-brief --out ~/.cache/agents/<repo>-<issue>-ticket-orchestrator.md` (`SKILLS` is this pack's `skills` folder as an absolute path, so a harness that doesn't load the pack still finds `implement`). Fill `PARENT` with this session's name (below); on a harness without session names, with `main orchestrator`. Use the printed line verbatim as the sub-orchestrator's prompt, never a hand-written path. It runs `implement` for that ticket and reports back here. Each launch note cites every ruling by comment ID and quotes it verbatim; on a relaunch, make the ruling the first prompt, and let the ruling comment win over conflicting ticket text.
- On Claude Code, start each sub-orchestrator as its own background session: `claude --bg -n <repo>-<issue> --agent ticket-orchestrator --permission-mode auto "<printed line>"`, with `PARENT` filled as this session's name as `ListAgents` prints it. A flywheel running as a subagent has no session name: stop and report that it can't start lanes. Subscribe to each lane with `SendMessage` `notify_when_idle` as a backstop. Run `claude stop <id>` once its report has arrived and been read. If the idle notice comes with no report, read `claude logs <id>`, then stop it. A finished session stays resident until stopped.
- Give every job its own worktree: delegation doesn't enforce read-only, so a shared directory lets parallel jobs damage each other. In the shared checkout run only `git fetch`.
- When a lane closes, start the next ticket at once. An idle lane needs a reason in the state file (no unblocked work, a running sweep holding its fence, or a pending ruling reshapes the queue).
- When handing an open PR to the owner, retire the lane with `lanecheck done <ticket> --handed-to-owner <card-id>`; the open card must name the PR or ticket.
- **Lane runtime**: the two bullets above on `claude --bg --agent ticket-orchestrator` are the default. A repo that ships its own flywheel scripts (fiber: `bin/mkbrief.sh`, `pilaunch.sh`, `pisend.sh`, a file inbox, state under `~/work/fiber-worktrees/flywheel/run/`) runs pi RPC lanes through them instead: its scripts override the launch, brief-fill and notify steps; every other step here still applies.
  Lane liveness on a shipped host: `~/.agents/bin/lanestat <run-dir>` and `~/.agents/bin/lanewatch <run-dir> [ssh-target]`, which this flywheel's own `lanestat.sh` and `lanewatch.sh` predate.
  A flywheel may cap concurrent cargo builds on one host with `~/.agents/bin/cargo-slot`. A lane puts it on its PATH by installing it as `cargo` in a directory placed first on the lane's PATH (`ln -s ~/.agents/bin/cargo-slot <dir>/cargo`). `CARGO_SLOTS=N` sets the slot count (unset, empty or `0` turns off the slot cap, but the shim still refuses `cargo mutants`: lanes take mutants from CI via `mutant-verdicts`), and `CARGO_SLOT_DIR` sets the slot directory (default `~/.cache/agents/cargo-slots`). A slot is held until the cargo process and its children exit, so a long-lived `cargo run` holds its slot for its whole life. While waiting, the shim prints a periodic notice; `CARGO_SLOT_NOTICE_SECS` sets the interval in seconds (default 60), and `<n>` counts elapsed intervals. N and the PATH wiring are the flywheel's call. Set `CARGO_SLOT_SHARED_CHECKOUT` to the shared checkout's path and the shim also refuses slot subcommands run from that checkout, so the inert rule above holds only while it is unset or empty. Set `CARGO_SLOT_WORKTREE_ROOT` beside it to the directory scratch worktrees go in, and the refusal also prints the `worktree add --detach <root>/<name>` command for a job with no ticket worktree (a diagnosis or audit); unset or empty, the refusal is unchanged.
  A flywheel may guard the `needs-owner` and `needs-triage` labels on a lane's PATH with `~/.agents/bin/gh-label-guard`. A lane puts it on its PATH by installing it as `gh` in a directory placed first on the lane's PATH (`ln -s ~/.agents/bin/gh-label-guard <dir>/gh`), never on an orchestrator's or sub-orchestrator's PATH. It refuses `gh issue|pr edit` with `--add-label`/`--remove-label` and `gh issue|pr create` with `--label`/`-l` naming `needs-owner` or `needs-triage`, exiting 1 with a message sending the question to the orchestrator; it runs the real `gh` for everything else and does not cover `gh api`.
  A flywheel may guard a lane's git hooks with `~/.agents/bin/git-hook-guard`, installed as `git` the way `gh-label-guard` is (`ln -s ~/.agents/bin/git-hook-guard <dir>/git`), never on an orchestrator's or sub-orchestrator's PATH. It refuses `--no-verify` on `git commit`, `push`, `merge`, `rebase` and `am` (and `-n` on commit and am), a `git config` write to `core.hooksPath`, `core.hooksPath` set by `-c`, `--config-env`, `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*` or `GIT_CONFIG_PARAMETERS`, an alias that expands to a refused form, `git hook run`, `HUSKY=0`, and `SKIP` set on a hook-running subcommand, exiting with a message telling the lane to stop with `STATUS: BLOCKED`; it also refuses a bare `git stash`, `git stash push` without `-m`, and `git stash pop`, naming the tagged push/apply/drop flow; it runs the real `git` for everything else. It does not cover a `!` shell alias that runs git with a refused form, a call from a test run (`NEXTEST_RUN_ID` set, or a working directory under the temp dir), editing a hook file, or a push through `gh api`; the lane brief's rule covers those.

**PR-stack mode**: for PRs with no ticket, run `review-loop`, then `ci-triage`, then merge by `implement` step 8, for each PR in the stack.

Done when every lane is filled or its idle reason is recorded.

### 3. Rule and merge

Answer each sub-orchestrator's escalations as `implement`'s rules say. Merge a PR only within the confirmed terms, through `tkt-ship` or `ship-pr`, never a bare `gh pr merge`: they refuse a worktree head that differs from the PR head and a patch changed since review. Watch a PR's CI with `~/.agents/bin/gh-ci wait <pr>`, never a hand-rolled `gh pr checks` loop: it prints the head each verdict covers and discards a verdict when the head moves. Report a CI verdict with the head SHA it covers. A merge neither tool covers, like a case the terms don't cover, goes to flywheel. A truly novel decision uses one dashboard card (`owner-ask file ...`) and parks the ticket; never ask in chat.

A merge the permission system denies ends merging for the session, even when an earlier merge in the same session succeeded. Record the denial in the state file. Attempt no merge by any route after it, `ship-pr` and `tkt-ship` included: a second route to a denied action is scored as a bypass. Hand no merge to a lane or peer either: a merge run elsewhere launders the denial. The round's goal becomes green and reported: drive each remaining PR to green with its review loop closed, then list them in the round report as one owner action, with each PR number and its exact merge command.

Done when every reported PR is merged, or waits on the owner with the exact action posted.

### 4. Keep the state file

Keep `~/.cache/agents/<repo>-flywheel-state.md` (durable: a reboot clears `/tmp`): the session config, each lane's ticket, branch, worktree and status, open escalations, rulings made, and the next steps. A recorded block names what holds it, not only what it waits on: the gate (the rule or required check), the ruling that set it, and who can lift it; an edge alone ("#3900 is blocked through #3907") sends a fresh session back to GitHub to re-derive whether it still holds. Update it after every merge, ruling and lane change, and stamp each entry with the time `date` prints, since a recalled time drifts. A fresh session continues from this file alone; `/handoff` is not involved.

Done when, after each update, the file alone would let a fresh session continue.

### 5. Close the round

1. Run `retro` on the round.
2. If pages in the wiki at `~/work/wiki` were added or changed this round, run its lint pass: `delegate run --model openai/gpt-6-luna:medium --cwd ~/work/wiki --prompt-file ~/work/wiki/lint-brief.md`.
3. Write the round report: merged / open / parked, items needing the owner with exact actions, leftover threads with issue links, and the lint pass's merges and supersessions. Short.

Done when the report lists every ticket's or PR's end state and every owner action, and any lint pass the round needed has run.
