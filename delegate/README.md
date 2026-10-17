# delegate

A small CLI that runs coding and research tasks on Cursor, pi, Claude Code, or Fiber models by driving the local `cursor-agent` binary in headless mode. Jobs are detached supervisors; you poll status from JSON files on disk.

## Install

delegate ships inside [switchyard](https://github.com/aakshintala/switchyard). With switchyard cloned at `~/.agents`:

```bash
~/.agents/delegate/bin/setup.sh
```

This builds `delegate`, copies it to `~/.local/bin/delegate`, optionally migrates an old host profile, and links the skill for Claude Code. pi loads it from `~/.agents/skills` without a link.

You need Rust (`cargo`), and `cursor-agent` on PATH with `cursor-agent login` before running jobs.

## Commands

| Command | Purpose |
| --- | --- |
| `delegate run` | Start a job (prompt on stdin or `--prompt-file`); prints the job id. |
| `delegate resume <jobId>` | Continue a finished job that has a session id; optional model/gate overrides. |
| `delegate cancel <jobId>` | Stop a running job and print its terminal record. |
| `delegate watch <jobId>...` | Block until each job is terminal (optional `--timeout` seconds). |
| `delegate models` | List configured model ids, labels, backends, prices, and tiers. |
| `delegate doctor` | Check the binary, `cursor-agent`, login, and model menu drift. |

Every job runs with writes enabled. A read task says "do not edit" in its brief; the record's `changeSet` shows any write. Parallel jobs need separate cwds (one worktree per lane).

## Backends

| Backend | Status |
| --- | --- |
| `cursor` | Implemented (`cursor-agent`, `CURSOR_AGENT_BIN`). |
| `pi` | Implemented (`pi`, `PI_BIN`). |
| `claude` | Implemented (`claude`, `CLAUDE_BIN`). |
| `fiber` | Implemented (`fiber ask`, `FIBER_BIN`). |

Model ids and prices come from bundled `config/models.json`, merged with your host profile.
A Claude model id may carry a trailing `:<level>` (`low|medium|high|xhigh|max`), run as `claude --model <base> --effort <level>` (e.g. `claude-opus-5-5:high`); ids without a suffix are unchanged, and pi ids with a thinking suffix such as `openai/gpt-6-luna:xhigh` stay their own ids.

A fiber model id is `fiber/` plus Fiber's own `provider/model` reference (e.g. `fiber/opencode-go/muse-spark-1.3-contributor`), run as `fiber ask --model <reference>` with resume via `--resume`; it carries no tiers so the ladder never picks it, and `delegate doctor` checks `fiber version` plus membership in `fiber models --json`. The real-fiber resume tests run with `FIBER_BIN=<path to fiber> cargo test --test fiber_live` from `delegate/`; each test spends two live Muse turns, and both skip when `FIBER_BIN` is unset.

## Status records

Each job writes `$TMPDIR/delegate-jobs/<jobId>.json` (use `$TMPDIR` when set, otherwise the OS temp directory). Prompt text is stored alongside as `<jobId>.prompt` until the supervisor starts. A gate writes its full ANSI-stripped output to `<jobId>-gate.log` beside the record; later gate runs for the same job use numbered names. `result.gateResult.outputPath` names the file, and `outputTail` remains the last 2048 bytes. When the supervisor resumed a session past a transient provider error (a 5xx, or a first 401), `result.retries` lists each failed attempt; it is absent when there were none.

## Host profile

Optional JSON at `~/.config/delegate/host-profile.json` (or `$XDG_CONFIG_HOME/delegate/host-profile.json`). Override the path with `DELEGATE_HOST_PROFILE`. Keys can set `default`, `models`, `gate`, `idleMs`, and `toolIdleMs`. Missing file is fine; defaults are built in.

## Replay

`scripts/replay.sh` reruns finished pi jobs on the Fiber backend and compares.
`select` freezes a manifest of eligible jobs (with prompt, gate and brief
snapshots); `run` replays each in a scratch clone at its base commit under
`sandbox-exec`, driving `delegate run --model fiber/<model>`; `report` writes
the Markdown comparison with the pass bar; `all` advances one batch of three.

Inputs: `REPLAY_JOBS_DIR` (default `$TMPDIR/delegate-jobs`),
`REPLAY_PI_SESSIONS` (default `~/.pi/agent/sessions`), `REPLAY_REPO_MAP`
(prefix TAB owner/name), `REPLAY_REMOTE_BASE`, `REPLAY_FIBER_SRC` (a dedicated
fiber clone, never `~/work/fiber`), `DELEGATE_BIN`, `REPLAY_SANDBOX_EXEC`
(fake `sandbox-exec` for tests). The seal denies writes under `$HOME` and the
real jobs dir, voids `GH_TOKEN`, and puts logging shims first on `PATH`:
`gh` logs and exits 1, `curl` and `wget` log then exec the real binary,
and `git` logs outward subcommands (`push`, `remote`, `send-email`,
`request-pull`) then execs the real git. Each shim appends one line to
`runs/<id>/outward.log`, which `report` surfaces as `note: outward:` lines;
`FIBER_HOME` and the cargo target stay under the out dir.
The replay `TMPDIR` is a unique `mktemp -d /tmp/frp-XXXXXX` dir per prep (path recorded in `runs/<id>/tmpdir`): Fiber and its tests put unix sockets under `TMPDIR`, and a path under the out dir leaves no room under the 103-byte socket limit.

## Canary

`scripts/canary.sh` runs one ticket's brief on pi and on Fiber side by side:
`run <ticket> <brief file> --gate '<gate>' [--pi-model M] [--fiber-model M] [--repo owner/name] [--clone <path>] [--out DIR]`
cuts two worktrees from the same freshly fetched `origin/main` (branches
`canary/<ticket>-pi` and `canary/<ticket>-fiber`), runs the brief through
`delegate run` on each side one after the other (pi's run and watch, then Fiber's), `--pi-model` and `--fiber-model` choosing the models (default: the muse-spark pair),
and runs the gate in each worktree once both jobs end. Each side's wall time covers only its own run. The brief is wrapped
with a line telling each agent to commit locally and never push or open a PR.
Output goes to `~/.cache/agents/canary/<ticket>/` (or `--out`): a `pi/` and a
`fiber/` directory, each holding `worktree`, `prompt.md`, `diff.patch`,
`gate.log`, `gate.exit` and `metrics.json`, plus a top-level `summary.md`
with the two-column comparison table and a `clone` file naming the clone,
written before any git change. The worktrees sit next to the clone as
`<clone name>-canary-<ticket>-pi` and `-fiber`. Exit codes: 0 means both runs
finished (whatever their gates did), 1 means a run errored in the harness, 2
means a usage or setup error; a setup failure cleans up as `clean` does.
`clean <ticket> [--out DIR]` works from the ticket and the `clone` file alone:
it removes whichever of the two worktrees and branches exist (metrics stay) so
the ticket can run again. It refuses a worktree with uncommitted changes
(exit 1), and running it twice is safe.
`report <ticket> [--out DIR]` rebuilds a finished run's `metrics.json` and
`summary.md` from its saved outputs, the job record and the Fiber event log,
without rerunning anything. Fiber's main and reviewer tokens and costs come
from the `usage_recorded` events (a record with an `action_id` is main, one
without is the reviewer); a null main cost is total minus reviewer.

## Skill

The skill lives in switchyard's `skills/delegate/`. Setup links `~/.claude/skills/delegate` to it, and pi reads `~/.agents/skills` directly, so both load it from the checkout and an edit is live without a reinstall.
