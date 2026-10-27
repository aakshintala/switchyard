# Delegate session contracts

This page records the ordering and cardinality guarantees that session tests rely on.

## Event and state ordering

`Store::update` writes the new state before it appends the update's event lines. The transition to `dead` appends exactly one `session.dead` event in that same update. A later call that sees an already-dead state appends no second dead event. `logs --follow` reads state before draining complete event lines, so it drains `session.dead` before exiting after the session dies.

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

A steer racing the end of a turn starts the next turn: the finished turn's `steer.unconsumed` line comes first, then the queued steer opens a new turn that carries it as its `user` line.
