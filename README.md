# switchyard

Skills, helper scripts and the `delegate` CLI for coding agents (Claude Code, pi): planning a ticket, landing it through delegated lanes, reviewing and repairing PRs, triaging CI, and running a flywheel of tickets with the owner away.

Started from [mattpocock/skills](https://github.com/mattpocock/skills) and reworked since.

## Layout

| Path | What it holds |
| --- | --- |
| `skills/` | One folder per skill: `SKILL.md`, plus brief templates in `briefs/` where the skill starts other jobs. |
| `delegate/` | The `delegate` CLI (Rust): runs a brief on another model and reports a job record. |
| `bin/` | Scripts the skills call: `fill-brief`, `plan-gate` (a plan's gate command, from its `## Gate` heading), `review-pr`, `gh-ci`, `pr-closes`, `ship-pr`, `check-pack`, `agent-cost` (token and cache cost of recent agents, by kind), `ci-health` (hourly fiber CI health check), `ci-friction` (same test failing across CI lanes), `inbox-send` (deliver a stdin message to a file inbox, atomically, or over ssh when `INBOX_HOST` is set), `inbox-wait` (block until an inbox file waits and print its path), `inbox-drain` (print every unread inbox message and move each to `read/`), `post-ruling` (post a ruling comment, copy it to the run dir, fix the label and drop an inbox line in one call). |
| `claude-code/agents/` | Claude Code agent definitions: `ticket-orchestrator` (a flywheel lane, run as its own `claude --bg` session) and `claude-worker` (a Claude lane, Verifier or fix job). |
| `test/` | Tests for the scripts. `test/run` runs every suite. |
| `docs/agents/` | This repo's own setup for the skills: issue tracker, triage labels, workflow doc. |

## Install

Clone to `~/.agents` and link the skills into your agent's skills folder, for example:

```bash
git clone https://github.com/aakshintala/switchyard ~/.agents
for s in ~/.agents/skills/*/; do ln -s "$s" ~/.claude/skills/; done
for a in ~/.agents/claude-code/agents/*.md; do ln -s "$a" ~/.claude/agents/; done   # Claude Code only
```

The skills call scripts at `~/.agents/bin/`.

## delegate

Delegated work runs through the `delegate` CLI in `delegate/`, a Rust binary that runs tasks on Cursor, pi and Claude Code models. Install it with `~/.agents/delegate/bin/setup.sh`; see [delegate/README.md](delegate/README.md). It moved here from `aakshintala/delegate`, which is archived and keeps the old issue and PR history.

## Working on it

Branch, open a PR, squash merge. CI (`ci`) runs `test/run` and delegate's format, lint and tests, and must pass on a head up to date with `main`.

- **Gate:** `bash test/run && bash bin/check-pack` (through `bash`: a fresh worktree's first direct exec of a script can stall for minutes on macOS), plus `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` in `delegate/` when it changes. `test/run` takes 2–3 minutes: run it in the foreground with a 600 s timeout, never in a background shell that a 120 s tool cap ends.
- **Merge:** squash, once a reviewer from a family other than the author's has approved the head's patch-id, CI is green and `pr-closes` prints OK. Use `bin/ship-pr`. When the PR changes `bin/ship-pr` or `bin/gh-ci`, run the reviewed copies from the PR's worktree (`bash <worktree>/bin/ship-pr ...`): `~/.agents` is fast-forwarded only after the merge. Several skills are adapted from other MIT-licensed projects; each says so in a comment at the top and carries its upstream licence beside it.

## Licence

MIT. See [LICENSE](LICENSE).
