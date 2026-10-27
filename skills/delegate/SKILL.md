---
name: delegate
description: >
  Run work on other models through the `delegate` CLI. Use when starting a delegated job,
  picking a model, writing a brief, waiting on or reading a job, or answering a NEEDS_CONTEXT
  job with resume.
---

# Delegate

Run `delegate` (no arguments) for the command syntax, and `delegate models` for the live model
table with backends, prices and tiers.

## Model ladder

Pick the lowest rung whose definition covers the job:

- `standard`: implements, reviews and explores from a clear brief. Follows the plan as written, flaws included, so it needs a plan someone else checked.
- `strong`: under-specified tickets. Makes local design calls, and stops and flags a plan that's wrong instead of following it. Writes a lane brief from an approved plan. Checks a plan as the Verifier.
- `frontier`: long-horizon planning, cross-cutting design, sub-orchestrating a ticket, and the last escalation before the owner.

The current pool is in the `delegate models` Tiers column. Use a model with no rung only when the owner names it. Within a rung, pick the cheapest model with headroom (the `$OUT/1M` column); on a price tie, pick the provider with more headroom.

When the pick is a Claude model and you run in a Claude Code session, start it as a local `claude-worker` subagent with that model and effort (`model: haiku` for `claude-haiku-5-5`), and run the gate yourself on its result. A script with no session to host a subagent, such as `review-pr`, passes the Claude model to `delegate run`. A session started before Claude Code learned of a model may resolve its alias to the older one (`haiku` to Haiku 4.5), so check the model id the subagent reports.

At session start, propose a pool per rung from `delegate models` and `~/.agents/bin/quota`, showing each provider's headroom. The owner confirms it. When the owner is unavailable, use the last confirmed pool, step down within the rung when a provider runs low, and report the switch.

A provider's headroom is its remaining quota on its tightest window (session, weekly or monthly): the lowest percent on its line from `~/.agents/bin/quota`. Map providers by backend or prefix: the `cursor` backend, `opencode-go/*`, `claude-*`, `muse/*`, and `openai/*`.

Mechanical jobs (rebase conflicts and compile fixes, formatting and lint fixes, mutant-killing tests, renames, moves, repeated edits) take the cheapest `standard` model; when it fails, the next cheapest. A Claude model that reviews, verifies or diagnoses runs at `:medium`, and `:high` only after it fails twice on one finding. A diagnosis reports the cause and its evidence, and leaves the fix to a lane.

Escalation: when a model fails, go up one rung. When a `frontier` model fails, stop and ask the owner. Never escalate to a model with no rung.

Review rule: review with a model from a different family than the implementer's, at the same rung or higher. Family means the model's maker, such as Anthropic, OpenAI, xAI or Cursor, not its backend or provider.

Muse backend: `muse/*` models run `muse exec` and carry the `standard` and `strong` rungs, and they are the preferred cheap pick: the `opencode-go/muse-*` route costs the same per token but its quota is nearly spent. Where muse is missing or the sandbox that was turned on is unusable, fall back to `openai/gpt-6-luna:xhigh` or `claude-haiku-5-5`. `bin/quota` prints a muse line (a provider QuotaBar cannot read prints `unavailable` and the reason), so read muse headroom there; what a muse run does at its limit is not mapped yet. The sandbox is off by default on every host, so the worktree is the only containment; a host profile with `museSandbox: true` turns the muse sandbox on, blocking writes outside the workspace with network through the proxy. A run with no tool result, model text or terminal for the idle window ends `STALLED` (a long silent tool call needs a higher `idleMs`), every run has a hard wall cap from the tool-idle limit, and the job record carries `allowance` window and weekly used percent plus reset times. `delegate doctor` does not check muse yet.

## Briefs

Every brief carries exactly one of these lines, verbatim:

- Worker: "Do not delegate further."
- Sub-orchestrator: "You may delegate through `delegate`; workers you start must not delegate
  further."

A brief without one is incomplete. A worker brief with a gate also carries, verbatim: "Run the gate in the foreground. If it is too slow for one tool call, run the narrowest affected test set in the foreground and leave the full gate to delegate's own gate at job end. Run every process in the foreground."

## Running

```bash
delegate run --model composer-2.5 --cwd /abs/repo \
  --gate 'scripts/check' < brief.md
```

The gate is the repo's own gate command (its workflow doc names it, e.g. `scripts/check` or `cargo nextest run`), exactly as CI runs it.

`run` prints the job id and returns; the job runs in a detached supervisor.
A Claude model id may carry a trailing `:<level>` (`low|medium|high|xhigh|max`), passed to `claude` as `--effort` (e.g. `claude-opus-5-5:high`).
Every job can write, so a read task says "do not edit" in its brief, the record's
`changeSet` shows any write, and parallel jobs need separate cwds (one worktree per lane).

**Write the gate as a shell command** that `/bin/sh -c` runs: an English postcondition is a
syntax error, and nothing is checked. Make it the next consumer's first action: if a packer
feeds a runner, the gate runs the runner. A gate that greps for a file is not a gate. Read
`result.gateResult` in the record, never the job's own report of its gate, and rerun the check yourself when `passed` is false.

