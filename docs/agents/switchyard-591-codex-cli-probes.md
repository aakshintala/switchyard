# Codex CLI probes for switchyard #591 (codex backend)

Sandbox probes against the real installed Codex CLI, run 2026-10-19T18:08–18:10Z
from `/tmp/codex-probe` (untrusted dir) and the `delegate-codex-backend`
worktree (trusted git repo). CLI: `codex-cli 0.160.0`, logged in via ChatGPT.
Every shell command ran under `timeout 60`. No MCP servers configured, default
`~/.codex` auth; no `--approve-for-me`, no `--dangerously-bypass-*` flags used.
Five tiny retail turns total (one-line replies); each trivial turn costs about
$0.001 at the `codex/gpt-6-luna` catalogue price (input dominates: ~20k system
tokens, ~8 output tokens).

## Free probes (no model cost)

- `codex --version` → `codex-cli 0.160.0`, exit 0.
- `codex login status` → `Logged in using ChatGPT`, exit 0.
- `codex exec --help`: prompt via argument or `-` (stdin); `-s` sandbox
  (`read-only`, `workspace-write`, `danger-full-access`); `-C/--cd` working
  root; `-m` model; `-c` config override (TOML value); `--json` JSONL events;
  `-i/--image` attaches images (flag present, not probed live: no image case).
- `codex exec resume --help`: `resume [SESSION_ID] [PROMPT]`, `-` reads the
  prompt from stdin; inherits `-m`, `--json`; `-s`/`-C`/`-c` precede `resume`
  as exec-level flags. This matches the backend's wire form
  `exec -s workspace-write -C <cwd> resume <tid> --json -m <m> [-c ...] -- -`.

## Live `exec` probes (tiny retail turns)

Trivial prompt, stdin `-`: `Reply with exactly this one line and nothing else: probe-ok N`.

1. `-c model_reasoning_effort=minimal` → deterministic validation failure
   (reproduced first try; retrying a deterministic 400 is pointless, so no
   retries were spent). Stream: `thread.started` (real UUID thread id),
   `turn.started`, then `error` + `turn.failed` whose message is a
   JSON-encoded error object (`invalid_request_error`, `param:
   reasoning.effort`, `status: 400`), exit code **0**. Lesson: the `minimal`
   level from the pre-probe mapping does not exist; supported values are
   `none`, `low`, `medium`, `high`, `xhigh`, `max`. Unsuffixed catalogue rows
   therefore send **no** `-c` flag (CLI default), `:medium`/`:xhigh` send the
   matching level. The JSON-wrapped `status` is intentionally *not* parsed as
   `provider_status`: only the two Codex-rendered shapes (`unexpected status
   {NNN}`, `last status: {NNN}`) count.
2. `-c model_reasoning_effort=none` → success: `thread.started`,
   `turn.started`, `item.completed` (`agent_message`, exact reply text),
   `turn.completed` with
   `input_tokens: 20563, cached_input_tokens: 0, output_tokens: 8`.
   Empty stderr, exit 0. This is the exact four-event shape the parser
   normalizes.
3. `-c model_reasoning_effort=medium` → success, usage
   `input_tokens: 20563, cached_input_tokens: 12544, output_tokens: 8`.
   Repeat prompts hit the cache (cached 0 → 12544 → 8064 across runs).
4. No `-c` flag (what unsuffixed rows send) → success, usage
   `input_tokens: 20563, cached_input_tokens: 8064, output_tokens: 8`.
5. Untrusted dir without `--skip-git-repo-check` → stderr `Not inside a
   trusted directory and --skip-git-repo-check was not specified.`, empty
   stdout, exit 0. The backend maps this to ERROR via the no-result
   diagnostic with the stderr preserved — verified end to end below.

Trimming behavior: piped stdout is pure JSONL (no ANSI); stderr is empty on
success. Item types other than `agent_message` (commands, file changes, tool
calls) were not observed live — progress paths for them are covered by
synthetic parser tests only.

## Live `delegate` probes (through the backend)

- `delegate doctor` with the real `codex` on PATH: `ok codex: codex
  codex-cli 0.160.0 (...)`, `ok codex: logged in`, plus one `warn ... not
  checked` per configured `codex/` row; exit 0.
- `delegate run --model codex/gpt-6-luna` from the untrusted probe dir →
  ERROR, `no result line / STATUS: ERROR`, `stderrTail` carrying the trust
  refusal, usage null, cost null/estimated. The trust failure is diagnosable
  from the record alone.
