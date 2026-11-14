#!/usr/bin/env bash
# Tests for bin/lane-model using fixture quota and session probes only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT/bin/lane-model"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-lane-model.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

mkdir -p "$T/bin" "$T/run"
cat >"$T/bin/quota" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 2
if [ "${QUOTA_FAIL:-0}" = 1 ]; then
  echo 'stub quota failed' >&2
  exit 1
fi
cat "$QUOTA_FILE"
EOF
cat >"$T/bin/delegate" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = session ] && [ "${2:-}" = list ] && [ "${3:-}" = --json ] || exit 2
if [ "${DELEGATE_FAIL:-0}" = 1 ]; then
  echo 'stub delegate failed' >&2
  exit 1
fi
cat "$DELEGATE_JSON"
EOF
cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = agents ] && [ "${2:-}" = --json ] || exit 2
if [ "${CLAUDE_FAIL:-0}" = 1 ]; then
  echo 'stub claude failed' >&2
  exit 1
fi
cat "$CLAUDE_JSON"
EOF
cat >"$T/bin/box-ssh" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 4 ] && [ "$1" = -o ] && [ "$2" = BatchMode=yes ] || exit 2
case "$4" in
  'PATH=$HOME/.local/bin:$PATH delegate session list --json')
    if [ "${BOX_DELEGATE_FAIL:-0}" = 1 ]; then
      echo 'stub box delegate failed' >&2
      exit 1
    fi
    cat "$BOX_DELEGATE_JSON"
    ;;
  'PATH=$HOME/.local/bin:$PATH claude agents --json')
    if [ "${BOX_CLAUDE_FAIL:-0}" = 1 ]; then
      echo 'stub box claude failed' >&2
      exit 1
    fi
    cat "$BOX_CLAUDE_JSON"
    ;;
  *) echo "unexpected box command: $4" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/bin/quota" "$T/bin/delegate" "$T/bin/claude" "$T/bin/box-ssh"
export LANE_MODEL_QUOTA="$T/bin/quota"
export LANE_MODEL_DELEGATE="$T/bin/delegate"
export LANE_MODEL_CLAUDE="$T/bin/claude"
export BOX_SSH="$T/bin/box-ssh"
export FW_RUN="$T/run" QUOTA_FILE="$T/quota.json"
export DELEGATE_JSON="$T/delegate.json" CLAUDE_JSON="$T/claude.json"
export BOX_DELEGATE_JSON="$T/box-delegate.json" BOX_CLAUDE_JSON="$T/box-claude.json"
export DELEGATE_FAIL=0 CLAUDE_FAIL=0 QUOTA_FAIL=0
export BOX_DELEGATE_FAIL=0 BOX_CLAUDE_FAIL=0
: >"$T/run/roster"
: >"$T/run/roster-done"
printf '{"ok":true,"sessions":[]}\n' >"$T/delegate.json"
printf '[]\n' >"$T/claude.json"
printf '{"sessions":[]}\n' >"$T/box-delegate.json"
printf '[]\n' >"$T/box-claude.json"

run_pick() {
  if bash "$BIN" "$@" >"$T/out" 2>"$T/err"; then
    RC=0
  else
    RC=$?
  fi
  OUT="$(cat "$T/out")"
  ERR="$(cat "$T/err")"
}

