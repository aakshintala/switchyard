---
name: autonomous-flywheel
description: "Flywheel: land a stack of tickets or PRs through parallel lanes, at any hour, with the owner away: frontier, fences, merge terms, round report. Fires when asked to run or continue a flywheel session, or to land a stack of PRs."
---

# Autonomous flywheel

Schedule many tickets through `implement` in parallel lanes, or many PRs through `review-loop` and `ci-triage`. Each ticket's own work is `implement`; this skill holds only the scheduling around it. The owner confirms the session at start, then may be away for the rest of it.

### 1. Confirm the session

First run `implement` step 1 (check setup). Then, with the owner, at start (a typed start means they're present now):

- Repo, work source (a list of tickets, or a stack of PRs for PR-stack mode), base commit.
- Models: the pool for each rung (per the `delegate` skill), a review pool (a correctness and an over-engineering reviewer, each from a family other than the implementers', at the same rung or higher), and the lane budget (2 works).
- Merge terms: the cases that need the owner's call beyond the workflow doc's merge rule. Terms only add cases; the workflow doc's merge rule always holds. CI-boundary changes (workflows, rulesets) need the owner's call unless the terms include them. When the terms include them, these still need the owner's call (owner, 2026-10-08):
  - ruleset or branch-protection changes;
  - `secrets.*`, `permissions:`, `pull_request_target`, and release or publish workflows;
  - adding a third-party action, or pinning one to a branch rather than a tag or SHA (a bump of a first-party `actions/*` action is a normal change);
  - making the required check pass where the repo's CI doc says it fails, for example a gating job missing from the required aggregate job's `needs` (removed, or a new job never added), a renamed required check, or `continue-on-error`.
- `gh auth status` shows the `workflow` scope; without it, PRs touching `.github/workflows/*` fail to merge.
- Whether the owner will be around for rulings (see `implement`).

Write these to the state file (step 4).

Done when the owner has confirmed every bullet.

### 2. Fill the lanes

- Take the **frontier**: open tickets whose blockers are all closed. A ticket enters a lane only when its fence (the plan's Files) is disjoint from every running lane's. Before dispatch, read each ticket's acceptance for an **owner-only step** (a billed probe, credentials, a dashboard action): ask the owner for it now when present, otherwise park the ticket with the question on it.
- Start each ticket's sub-orchestrator with `briefs/ticket-orchestrator.md`, filled with `~/.agents/bin/fill-brief --out ~/.cache/agents/<repo>-<issue>-ticket-orchestrator.md` (`SKILLS` is this pack's `skills` folder as an absolute path, so a harness that doesn't load the pack still finds `implement`). Fill `PARENT` with this session's name (below); on a harness without session names, with `main orchestrator`. Use the printed line verbatim as the sub-orchestrator's prompt, never a hand-written path. It runs `implement` for that ticket and reports back here.
- On Claude Code, start each sub-orchestrator as its own background session: `claude --bg -n <repo>-<issue> --agent ticket-orchestrator --permission-mode auto "<printed line>"`, with `PARENT` filled as this session's name as `ListAgents` prints it. A flywheel running as a subagent has no session name: stop and report that it can't start lanes. Subscribe to each lane with `SendMessage` `notify_when_idle` as a backstop. Run `claude stop <id>` once its report has arrived and been read. If the idle notice comes with no report, read `claude logs <id>`, then stop it. A finished session stays resident until stopped.
- Give every job its own worktree: delegation doesn't enforce read-only, so a shared directory lets parallel jobs damage each other. In the shared checkout run only `git fetch`.
- When a lane closes, start the next disjoint ticket at once. An idle lane needs a reason in the state file (no disjoint work, or a pending ruling reshapes the queue).
- **Lane runtime**: the two bullets above on `claude --bg --agent ticket-orchestrator` are the default. A repo that ships its own flywheel scripts (fiber: `bin/mkbrief.sh`, `pilaunch.sh`, `pisend.sh`, a file inbox, state under `~/work/fiber-worktrees/flywheel/run/`) runs pi RPC lanes through them instead: its scripts override the launch, brief-fill and notify steps; every other step here still applies.
  A flywheel may cap concurrent cargo builds on one host with `~/.agents/bin/cargo-slot`. A lane puts it on its PATH by installing it as `cargo` in a directory placed first on the lane's PATH (`ln -s ~/.agents/bin/cargo-slot <dir>/cargo`). `CARGO_SLOTS=N` sets the slot count (unset, empty or `0` leaves the shim inert), and `CARGO_SLOT_DIR` sets the slot directory (default `~/.cache/agents/cargo-slots`). A slot is held until the cargo process and its children exit, so a long-lived `cargo run` holds its slot for its whole life. N and the PATH wiring are the flywheel's call. Set `CARGO_SLOT_SHARED_CHECKOUT` to the shared checkout's path and the shim also refuses slot subcommands run from that checkout, so the inert rule above holds only while it is unset or empty.

**PR-stack mode**: for PRs with no ticket, run `review-loop`, then `ci-triage`, then merge by `implement` step 8, for each PR in the stack.

Done when every lane is filled or its idle reason is recorded.

### 3. Rule and merge

Answer each sub-orchestrator's escalations as `implement`'s rules say. Merge a PR only within the confirmed terms; a case the terms don't cover goes to the owner by `implement`'s presence rule.

Done when every reported PR is merged, or waits on the owner with the exact action posted.

### 4. Keep the state file

Keep `~/.cache/agents/<repo>-flywheel-state.md` (durable: a reboot clears `/tmp`): the session config, each lane's ticket, branch, worktree and status, open escalations, rulings made, and the next steps. Update it after every merge, ruling and lane change, and stamp each entry with the time `date` prints, since a recalled time drifts. A fresh session continues from this file alone; `/handoff` is not involved.

Done when, after each update, the file alone would let a fresh session continue.

### 5. Close the round

1. Run `retro` on the round.
2. Write the round report: merged / open / parked, items needing the owner with exact actions, and leftover threads with issue links. Short.

Done when the report lists every ticket's or PR's end state and every owner action.
