#!/usr/bin/env bash
# Tests for bin/agent-cost, against a fixture transcript tree (never ~/.claude).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/agent-cost"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-agent-cost.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/p1/s1/subagents"
SUB="$T/p1/s1/subagents/agent-a.jsonl"
printf '{"agentType":"claude-worker"}\n' >"$T/p1/s1/subagents/agent-a.meta.json"

# Subagent. Message m1 is streamed twice: the first chunk is a stub, the last wins.
#   m1 (final): input 1000, cache write 400000 (1h 100000 -> w5 300000, w1 100000), read 2000000, out 100000
#   m2 (+10min): cache write 600000 (1h 200000 -> w5 400000, w1 200000): a bigwrite;
#                carries a poll (delegate watch) tool_use, streamed twice (one poll)
#   two messages without an id (+11, +12 min): read 500000, out 10000 each: two turns, not one
#   one tool_result over 20000 chars: bigres; one malformed line: skipped
# Totals: inp 1000, w5 700000, w1 300000, cr 4000000, out 170000, turns 4
#   cost = 1000 + 1.25*700000 + 2*300000 + 0.1*4000000 + 5*170000 = 2726000 -> 2.7M, per 2.73M
cat >"$SUB" <<'FIXTURE'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m1","usage":{"input_tokens":1000,"cache_creation_input_tokens":400000,"cache_creation":{"ephemeral_1h_input_tokens":100000},"cache_read_input_tokens":2000000,"output_tokens":100000}}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"BIGRESULT"}]}}
this line is not json {"type":
{"type":"assistant","timestamp":"2026-01-01T00:10:00Z","message":{"id":"m2","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"delegate watch x"}}],"usage":{"cache_creation_input_tokens":600000,"cache_creation":{"ephemeral_1h_input_tokens":200000},"cache_read_input_tokens":1000000,"output_tokens":50000}}}
{"type":"assistant","timestamp":"2026-01-01T00:10:00Z","message":{"id":"m2","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"delegate watch x"}}],"usage":{"cache_creation_input_tokens":600000,"cache_creation":{"ephemeral_1h_input_tokens":200000},"cache_read_input_tokens":1000000,"output_tokens":50000}}}
{"type":"assistant","timestamp":"2026-01-01T00:11:00Z","message":{"usage":{"cache_read_input_tokens":500000,"output_tokens":10000}}}
{"type":"assistant","timestamp":"2026-01-01T00:12:00Z","message":{"usage":{"cache_read_input_tokens":500000,"output_tokens":10000}}}
FIXTURE
python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read().replace("BIGRESULT","x"*25000); open(p,"w").write(s)' "$SUB"

# bg ticket-orchestrator: input 1000000, cache write 800000 (all 5m), out 100000
#   cost = 1000000 + 1.25*800000 + 5*100000 = 2500000 -> 2.5M
cat >"$T/p1/bg.jsonl" <<'FIXTURE'
{"type":"system","agentSetting":"ticket-orchestrator"}
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"b1","usage":{"input_tokens":1000000,"cache_creation_input_tokens":800000,"output_tokens":100000}}}
FIXTURE

# main interactive session: no agentSetting, excluded
cat >"$T/p1/main.jsonl" <<'FIXTURE'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"x1","usage":{"input_tokens":9000000}}}
FIXTURE

# old bg session (mtime 10 days back): input 4000000 -> cost 4.0M; only with days=30
cat >"$T/p1/old.jsonl" <<'FIXTURE'
{"type":"system","agentSetting":"claude-worker"}
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"o1","usage":{"input_tokens":4000000}}}
FIXTURE
python3 -I -c 'import os,sys,time; t=time.time()-10*86400; os.utime(sys.argv[1],(t,t))' "$T/p1/old.jsonl"

SUBLINE='sub:claude-worker        n=  1 cost=    2.7M  per= 2.73M turns/agent=    4 cw5=0.7M cw1=0.3M cr=4M out=0.17M bigwrites=1 (0.6M) polls=1 bigres=1'
BGLINE='bg:ticket-orchestrator   n=  1 cost=    2.5M  per= 2.50M turns/agent=    1 cw5=0.8M cw1=0.0M cr=0M out=0.10M bigwrites=0 (0.0M) polls=0 bigres=0'
OLDLINE='bg:claude-worker         n=  1 cost=    4.0M  per= 4.00M turns/agent=    1 cw5=0.0M cw1=0.0M cr=0M out=0.00M bigwrites=0 (0.0M) polls=0 bigres=0'