`delegate resume <id>` takes the new prompt on stdin and prints the new job id. `--model` must
stay on the same backend. It adds `supersededBy` to the old record. A `CANCELLED`, `STALLED` or
`ERROR` record with a session id can be resumed; it exits 2 for a `RUNNING` job or a record with
no session id, except a Fiber record with no session id resumes as a fresh run on an explicit
resume. A cancelled record with no session id is still refused (exit 2), and a cancelled job
never restarts by itself. Cursor, pi and claude were verified (2026-10-04) to resume a session cancelled
mid-turn. Answer `NEEDS_CONTEXT` with it. A resumed lane whose `result.changeSet.newCommits` comes back empty committed nothing: start a fresh job.

`--tool-idle-ms` widens how long a running tool may stay silent before the idle watchdog
kills the job (default 1800000, 30 min; a model silent between tools gets 300000). It also
bounds the gate.

`--idle-ms` sets the model-idle window for that one run, overriding the host-profile `idleMs`
(default 300000); `muse/*` runs get 1800000 from `bin/tkt-job`.

`--wall-ms N` caps the whole run in milliseconds: agent, retry backoff and job-end gate.
It is off by default; `bin/tkt-job` passes 10800000 (3 h) for `verifier-r*` slots. Expiry
is `CANCELLED` with `Cancelled: wall budget of ...`; a resume gets a fresh full budget.
The first kill is SIGTERM; a wall-expired child that ignores it gets SIGKILL after the
grace, while an idle stall sends a single SIGTERM. A user cancel after a watchdog kill
sends SIGKILL at once and reads the cancel wording, and a wall expiry during retry
backoff performs no respawn.

## Waiting

`watch` blocks until every listed job is terminal, then prints their records on stdout. It is
the only way to wait; run it in the background the way your harness's instructions say. On
timeout, it prints the still-RUNNING records, exits 1 and writes one stderr line per job. The
`progress` field holds the partial state: phase, last tool, last assistant text, files touched,
tokens, elapsed time, last-event age and session id. Run `watch` again to keep waiting. A job's state and result
come from `status` and the record file below; `status` prints the job's state without waiting, `watch` waits for and prints the result, and `delegate` has no `result` subcommand.

Judge liveness by `progress.lastEventAgeMs` (ms since the last event the supervisor counted as
liveness, the same instant `--idle-ms` measures from), never by `tokensSoFar`: `tokensSoFar` is
live on cursor, claude and fiber, but stays 0 until the end on pi, codex and muse (the final
`result.usage` carries the count). The stored age is as of `lastHeartbeatAt`, written every 30 s;
`watch --timeout` prints the corrected age on its stderr line. `lastHeartbeatAt` proves the
supervisor is alive, not that the model is working. On muse the age ignores raw stdout chunks and
stderr, exactly as its idle watchdog does. The age keeps growing while a retry backs off or the
job-end gate runs (status stays RUNNING); neither is a stall.

```bash
delegate watch <id-a> <id-b> --timeout 1800
```

## Reading the result

The record is `DELEGATE_JOBS_DIR/<id>.json` when that override is set, else `$TMPDIR/delegate-jobs/<id>.json` (a terminal record has no `lastHeartbeatAt`). If the job started under another `TMPDIR`, set `DELEGATE_JOBS_DIR=<that dir>/delegate-jobs` before you run `cancel`, `watch` or `resume`. They search that dir first, then your `$TMPDIR/delegate-jobs`, then `/tmp/delegate-jobs`. The unknown-job error lists every directory searched:

```json
{"status":"DONE","result":{"status":"DONE","text":"Renamed the helper in 4 files.\n\nSTATUS: DONE","sessionId":"7c1e0a52-3b9f-4e0c-9a55-0d6f1b2c8e41","backend":"cursor","model":"model-id","usage":{"inputTokens":18234,"outputTokens":1207,"cacheReadTokens":9100,"cacheWriteTokens":0},"costUsd":0.0148,"costEstimated":true,"durationMs":84213,"jobId":"d2f4a8e6-51c7-4b3a-8f90-6e1a7c3b5d02"},"supervisorPid":48213,"resume":{"model":"model-id","cwd":"/abs/repo","sessionId":"7c1e0a52-3b9f-4e0c-9a55-0d6f1b2c8e41","gate":"cargo test","toolIdleMs":null}}
```

