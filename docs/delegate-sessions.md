# Delegate session contracts

This page records the ordering and cardinality guarantees that session tests rely on.

## Box TMPDIR setup

Run `bin/box-setup` on the box as the box user to set `TMPDIR=/srv/lanes/tmp` for new SSH commands and systemd user services. From the Mac, run `ssh <box> 'bash -s' < bin/box-setup`, or run the script from a checkout on the box. It runs `systemctl --user daemon-reload` so the user manager re-reads `environment.d`; a systemd user unit picks up `TMPDIR` the next time it restarts after that reload.

Delegate session daemons that were already running keep their old environment. Before restarting one, check `delegate session list --json` and find its entry in `sessions[]`. Stop it only when `status` is `idle` and `activeTurnId` is `null`; a null active turn id alone can also mean a replay decision is pending. Run `delegate session stop <id>`, then start a fresh session with the original `delegate session start` arguments.

## Event and state ordering

`Store::update` appends event lines before publishing new state. A `watch` cannot return on that state until those lines exist. If the state write fails, the store attempts to truncate the append and keeps its in-memory state and event sequence unchanged.

A transition to `dead` appends one `session.dead` event. Later updates to an already-dead session do not append another. `logs --follow` reads state before draining complete event lines, so it drains `session.dead` before exiting.

`send`, `logs`, `watch`, and `stop` accept a full session id or a unique prefix. If a prefix matches multiple sessions, the command exits with code 2 and lists their ids. If it matches none, the command exits with code 3 and reports `no such session`.

`list` includes each valid session directory, marks a directory with unreadable state as `unreadable`, and sorts readable sessions by `startedAt`, then by session id. Human-readable entries use `<id> <status> <model> turns=<n> <cwd>`.

When `send` reaches an idle session, the reply is `started`. When it reaches a running session with an active turn, the host accepts a steer and waits up to the steer-reply deadline for resolution: `steered` means delivery was confirmed, and `unconsumed` means the host recorded that it was not delivered. `unconfirmed` means the wait expired while delivery was still pending; callers should wait for the session to become idle before resending. While a replay decision is pending (running with no active turn id), `send` returns `busy` (exit 5) and does not accept the text; callers must retain and retry it after the replay/continuation resolves.

## Job kill contracts

Each dispatched run spawns its child exactly once; a wall expiry during retry
backoff performs no respawn. The first kill signal to a run's process group is
SIGTERM. A clean wall kill and an idle stall each send just this one SIGTERM.
A wall-expired child that ignores SIGTERM gets SIGKILL after the kill grace,
and a user cancel after a watchdog kill sends SIGKILL at once, with no SIGTERM
grace. A cancel after a wall kill reads the cancel wording, not the wall
wording. Once the driver has reaped the child, further kill calls send
nothing, so a late kill cannot hit a recycled pid.

## Inbox notes

A matching turn completion with no pending steers changes the session from `running` to `idle` and triggers one `[session <id> idle]` inbox note. With pending steers, the session stays `running` (with no active turn id) while the replay worker waits for admission; the reader does not wait on admission. Under admission, the worker starts a pi replay turn without publishing `idle`, or publishes `idle` and the inbox note when replay is not needed (the pending steers have been resolved or the host is not pi). If pi still holds any pending steers, the session stays busy through the continuation and retries the replay decision when that turn completes, including when all pending steers remain queued. `watch` waits through a replay turn, `send` rejects new text as busy during the decision, and `stop --interrupt` does not return its idle no-op. The transition to `dead` triggers one `[session <id> dead]` note. If a verb finds a dead supervisor, a `dead.noted` marker lets only the first settling verb write the fallback note. Inbox writes are best-effort and do not change the verb's exit code.

## Pi host contracts

A steer queued before pi's internal `turn_end` poll is delivered on pi's next model turn. A steer accepted after that poll can remain queued after pi emits `agent_settled`: pi's queue operation does not start a new run once the previous run is settled. The supervisor therefore does not report `steered` immediately: it waits for the steer to be consumed, replayed, or marked unconsumed. If pi still reports a steer queued when a turn ends, the session stays `running` while the host waits for a continuation. If pi does not start one within 30 seconds, the supervisor asks pi to clear its queue, logs `steer.unconsumed`, and changes the session to `idle` with one inbox note. If clearing fails, the message can remain queued for a later explicit turn; it does not restart the settled run by itself.

The early-steer trace queues its steer before any tool call; the two post-tool traces queue after a tool call. In all three pi 1.5.0 traces, any steer still queued at `turn_end` is consumed by pi's next internal `turn_start` about 0.1 ms later, and the queue clears before `agent_settled`. The supervisor's post-settle wait for a host `TurnStarted` is therefore not entered in normal flow; 30 seconds remains a safety deadline for that unmeasured path. The slower `openai/gpt-6-luna` run completed in 5.782 seconds, and none of the traces triggered compaction. These traces show pi's internal continuation, not a new host-level `TurnStarted`. `pi::Wire` ignores internal `turn_start` events. Tests record this distinction rather than treating the internal event as a host event. The bound can be overridden with `DELEGATE_SESSION_PI_CONTINUATION_WAIT_MS`.

An interrupt requests that pi clear its queue before the abort. This is best-effort: pi may still continue queued messages after `stop --interrupt`; callers must not treat the clear request as proof that every queued steer was dropped. The host survives, the session returns to `idle` when the abort settles, and any unsent steer reported on the cancelled completion is logged as `steer.unconsumed`. The remaining interrupt/queue race is tracked as debt in `delegate/src/session/supervisor.rs`.

A steer that pi still holds when its internal `turn_end` poll runs starts the next turn: the supervisor does not replay it, and neither `steer.replayed` nor `steer.unconsumed` is logged; that continuation carries the steer as its `user` line, exactly once. If a queued steer remains pending past the caller's 10-second reply wait, `send` returns `unconfirmed`; if the supervisor resolves it sooner, `send` returns `steered` after delivery or `unconsumed` when it records the drop. `bin/ruled.sh` waits for idle and resends once after either uncertain result.

A steer pi accepted but no longer holds at turn end, and never delivered, is replayed: the supervisor logs `steer.replayed` and starts one new turn carrying the pending steers' text in order. If pi still holds some pending steers and dropped others, the supervisor waits for pi's continuation turn to end and replays the dropped ones then, so order is kept and pi never gets a second turn start.

Pending steers are replayed only for pi, whose host reports queue snapshots. At an MSP/Muse turn end, pending steers are logged as `steer.unconsumed` with their command ids and cleared, with no replay turn; Muse may execute a late steer itself, so replay could duplicate delivery. The Muse case is tracked in #1557.
