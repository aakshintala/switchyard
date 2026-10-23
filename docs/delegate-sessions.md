# Delegate session contracts

This page records the ordering and cardinality guarantees that session tests rely on.

## Event and state ordering

`Store::update` writes the new state before it appends the update's event lines. The transition to `dead` appends exactly one `session.dead` event in that same update. A later call that sees an already-dead state appends no second dead event. `logs --follow` reads state before draining complete event lines, so it drains `session.dead` before exiting after the session dies.

`list` includes each valid session directory, marks a directory with unreadable state as `unreadable`, and sorts readable sessions by `startedAt`, then by session id. Human-readable entries use `<id> <status> <model> turns=<n> <cwd>`.

When `send` reaches an idle session, the host reply is `started`. When it reaches a running session, the host reply is `steered`; that means the host accepted the message for its next model continuation.

## Inbox notes

A matching turn completion changes the session from `running` to `idle` and triggers one `[session <id> idle]` inbox note. The transition to `dead` triggers one `[session <id> dead]` note. If a verb finds a dead supervisor, a `dead.noted` marker lets only the first settling verb write the fallback note. Inbox writes are best-effort and do not change the verb's exit code.