# Highest score wins, with the haiku candidate held back by the >20% floor.
# Muse has the most headroom but muse/* is deliberately not a candidate.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":70}]},
  {"id":"opencode-go","status":"warning","quotas":[{"percentRemaining":80}]},
  {"id":"muse","status":"healthy","quotas":[{"percentRemaining":100}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
run_pick
[ "$RC" -eq 0 ] || fail "highest score exit $RC: $ERR"
[ "$OUT" = 'opencode-go/muse-spark-1.3-contributor muselaunch' ] || fail "highest score chose [$OUT]"
case "$OUT" in muse/*) fail "muse provider yielded a muse model: $OUT";; esac
[ -z "$ERR" ] || fail "normal pick wrote stderr: $ERR"

# Load counts only live delegate sessions represented in the roster. Two
# OpenCode Go sessions divide its score by three; an unrostered session is ignored.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":70}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":90}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
printf '2026-11-13T00:00:00Z\t172\tmuse\tfiber-172-build\topencode-session-1\n2026-11-13T00:00:01Z\t173\tmuse\tfiber-173-build\topencode-session-2\n' >"$T/run/roster"
cat >"$T/delegate.json" <<'JSON'
{"ok":true,"sessions":[
  {"id":"opencode-session-1","status":"running","model":"opencode-go/muse-spark-1.3-contributor"},
  {"id":"opencode-session-2","status":"idle","model":"opencode-go/muse-spark-1.3-contributor"},
  {"id":"unrostered-codex","status":"running","model":"openai/gpt-6-luna:medium"},
  {"id":"dead-opencode","status":"dead","model":"opencode-go/muse-spark-1.3-contributor"}
]}
JSON
run_pick
[ "$RC" -eq 0 ] || fail "load pick exit $RC: $ERR"
[ "$OUT" = 'openai/gpt-6-luna:medium muselaunch' ] || fail "load did not pull OpenCode Go down: [$OUT]"

# Box-only delegate sessions contribute load and can pull that model down.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":60}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":90}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
printf '2026-11-13T00:00:00Z\t176\tmuse\tfiber-176-build\tbox-opencode-1\n' >"$T/run/roster"
printf '{"sessions":[]}\n' >"$T/delegate.json"
printf '{"sessions":[{"id":"box-opencode-1","status":"running","model":"opencode-go/muse-spark-1.3-contributor"}]}\n' >"$T/box-delegate.json"
run_pick
[ "$RC" -eq 0 ] || fail "box-only load exit $RC: $ERR"
[ "$OUT" = 'openai/gpt-6-luna:medium muselaunch' ] || fail "box-only load did not pull model down: [$OUT]"

# Box Claude agents are roster-matched and lower the Haiku score.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":19}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":15}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":20}]}
]}
JSON
printf '2026-11-13T00:00:00Z\t179\tbox\tfiber-179-build\tbox-claude-1\n' >"$T/run/roster"
printf '[]\n' >"$T/claude.json"
printf '{"agents":[{"id":"box-claude-1","name":"fiber-179-build","status":"busy"}]}\n' >"$T/box-claude.json"
run_pick
[ "$RC" -eq 0 ] || fail "box Claude load exit $RC: $ERR"
[ "$OUT" = 'openai/gpt-6-luna:medium muselaunch' ] || fail "box Claude load did not lower Haiku score: [$OUT]"

# A session visible on both hosts is counted once, not twice.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":40}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":90}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
printf '2026-11-13T00:00:00Z\t177\tmuse\tfiber-177-build\tshared-session\n' >"$T/run/roster"
printf '{"sessions":[{"id":"shared-session","status":"running","model":"opencode-go/muse-spark-1.3-contributor"}]}\n' >"$T/delegate.json"
printf '{"sessions":[{"id":"shared-session","status":"running","model":"opencode-go/muse-spark-1.3-contributor"}]}\n' >"$T/box-delegate.json"
run_pick
[ "$RC" -eq 0 ] || fail "deduplicated load exit $RC: $ERR"
[ "$OUT" = 'opencode-go/muse-spark-1.3-contributor muselaunch' ] || fail "duplicate session counted twice: [$OUT]"

# A roster lane retired by a ticket-scoped roster-done entry no longer adds load.
printf '2026-11-13T00:00:00Z\t174\tmuse\tfiber-174-build\topencode-retired-id\n' >"$T/run/roster"
printf '2026-11-13T00:00:01Z\t174\n' >"$T/run/roster-done"
printf '{"sessions":[{"id":"opencode-retired-id","status":"running","model":"opencode-go/muse-spark-1.3-contributor"}]}\n' >"$T/delegate.json"
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":60}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":90}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
run_pick
[ "$RC" -eq 0 ] || fail "retired roster exit $RC: $ERR"
[ "$OUT" = 'opencode-go/muse-spark-1.3-contributor muselaunch' ] || fail "retired session still counted: [$OUT]"

# Critical and depleted providers are skipped even with abundant percentage.
: >"$T/run/roster"
: >"$T/run/roster-done"
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"critical","quotas":[{"percentRemaining":100}]},
  {"id":"opencode-go","status":"depleted","quotas":[{"percentRemaining":95}]},
  {"id":"muse","status":"warning","quotas":[{"percentRemaining":100}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
run_pick
[ "$RC" -eq 0 ] || fail "depleted/critical exit $RC: $ERR"
[ "$OUT" = 'claude-haiku-5-5 boxlaunch' ] || fail "depleted/critical provider was selected: [$OUT]"

# Haiku is excluded when any usable non-Claude provider has more than 20%.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":20}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":21}]},
  {"id":"muse","status":"healthy","quotas":[{"percentRemaining":100}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
run_pick
[ "$RC" -eq 0 ] || fail "haiku-above-floor exit $RC: $ERR"
[ "$OUT" = 'opencode-go/muse-spark-1.3-contributor muselaunch' ] || fail "haiku was not excluded above floor: [$OUT]"

# If no other usable provider exceeds 20%, haiku competes on score and wins
# with the highest one.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":20}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":15}]},
  {"id":"muse","status":"healthy","quotas":[{"percentRemaining":18}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":60}]}
]}
JSON
run_pick
[ "$RC" -eq 0 ] || fail "haiku-under-floor exit $RC: $ERR"
[ "$OUT" = 'claude-haiku-5-5 boxlaunch' ] || fail "haiku was not chosen under floor: [$OUT]"

# Under the floor, haiku still loses to a higher-scoring candidate.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":20}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":15}]},
  {"id":"muse","status":"healthy","quotas":[{"percentRemaining":18}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":10}]}
]}
JSON
run_pick
[ "$RC" -eq 0 ] || fail "haiku-scored-under-floor exit $RC: $ERR"
[ "$OUT" = 'openai/gpt-6-luna:medium muselaunch' ] || fail "haiku won without the best score: [$OUT]"

# Quota providers codex/cursor never become codex/* or cursor models.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":99}]},
  {"id":"cursor","status":"healthy","quotas":[{"percentRemaining":100}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":35}]},
  {"id":"muse","status":"healthy","quotas":[{"percentRemaining":45}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
run_pick
[ "$RC" -eq 0 ] || fail "codex/cursor exclusion exit $RC: $ERR"
[ "$OUT" = 'openai/gpt-6-luna:medium muselaunch' ] || fail "best allowed candidate was not selected: [$OUT]"
case "$OUT" in codex/*|cursor/*) fail "forbidden model emitted: $OUT";; esac

# No usable candidate returns status 2, no stdout, and a clear explanation.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"critical","quotas":[{"percentRemaining":90}]},
  {"id":"opencode-go","status":"healthy","unavailable":"feed unavailable","quotas":[{"percentRemaining":90}]},
  {"id":"muse","status":"depleted","quotas":[{"percentRemaining":90}]}
]}
JSON
run_pick
[ "$RC" -eq 2 ] || fail "no usable candidates exit $RC, want 2"
[ -z "$OUT" ] || fail "no usable candidates printed stdout: [$OUT]"
case "$ERR" in *'lane-model: no usable candidates'*) ;; *) fail "no-usable error unclear: $ERR";; esac

# A failed box delegate probe warns on stderr, keeps the Mac load, and still picks.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":60}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":90}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
printf '2026-11-13T00:00:00Z\t178\tmuse\tfiber-178-build\tmac-opencode-id\n' >"$T/run/roster"
printf '{"sessions":[{"id":"mac-opencode-id","status":"running","model":"opencode-go/muse-spark-1.3-contributor"}]}\n' >"$T/delegate.json"
printf '{"sessions":[]}\n' >"$T/box-delegate.json"
BOX_DELEGATE_FAIL=1 run_pick
[ "$RC" -eq 0 ] || fail "box probe failure exit $RC: $ERR"
[ "$OUT" = 'openai/gpt-6-luna:medium muselaunch' ] || fail "box failure discarded Mac load: [$OUT]"
grep -q 'warning: Box delegate probe failed; using Mac-only load' "$T/err" || fail "box failure warning missing: $ERR"

# --explain keeps stdout to one pick line and prints every candidate's quota,
# load and score to stderr. Failed local probes mean zero local load and are called out.
cat >"$T/quota.json" <<'JSON'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"percentRemaining":65}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"percentRemaining":80}]},
  {"id":"muse","status":"healthy","quotas":[{"percentRemaining":100}]},
  {"id":"claude","status":"healthy","quotas":[{"percentRemaining":100}]}
]}
JSON
printf '2026-11-13T00:00:00Z\t175\tmuse\tfiber-175-build\tprobe-failed-id\n' >"$T/run/roster"
printf '{"sessions":[{"id":"probe-failed-id","status":"running","model":"opencode-go/muse-spark-1.3-contributor"}]}\n' >"$T/delegate.json"
DELEGATE_FAIL=1 CLAUDE_FAIL=1 run_pick --explain
[ "$RC" -eq 0 ] || fail "explain exit $RC: $ERR"
[ "$OUT" = 'opencode-go/muse-spark-1.3-contributor muselaunch' ] || fail "failed probe was not zero load: [$OUT]"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "explain stdout was not one line"
[ "$(grep -c '^lane-model: candidate ' "$T/err")" -eq 3 ] || fail "explain did not report all candidates: $ERR"
grep -q 'provider=opencode-go headroom=80% live lanes=0 score=80' "$T/err" || fail "explain lacks quota/load/score: $ERR"
grep -q 'delegate probe failed; load treated as 0' "$T/err" || fail "explain omitted delegate probe failure: $ERR"
grep -q 'claude probe failed; load treated as 0' "$T/err" || fail "explain omitted Claude probe failure: $ERR"

# A missing roster means zero loads, even when the delegate reports a matching
# session; no absolute home path is needed in this fixture.
rm -f "$T/run/roster"
DELEGATE_FAIL=0 CLAUDE_FAIL=0 run_pick --explain
[ "$RC" -eq 0 ] || fail "missing roster exit $RC: $ERR"
grep -q 'roster missing; load is 0' "$T/err" || fail "missing roster was not explained: $ERR"

# A failing quota command also degrades to the required no-usable exit.
QUOTA_FAIL=1 run_pick --explain
[ "$RC" -eq 2 ] || fail "failed quota exit $RC, want 2"
[ -z "$OUT" ] || fail "failed quota printed stdout: [$OUT]"
case "$ERR" in *'quota command failed'*) ;; *) fail "failed quota message unclear: $ERR";; esac

echo 'lane-model: ok'
