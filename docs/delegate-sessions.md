# Delegate session contracts

This page records the ordering and cardinality guarantees that session tests rely on.

## Event and state ordering

`Store::update` appends event lines before publishing new state. A `watch` cannot return on that state until those lines exist. If the state write fails, the store attempts to truncate the append and keeps its in-memory state and event sequence unchanged.

A transition to `dead` appends one `session.dead` event. Later updates to an already-dead session do not append another. `logs --follow` reads state before draining complete event lines, so it drains `session.dead` before exiting.

`send`, `logs`, `watch`, and `stop` accept a full session id or a unique prefix. If a prefix matches multiple sessions, the command exits with code 2 and lists their ids. If it matches none, the command exits with code 3 and reports `no such session`.

`list` includes each valid session directory, marks a directory with unreadable state as `unreadable`, and sorts readable sessions by `startedAt`, then by session id. Human-readable entries use `<id> <status> <model> turns=<n> <cwd>`.

When `send` reaches an idle session, the host reply is `started`. When it reaches a running session, the host reply is `steered`; that means the host accepted the message for its next model continuation.

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

A matching turn completion changes the session from `running` to `idle` and triggers one `[session <id> idle]` inbox note. The transition to `dead` triggers one `[session <id> dead]` note. If a verb finds a dead supervisor, a `dead.noted` marker lets only the first settling verb write the fallback note. Inbox writes are best-effort and do not change the verb's exit code.

## Pi host contracts

A steer queued during a tool call reaches the next continuation: it is delivered after that turn's tool calls and before the next model call, and no `steer.unconsumed` line is emitted for it.

An interrupt clears the queue before the abort and the host survives: `stop --interrupt` (and a plain `stop` on a running turn) sends `clear_queue` before the abort, dropping unsent steers, which are reported as one `steer.unconsumed` line on the cancelled completion; the host process keeps running and the session returns to `idle`.

A steer racing the end of a turn starts the next turn: pi still holds it in its queue, so the supervisor does not replay it, and neither `steer.replayed` nor `steer.unconsumed` is logged; the queued steer opens a new turn that carries it as its `user` line, exactly once.

A steer pi accepted but no longer holds at turn end, and never delivered, is replayed: the supervisor logs `steer.replayed` and starts one new turn carrying the pending steers' text in order. If pi still holds some pending steers and dropped others, the supervisor waits for pi's continuation turn to end and replays the dropped ones then, so order is kept and pi never gets a second turn start.