OUT="$(AGENT_COST_ROOT="$T" python3 -I "$BIN")" || fail "default run exited non-zero"
EXPECT="$SUBLINE
$BGLINE"
[ "$OUT" = "$EXPECT" ] || fail "default output differs:
$OUT
--- expected
$EXPECT"

OUT="$(AGENT_COST_ROOT="$T" python3 -I "$BIN" 30)" || fail "30-day run exited non-zero"
EXPECT="$OLDLINE
$SUBLINE
$BGLINE"
[ "$OUT" = "$EXPECT" ] || fail "30-day output differs:
$OUT
--- expected
$EXPECT"

OUT="$(AGENT_COST_ROOT="$T" python3 -I "$BIN" 0.5)" || fail "fractional run exited non-zero"
[ "$OUT" = "$SUBLINE
$BGLINE" ] || fail "fractional days output differs"

# missing root: nothing, exit 0
OUT="$(AGENT_COST_ROOT="$T/nope" python3 -I "$BIN")" || fail "missing root exited non-zero"
[ -z "$OUT" ] || fail "missing root printed output"

# bad usage: exit 2, usage on stderr
check_bad() {
  local err rc
  err="$(AGENT_COST_ROOT="$T" python3 -I "$BIN" "$@" 2>&1 >/dev/null)"
  rc=$?
  [ "$rc" = "2" ] || fail "args '$*': exit $rc, want 2"
  case "$err" in *sage*) ;; *) fail "args '$*': no usage line on stderr" ;; esac
}
check_bad abc
check_bad 0
check_bad -1
check_bad 1 2
check_bad -h