`status` is `DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, `NEEDS_CONTEXT`, `ERROR` (from the
agent's trailing STATUS line or the supervisor), `CANCELLED`, or `STALLED` (the idle watchdog
killed it: rerun, with a larger `--tool-idle-ms` if it stalled inside a tool). A wall-capped
job reads `CANCELLED`, and `tkt-job` prints it as `WALL-CAP`. `text` is the agent's final message; for
`NEEDS_CONTEXT` it is the question.

- `result.gateResult`: a failing gate downgrades `DONE` to `DONE_WITH_CONCERNS`; it holds the
  gate's `exitCode`, `outputTail` and `outputPath`, the file with the gate's full output.
- `result.changeSet`: git delta for the cwd (`newCommits`, `filesChanged`, `diffstat`,
  `uncommittedFiles`).
- `result.concerns`: warnings from the CLI, e.g. commits landed but the tree is still dirty.
- `result.retries`: present when delegate resumed the session after a transient provider error
  (a 5xx, or one 401), at most twice: one entry per failed attempt, and usage, cost and
  duration add up across attempts. It is history, not the final cause: read the final error
  before deciding to resume.

- **Resume chain:** follow `supersededBy` to the newest record; the old one stays as it was.
- **Stuck job:** `watch` rewrites a record whose supervisor pid is dead to `ERROR` ("supervisor
  died"). A live supervisor whose `lastHeartbeatAt` has gone stale is not healed: `delegate
  cancel` it and rerun. Before you report a job stopped, read its record (following
  `supersededBy`): `RUNNING` means it has not stopped, even if your own wait or its output
  ended; check `supervisorPid` with `ps -p`, and report stopped only for a terminal `status`
  or a `RUNNING` record whose supervisor pid is gone.
- A weak model may skip the STATUS line and guess; your review of the artifact is the backstop.
- An empty final reply is reported DONE_WITH_CONCERNS with the concern "empty final message".

## Exit codes

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | `watch` timed out, or `doctor` hard failure |
| 2 | bad input or unknown job |

## Muse sessions

Use `delegate session` for a long-running Muse sub-orchestrator. Each session runs on the machine where you invoke the command. Delegate does not connect to remote hosts; call it through `ssh` when needed.

```bash
delegate session start --model muse/muse-spark-1.3-contributor \
  --brief /abs/brief.md --inbox /abs/inbox --json
delegate session send <id> 'Check the test results'
delegate session logs <id> --follow
delegate session watch <id>
delegate session stop <id>
delegate session list
```

`start` creates a detached `muse serve` supervisor and sends the brief as the first user turn, unchanged. The brief is user-provided task text, not a system instruction. The session can send progress and its final report to the starter's file inbox with `inbox-send`; include this line in its brief:

```text
Send progress messages and your final report to the starter's file inbox with `inbox-send`.
```

Muse sessions use `--disable-sandbox` and `allowAll`. The worktree is the only containment. Keep the session's work inside its worktree.

`--inbox` is a path on the session machine. The supervisor writes one-line backstop notes such as `[session <id> idle]` and `[session <id> dead]`. The note does not replace messages sent with `inbox-send`.

Use `send <id> TEXT` to start a turn when idle or steer the active turn. `send <id> -` reads text from stdin; it fails rather than prompting when stdin is a terminal. For text that starts with a dash, use `send <id> -- TEXT`. Text is limited to 8 MiB, must be non-empty after trimming, and cannot contain NUL.

`steered` means the host accepted the message for application on the next model continuation. It does not mean the model has acted on it yet.

Plain `stop` interrupts a running turn, closes host stdin, and ends the session. `stop --interrupt` interrupts the running turn and keeps the session; at idle, it is a no-op.

`watch` is level-triggered: it returns immediately when the session is already idle or dead. Call it after `send` to wait for the current turn to finish. It returns exit code 0 for idle and 4 for dead; watching does not wait for a future turn.

`logs --follow` emits complete event lines as they arrive, then exits when the session is dead. Without `--follow`, logs returns the complete lines already written. A partial final line is not emitted.

Every session verb accepts `--json`. Success output has these shapes:

| Verb | JSON output |
|---|---|
| `start` | `{"ok":true,"session":<State>}` |
| `send` | `{"ok":true,"disposition":"started|steered","session":<State>}` |
| `logs` | `{"ok":true,"lines":[<event>, ...]}` without `--follow`; JSON lines with `--follow` |
| `watch` | `{"ok":true,"session":<State>}` |
| `stop` | `{"ok":true,"interrupted":true|false,"session":<State>}` |
| `list` | `{"ok":true,"sessions":[<State>|{"id":"..","status":"unreadable"}, ...]}` |

Errors produce `{"ok":false,"error":{"code":"...","message":"..."}}` on stdout and a diagnostic on stderr. `watch` on a dead session is a successful JSON response with exit code 4.

| Exit code | Meaning |
|---|---|
| 0 | Success; `watch` found an idle session |
| 1 | Startup, host, I/O, unreadable-state or supervisor failure |
| 2 | Usage error |
| 3 | No such session |
| 4 | Dead session; `watch` found a dead session |
| 5 | Session busy or stopping |

Use this form to start a session on a remote machine through SSH:

```bash
ssh box 'cd /abs/worktree && delegate session start --model muse/muse-spark-1.3-contributor --brief /abs/brief.md --inbox ~/flywheel-inbox --json'
```

The command still runs locally on the box. `delegate` has no `--host` option. Keep `--inbox` on that machine; the caller can pull its files separately.