- Same run from the trusted worktree → DONE, text `delegate-probe-ok`,
  `sessionId` = live thread UUID, usage `inputTokens 8146 / cacheReadTokens
  12544 / outputTokens 8`, `costUsd 0.00094404` estimated, clean `changeSet`.
  Record: job `06a74ba4-6c96-4c86-8dab-c1cbafeb0c71`.

## Raw transcripts

Kept in the shell history above; representative four-event stream:

```json
{"type":"thread.started","thread_id":"01a1555a-8f35-78b3-b379-ed070ffac6e3"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"probe-ok 20"}}
{"type":"turn.completed","usage":{"input_tokens":20563,"cached_input_tokens":8064,"cache_write_input_tokens":0,"output_tokens":8,"reasoning_output_tokens":0}}
```

## Open question (not implemented)

If a real transient 5xx arrives JSON-wrapped like the observed 400 (no
`unexpected status` prefix), the parser records no `provider_status` and the
supervisor will not retry it. Only the two Codex-rendered shapes retry today,
per the approved spec; revisit if a wrapped 5xx is ever observed.

## Live resume through `delegate` (2026-10-19T18:11Z, `codex_live.rs`)

Both opt-in tests pass against the real CLI (4 turns, ~23s, ~$0.004):
NEEDS_CONTEXT first turn then `delegate resume` continues the same thread
(record `resume.sessionId` unchanged, second-turn text uses the first turn's
fact), and a failed `--gate` run repairs on resume (gate passes, file
created, same thread). The child argv is
`exec -s workspace-write -C <work> resume <thread-id> --json -m gpt-6-luna -- -`
with the continuation prompt on stdin.

Harness note: the temp workspace must be a git repo (`git init`), otherwise
every turn fails with the trust refusal above. No `CODEX_HOME` override or
auth copying is needed; login comes from the owner's `~/.codex`.

## Sandbox scope probes for #591 (2026-10-19, `CODEX_BIN` unset)

Question: do `cargo`/`gh` need `--add-dir` or network access under
`-s workspace-write`, and can permission denials or approvals hang
`codex exec`? Throwaway git repo: `/tmp` copy of this worktree minus
`target`/`.git`, `git init`, no commit. Every run is the backend wire form
`codex exec --json -s workspace-write -C <work> -m gpt-6-luna -- -` with the
prompt on stdin, each under `timeout 300`. All three runs exited 0 well
inside the timeout: denials never hang a non-interactive `exec`.

Probe (a) `cargo`/`gh` under `workspace-write`, two runs:

- Run 1 (thread `01a1558a-c6de-78d1-a29c-3676c904c40c`, usage
  `in 86900 / cached 72576 / out 331`, codex exit 0):
  `cargo --version` → exit 0, tail `cargo 1.98.1 (797e8a9bc 2026-08-05)`.
  `cargo metadata --offline --format-version 1` from the work root → exit
  101, tail `error: could not find Cargo.toml in .../work or any parent
  directory` (prompt bug: the manifest lives at `delegate/Cargo.toml`, not
  the work root — not a sandbox signal). `gh api user --jq .login` →
  exit 1, tail `error connecting to api.github.com / check your internet
  connection or https://githubstatus.com`.
- Run 2, corrected manifest (thread `01a1558b-0c17-7952-b620-11daec098197`,
  usage `in 63126 / cached 41088 / out 865`, codex exit 0):
  `cargo metadata --offline --manifest-path delegate/Cargo.toml
  --format-version 1` → exit 101, 0 stdout bytes, stderr tail `error:
  process didn't exit successfully: sccache .../bin/rustc -vV (exit status:
  2) / sccache: error: Operation not permitted (os error 1)`. The sandbox
  denies the machine-local `~/.cargo/config.toml` `rustc-wrapper = sccache`
  spawn. Control: the same command run unsandboxed on this machine exits 0
  (75650-byte JSON), so the manifest/lock are fine offline — the failure is
  the env-specific wrapper hitting sandbox EPERM, not a missing writable
dir or network (the `--offline` flag needs none).

Probe (b) write outside the workspace (thread
`01a1558b-8748-75c3-91d1-446453dee496`, usage `in 62666 / cached 53760 /
out 288`, codex exit 0): asked to write one line to
`$HOME/codex-denial-probe.txt`. Shell `printf` denied verbatim
(`zsh:1: operation not permitted: ...`), Python-writer retry denied
verbatim (`PermissionError: [Errno 1] Operation not permitted: ...`). No
approval prompt appeared, `exec` returned promptly with `STATUS: DONE`, and
no file was created (verified absent afterwards).