# USD mode reads record timestamps from all sources and never the user's real roots.
USD_CLAUDE="$T/usd-claude"
USD_PI="$T/usd-pi"
USD_CODEX="$T/usd-codex"
USD_LEDGER="$T/usd-delegate-cost.jsonl"
mkdir -p "$USD_CLAUDE/encoded-project" "$USD_CLAUDE/opus5" "$USD_CLAUDE/opus48" "$USD_PI/workspace" "$USD_PI/muse" "$USD_CODEX/2026/11/06"
cat >"$USD_CLAUDE/encoded-project/main.jsonl" <<'FIXTURE'
{"type":"assistant","timestamp":"2026-11-05T08:00:00Z","message":{"id":"dup-1","model":"claude-sonnet-5","usage":{"input_tokens":500,"output_tokens":10}}}
{"type":"assistant","timestamp":"2026-11-05T08:00:01Z","message":{"id":"dup-1","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":400,"cache_creation":{"ephemeral_1h_input_tokens":100}}}}
{"type":"assistant","timestamp":"2026-11-06T08:00:00Z","message":{"id":"unknown-1","model":"experimental-model","usage":{"input_tokens":50,"output_tokens":2}}}
{"type":"assistant","timestamp":"2026-10-31T23:59:59Z","message":{"id":"old-1","model":"claude-sonnet-5","usage":{"input_tokens":2000000,"output_tokens":0}}}
FIXTURE
cat >"$USD_CLAUDE/opus5/session.jsonl" <<'FIXTURE'
{"type":"assistant","timestamp":"2026-11-05T09:00:00Z","message":{"id":"opus-5","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
FIXTURE
cat >"$USD_CLAUDE/opus48/session.jsonl" <<'FIXTURE'
{"type":"assistant","timestamp":"2026-11-05T09:00:00Z","message":{"id":"opus-48","model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":4,"cache_creation_input_tokens":1}}}
FIXTURE
cat >"$USD_PI/workspace/session.jsonl" <<'FIXTURE'
{"type":"session","cwd":"/work/pi-app"}
{"type":"message","timestamp":"2026-11-05T09:00:00Z","message":{"role":"assistant","model":"claude-haiku-4-5","usage":{"input":100,"output":20,"cacheRead":50,"cacheWrite":10,"cost":{"total":99}}}}
{"type":"message","timestamp":"2026-10-30T09:00:00Z","message":{"role":"assistant","model":"claude-haiku-4-5","usage":{"input":1000000,"output":0,"cacheRead":0,"cacheWrite":0}}}
FIXTURE
# A bare Muse id has no exact models.json key; it prices through its prefixed keys.
cat >"$USD_PI/muse/session.jsonl" <<'FIXTURE'
{"type":"session","cwd":"/work/muse-app"}
{"type":"message","timestamp":"2026-11-05T10:00:00Z","message":{"role":"assistant","model":"muse-spark-1.3-contributor","usage":{"input":1000,"output":100,"cacheRead":500,"cacheWrite":0}}}
FIXTURE
python3 -I - "$USD_CODEX/2026/11/06/rollout.jsonl" "$USD_LEDGER" <<'PY'
import json
import sys
from datetime import datetime, timezone

codex_path, ledger_path = sys.argv[1:]
codex = [
    {"timestamp": "2026-11-06T10:00:00Z", "type": "session_meta", "payload": {"cwd": "/work/codex-app", "model_provider": "openai"}},
    {"timestamp": "2026-11-06T10:01:00Z", "type": "turn_context", "payload": {"model": "gpt-6-luna"}},
    {"timestamp": "2026-11-06T10:02:00Z", "type": "event_msg", "payload": {"type": "token_count", "info": {"last_token_usage": {"input_tokens": 1000, "cached_input_tokens": 400, "cache_write_input_tokens": 20, "output_tokens": 10}}}},
    {"timestamp": "2026-10-30T10:02:00Z", "type": "event_msg", "payload": {"type": "token_count", "info": {"last_token_usage": {"input_tokens": 10000000, "cached_input_tokens": 0, "output_tokens": 0}}}},
]
with open(codex_path, "w") as f:
    for record in codex:
        f.write(json.dumps(record) + "\n")
finished_at = datetime(2026, 11, 6, 12, tzinfo=timezone.utc).timestamp() * 1000
ledger = {
    "jobId": "job-codex-1", "finishedAtMs": finished_at,
    "model": "codex/gpt-6-luna", "status": "DONE", "cwd": "/work/codex-app",
    "costUsd": 0.0000715,
    "usage": {"inputTokens": 600, "cacheReadTokens": 400, "cacheWriteTokens": 20, "outputTokens": 10},
}
unpriced_ledger = {
    "jobId": "job-unpriced-1", "finishedAtMs": finished_at,
    "model": "experimental-ledger-model", "status": "DONE", "cwd": "/work/codex-app",
    "usage": {"inputTokens": 3, "cacheReadTokens": 4, "cacheWriteTokens": 5, "outputTokens": 6},
}
with open(ledger_path, "w") as f:
    f.write(json.dumps(ledger) + "\n")
    f.write(json.dumps(unpriced_ledger) + "\n")
PY
python3 -I - "$USD_PI/workspace/session.jsonl" <<'PY'
import os
import sys
import time
path = sys.argv[1]
old = time.time() - 30 * 86400
os.utime(path, (old, old))
PY
OUT="$(AGENT_COST_ROOT="$USD_CLAUDE" AGENT_COST_PI_ROOT="$USD_PI" AGENT_COST_CODEX_ROOT="$USD_CODEX" DELEGATE_COST_LEDGER="$USD_LEDGER" python3 -I "$BIN" --usd --since 2026-11-01)" || fail "USD report exited non-zero"
contains() { grep -Fqx "$1" <<<"$OUT" || fail "USD report lacks [$1]:\n$OUT"; }
contains '  model=claude-opus-5 usd=0.000081500 input=1 cacheRead=3 cacheWrite=4 output=2'
contains '  model=claude-opus-4-8 usd=0.000043250 input=2 cacheRead=4 cacheWrite=1 output=1'
contains '  model=claude-sonnet-5 usd=0.004190000 input=1000 cacheRead=200 cacheWrite=400 output=100'
contains '  model=claude-haiku-4-5 usd=0.000217500 input=100 cacheRead=50 cacheWrite=10 output=20'
contains '  model=codex/gpt-6-luna usd=0.000071500 input=600 cacheRead=400 cacheWrite=20 output=10'
contains '  model=experimental-model unpriced input=50 cacheRead=0 cacheWrite=0 output=2'
contains '  project=encoded-project usd=0.004190000 unpricedRecords=1 unpriced=experimental-model(input=50,cacheRead=0,cacheWrite=0,output=2)'
contains '  project=/work/pi-app usd=0.000217500'
contains '  project=/work/codex-app usd=0.000071500'
contains '  model=muse-spark-1.3-contributor usd=0.000121000 input=1000 cacheRead=500 cacheWrite=0 output=100'
contains '  project=/work/muse-app usd=0.000121000'
contains 'logs total pricedUsd=0.004724750 unpricedRecords=1'
contains '  model=codex/gpt-6-luna usd=0.000071500 input=600 cacheRead=400 cacheWrite=20 output=10'
contains '  model=experimental-ledger-model unpriced input=3 cacheRead=4 cacheWrite=5 output=6'
contains '  project=/work/codex-app usd=0.000071500 unpricedRecords=1 unpriced=experimental-ledger-model(input=3,cacheRead=4,cacheWrite=5,output=6)'
contains 'delegate ledger (separate total; may overlap log rows from the same jobs):'
contains 'delegate ledger total recordedUsd=0.000071500 entries=2 unpricedRecords=1'
case "$OUT" in *2000000*|*10000000*|*1000000*) fail "USD report used records before --since" ;; esac

