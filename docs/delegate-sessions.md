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

When `send` reaches an idle session, the host reply is `started`. When it reaches a running session with an active turn, the host reply is `steered`; that means the host accepted the message for its next model continuation. While a replay decision is pending (running with no active turn id), `send` returns `busy` (exit 5) and does not accept the text; callers must retain and retry it after the replay/continuation resolves.

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

A steer queued during a tool call reaches the next continuation: it is delivered after that turn's tool calls and before the next model call, and no `steer.unconsumed` line is emitted for it. When pi still reports the steer queued at turn end, the session stays `running` while waiting for `turn.started`; if no continuation starts within 30 seconds, the supervisor asks pi to clear its queue, logs the pending steers as `steer.unconsumed`, and changes the session to `idle` with one inbox note. The clear request is best-effort: pi may still continue a queued steer, so callers must not treat it as proof that pi dropped every steer. The bound is unmeasured: the fake starts the continuation in the same settled-event cycle, but no checked-in real-pi trace records this gap. Thirty seconds is 15× the 2-second `STEER_SETTLE` wait, a margin rather than a measurement. `TurnStarted` may wait on the first model response, so a slow model or compaction can exceed 30 seconds. Tests or hosts can override the bound with `DELEGATE_SESSION_PI_CONTINUATION_WAIT_MS`.

An interrupt requests that pi clear its queue before the abort. This is best-effort: pi may still continue queued messages after `stop --interrupt`; callers must not treat the clear request as proof that every queued steer was dropped. The host survives, the session returns to `idle` when the abort settles, and any unsent steer reported on the cancelled completion is logged as `steer.unconsumed`. The remaining interrupt/queue race is tracked as debt in `delegate/src/session/supervisor.rs`.

A steer racing the end of a turn starts the next turn: pi still holds it in its queue, so the supervisor does not replay it, and neither `steer.replayed` nor `steer.unconsumed` is logged; the queued steer opens a new turn that carries it as its `user` line, exactly once.

A steer pi accepted but no longer holds at turn end, and never delivered, is replayed: the supervisor logs `steer.replayed` and starts one new turn carrying the pending steers' text in order. If pi still holds some pending steers and dropped others, the supervisor waits for pi's continuation turn to end and replays the dropped ones then, so order is kept and pi never gets a second turn start.

Pending steers are replayed only for pi, whose host reports queue snapshots. At an MSP/Muse turn end, pending steers are logged as `steer.unconsumed` with their command ids and cleared, with no replay turn; Muse may execute a late steer itself, so replay could duplicate delivery. The Muse case is tracked in #1557.