Decision: no `--add-dir`, no network widening, no code change. `cargo
--version` works as-is; the `cargo metadata` failure is fixed by nothing the
backend can pass (`--add-dir` grants writable dirs, not spawn permission,
and the command is offline), so machine-local wrapper setups stay the
owner's concern. `gh api` needs internet, which `workspace-write` blocks by
design — network-dependent commands are unsupported under this sandbox, and
widening it is out of scope. Outside-workspace writes fail closed with EPERM
and never hang.

## Follow-up probes (2026-10-19, repair round 2)

Same wire form (`codex exec --json -s workspace-write -C <work>
-m gpt-6-luna -- -`, prompt on stdin, each under `timeout 300`) against a
fresh throwaway copy (`/tmp/codex-probe-fix3`: this worktree minus
`target`/`.git`, `git init`, no commit).

Probe (a) cargo with sccache disabled (thread
`01a1559b-2df0-7172-987d-4f93c8872909`, usage `in 70266 / cached 57856 /
out 393`, codex turn `turn.completed`, empty codex stderr): the codex
process ran with `RUSTC_WRAPPER=` (empty) in its environment, then the job
ran `cargo metadata --offline --manifest-path delegate/Cargo.toml
--format-version 1` → exit 0, 75540 stdout bytes, empty stderr (the
`command_execution` item independently records `exit_code: 0`). Emptying
`RUSTC_WRAPPER` neutralizes the machine-local `~/.cargo/config.toml`
`rustc-wrapper = sccache` line (an empty wrapper means no wrapper), so the
sandbox EPERM from run 2 above disappears with no backend flag involved.

Probe (b) one `gh` operation the lanes actually need (thread
`01a1559b-72b8-7fb3-96af-b068446b2bdd`, usage `in 43040 / cached 33792 /
out 156`, codex exit 0, empty codex stderr): the job ran `gh pr view 594
--repo aakshintala/switchyard --json state` → exit 1, stderr tail `error
connecting to api.github.com / check your internet connection or
https://githubstatus.com`. Same network block as the earlier `gh api`
probe, now against a lane-real operation.

Decision: no sandbox widening, no code change. Codex jobs run cargo with
sccache disabled: a codex job's gate needs `RUSTC_WRAPPER=` (empty) in the
job environment, and the backend deliberately does not set that variable
itself — machine-local wrapper setups stay the owner's concern, and
baking an env override into the backend would mask owner config rather
than fix sandbox scope. `gh`-dependent steps run outside codex jobs: the
orchestrator runs ship-pr and `gh`, never the job.

## Round 4: cargo with RUSTC_WRAPPER= (2026-10-19)

Same wire form (`codex exec --json -s workspace-write -C /tmp/codex-probe-r4
-m gpt-6-luna -- -`, prompt on stdin, under `timeout 300`) against a fresh
throwaway git repo (`/tmp/codex-probe-r4`: `cargo new --lib probe_crate`,
nested `probe_crate/.git` removed, committed as `99f8e5a init`). The codex
process was launched with `RUSTC_WRAPPER=` (empty) in its environment
(`timeout 300 env RUSTC_WRAPPER= codex exec ...`). The prompt asked the job
to run `cargo metadata --offline --manifest-path probe_crate/Cargo.toml
--format-version 1 >/dev/null; echo META=$?` then `cargo check
--manifest-path probe_crate/Cargo.toml --offline; echo CHECK=$?`.

Probe (thread `01a155a8-d45c-72b1-9947-c04a312f4294`, usage `in 43132 /
cached 33792 / out 143`, codex exit 0, empty codex stderr): the job ran both
cargo commands in one shell. Verbatim `command_execution` item:

- command: `/bin/zsh -lc 'cargo metadata --offline --manifest-path probe_crate/Cargo.toml --format-version 1 >/dev/null; echo META=$?\ncargo check --manifest-path probe_crate/Cargo.toml --offline; echo CHECK=$?'`
- `exit_code: 0`, `status: completed`
- `aggregated_output` verbatim:

```
META=0
    Checking probe_crate v0.1.0 (/private/tmp/codex-probe-r4/probe_crate)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.20s
CHECK=0
```

Final agent message verbatim: `META=0` / `CHECK=0`. Codex stderr verbatim:
empty (0 bytes).

META=0 and CHECK=0: the empty `RUSTC_WRAPPER=` neutralizes the
machine-local sccache wrapper under `workspace-write`, so cargo works with
no `--add-dir` and no network widening.

Decision made (switchyard ruling): workspace-write, no network, RUSTC_WRAPPER= for codex children; gh and network steps run outside codex jobs.