# Bare-id fallback, against fixture prices: it prices only when every matching key agrees,
# and never changes a match the earlier candidates already make.
python3 -I -B - "$BIN" <<'PY' || fail "bare-id pricing fallback"
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

loader = SourceFileLoader("agent_cost", sys.argv[1])
mod = module_from_spec(spec_from_loader("agent_cost", loader))
loader.exec_module(mod)
cheap = {"input": 1, "output": 2, "cacheRead": 0.1, "cacheWrite": 0}
dear = {"input": 3, "output": 6, "cacheRead": 0.3, "cacheWrite": 0}
models = {
    "muse/muse-spark-1.3-contributor": {"price": cheap},
    "opencode-go/muse-spark-1.3-contributor": {"price": cheap},
    "fiber/codex/gpt-6-luna:xhigh": {"price": cheap},
    "openai/gpt-6-luna:medium": {"price": cheap},
    "opencode-go/glm-5.3-flash": {"price": cheap},
    "zen/glm-5.3-flash:max": {"price": dear},
    "claude-haiku-4-5": {"price": dear},
    "codex/gpt-6-sol": {"price": dear},
}
cases = [
    (("muse-spark-1.3-contributor", "pi", models), ("muse-spark-1.3-contributor", "muse/muse-spark-1.3-contributor")),
    (("gpt-6-luna", "pi", models), ("gpt-6-luna", "fiber/codex/gpt-6-luna:xhigh")),
    (("glm-5.3-flash", "pi", models), ("glm-5.3-flash", None)),
    (("claude-haiku-4-5", "pi", models), ("claude-haiku-4-5", "claude-haiku-4-5")),
    (("gpt-6-sol", "codex", models), ("codex/gpt-6-sol", "codex/gpt-6-sol")),
]
for args, want in cases:
    got = mod.model_and_price(*args)
    if got != want:
        sys.exit(f"model_and_price{args[:2]} = {got}, want {want}")
usage = {"input": 1000, "cacheRead": 0, "cacheWrite": 0, "output": 100}
usd = mod.price_usage("muse/muse-spark-1.3-contributor", usage, models, "pi")
if abs(usd - 0.0012) > 1e-12:
    sys.exit(f"bare muse usd = {usd}, want 0.0012")
PY

# XDG_CACHE_HOME isolates the default delegate ledger location too.
mkdir -p "$T/xdg-cache/agents"
cp "$USD_LEDGER" "$T/xdg-cache/agents/delegate-cost.jsonl"
OUT="$(AGENT_COST_ROOT="$USD_CLAUDE" AGENT_COST_PI_ROOT="$USD_PI" AGENT_COST_CODEX_ROOT="$USD_CODEX" XDG_CACHE_HOME="$T/xdg-cache" DELEGATE_COST_LEDGER= python3 -I "$BIN" --usd --since 2026-11-01)" || fail "USD report with XDG ledger path exited non-zero"
contains 'delegate ledger total recordedUsd=0.000071500 entries=2 unpricedRecords=1'

# A file argument or stdin remain legacy mode unless --usd is selected.
EXPECT="$SUBLINE
$BGLINE"
OUT="$(AGENT_COST_ROOT="$T/p1" python3 -I "$BIN")" || fail "legacy output changed after USD mode"
[ "$OUT" = "$EXPECT" ] || fail "legacy output changed after USD mode"

# bad USD invocations fail clearly.
check_bad --usd
check_bad --since 2026-11-01
check_bad --usd --since not-a-date

echo "agent-cost: ok"
