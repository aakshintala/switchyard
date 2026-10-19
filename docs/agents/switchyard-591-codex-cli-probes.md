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
